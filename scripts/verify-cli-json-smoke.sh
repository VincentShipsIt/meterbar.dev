#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 METERBAR_EXECUTABLE" >&2
  exit 64
fi

cli_binary="$1"
if [ ! -f "$cli_binary" ] || [ ! -x "$cli_binary" ]; then
  echo "MeterBar CLI executable not found or not executable: $cli_binary" >&2
  exit 1
fi

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/meterbar-cli-json-smoke.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT

run_json_command() {
  local command_name="$1"
  local stdout_file="$temporary_directory/$command_name.stdout"
  local stderr_file="$temporary_directory/$command_name.stderr"

  if ! "$cli_binary" "$command_name" --json > "$stdout_file" 2> "$stderr_file"; then
    echo "meterbar $command_name --json failed." >&2
    if [ -s "$stderr_file" ]; then
      cat "$stderr_file" >&2
    fi
    exit 1
  fi

  if [ -s "$stderr_file" ]; then
    echo "meterbar $command_name --json wrote diagnostics to stderr; validating stdout separately."
  fi
}

run_json_command usage
run_json_command cost
run_json_command doctor

python3 - \
  "$temporary_directory/usage.stdout" \
  "$temporary_directory/cost.stdout" \
  "$temporary_directory/doctor.stdout" <<'PY'
import json
import math
import sys


def fail(message):
    raise SystemExit(message)


def reject_constant(value):
    fail(f"non-standard JSON numeric constant: {value}")


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            fail(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_document(path, label):
    try:
        with open(path, "r", encoding="utf-8") as stream:
            return json.load(
                stream,
                parse_constant=reject_constant,
                object_pairs_hook=unique_object,
            )
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"{label} stdout is not one JSON document: {error}")


def require(condition, message):
    if not condition:
        fail(message)


def require_number(value, path):
    require(
        isinstance(value, (int, float)) and not isinstance(value, bool),
        f"{path} must be numeric",
    )
    require(math.isfinite(value), f"{path} must be finite")


def require_integer(value, path, minimum=0):
    require(
        isinstance(value, int) and not isinstance(value, bool) and value >= minimum,
        f"{path} must be an integer greater than or equal to {minimum}",
    )


def validate_error_or_providers(document, label, expected_error_code):
    require(isinstance(document, dict), f"{label} must be a JSON object")
    require_integer(document.get("schemaVersion"), f"{label}.schemaVersion", minimum=1)
    require(document["schemaVersion"] == 1, f"{label}.schemaVersion must equal 1")

    if "error" in document:
        require("providers" not in document, f"{label} cannot contain both error and providers")
        error = document["error"]
        require(isinstance(error, dict), f"{label}.error must be an object")
        require(error.get("code") == expected_error_code, f"{label}.error.code is unexpected")
        require(
            isinstance(error.get("message"), str) and error["message"],
            f"{label}.error.message must be a non-empty string",
        )
        return None

    providers = document.get("providers")
    require(isinstance(providers, list), f"{label}.providers must be an array")
    require("error" not in document, f"{label} cannot contain both providers and error")
    return providers


def validate_usage(document):
    providers = validate_error_or_providers(
        document,
        "usage",
        "usage_cache_missing",
    )
    if providers is None:
        return

    require(providers, "usage.providers must contain at least one provider")
    for provider_index, provider in enumerate(providers):
        path = f"usage.providers[{provider_index}]"
        require(isinstance(provider, dict), f"{path} must be an object")
        require(
            isinstance(provider.get("provider"), str) and provider["provider"],
            f"{path}.provider must be a non-empty string",
        )
        require(
            isinstance(provider.get("displayName"), str) and provider["displayName"],
            f"{path}.displayName must be a non-empty string",
        )
        require(
            isinstance(provider.get("lastUpdated"), str) and provider["lastUpdated"],
            f"{path}.lastUpdated must be a non-empty string",
        )
        windows = provider.get("windows")
        require(isinstance(windows, list), f"{path}.windows must be an array")
        for window_index, window in enumerate(windows):
            window_path = f"{path}.windows[{window_index}]"
            require(isinstance(window, dict), f"{window_path} must be an object")
            require(
                window.get("kind") in {"session", "weekly", "codeReview"},
                f"{window_path}.kind is unexpected",
            )
            require(
                window.get("quotaBand") in {"healthy", "tight", "critical", "exhausted"},
                f"{window_path}.quotaBand is unexpected",
            )
            require(
                isinstance(window.get("estimated"), bool),
                f"{window_path}.estimated must be boolean",
            )
            for field in ("used", "total", "percentUsed", "percentLeft"):
                require_number(window.get(field), f"{window_path}.{field}")


def validate_cost(document):
    providers = validate_error_or_providers(
        document,
        "cost",
        "cost_cache_missing",
    )
    if providers is None:
        return

    require(
        isinstance(document.get("lastScannedAt"), str) and document["lastScannedAt"],
        "cost.lastScannedAt must be a non-empty string",
    )
    period = document.get("period")
    require(isinstance(period, dict), "cost.period must be an object")
    require_integer(period.get("requestedDays"), "cost.period.requestedDays", minimum=1)
    require_integer(period.get("coveredDays"), "cost.period.coveredDays")
    require(
        isinstance(period.get("isTruncated"), bool),
        "cost.period.isTruncated must be boolean",
    )
    require_number(document.get("totalCostUSD"), "cost.totalCostUSD")
    require_integer(document.get("totalTokens"), "cost.totalTokens")

    for provider_index, provider in enumerate(providers):
        path = f"cost.providers[{provider_index}]"
        require(isinstance(provider, dict), f"{path} must be an object")
        require(
            isinstance(provider.get("provider"), str) and provider["provider"],
            f"{path}.provider must be a non-empty string",
        )
        require(
            isinstance(provider.get("displayName"), str) and provider["displayName"],
            f"{path}.displayName must be a non-empty string",
        )
        for field in (
            "inputTokens",
            "outputTokens",
            "cacheReadTokens",
            "totalTokens",
        ):
            require_integer(provider.get(field), f"{path}.{field}")
        require_number(provider.get("estimatedCostUSD"), f"{path}.estimatedCostUSD")


def reject_secret_keys(value, path="doctor"):
    forbidden_fragments = (
        "authorization",
        "credential",
        "password",
        "secret",
        "token",
    )
    if isinstance(value, dict):
        for key, child in value.items():
            normalized = key.lower().replace("_", "").replace("-", "")
            require(
                not any(fragment in normalized for fragment in forbidden_fragments),
                f"{path} contains forbidden secret-bearing field {key!r}",
            )
            reject_secret_keys(child, f"{path}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            reject_secret_keys(child, f"{path}[{index}]")


def validate_doctor(document):
    require(isinstance(document, list), "doctor must be a JSON array")
    require(document, "doctor must contain at least one provider report")
    reject_secret_keys(document)

    report_keys = {"provider", "overall", "healthy", "checks"}
    required_check_keys = {"id", "title", "level", "detail"}
    allowed_check_keys = required_check_keys | {"recovery"}
    levels = {"pass", "warn", "fail"}

    for report_index, report in enumerate(document):
        path = f"doctor[{report_index}]"
        require(isinstance(report, dict), f"{path} must be an object")
        require(set(report) == report_keys, f"{path} fields do not match the redacted DTO")
        require(
            isinstance(report["provider"], str) and report["provider"],
            f"{path}.provider must be a non-empty string",
        )
        require(report["overall"] in levels, f"{path}.overall is unexpected")
        require(isinstance(report["healthy"], bool), f"{path}.healthy must be boolean")
        require(
            report["healthy"] == (report["overall"] == "pass"),
            f"{path}.healthy conflicts with overall",
        )
        require(isinstance(report["checks"], list), f"{path}.checks must be an array")

        for check_index, check in enumerate(report["checks"]):
            check_path = f"{path}.checks[{check_index}]"
            require(isinstance(check, dict), f"{check_path} must be an object")
            require(
                required_check_keys <= set(check) <= allowed_check_keys,
                f"{check_path} fields do not match the redacted DTO",
            )
            for field in ("id", "title", "detail"):
                require(
                    isinstance(check[field], str) and check[field],
                    f"{check_path}.{field} must be a non-empty string",
                )
            require(check["level"] in levels, f"{check_path}.level is unexpected")
            if "recovery" in check:
                require(
                    check["recovery"] is None or isinstance(check["recovery"], str),
                    f"{check_path}.recovery must be a string or null",
                )


usage = load_document(sys.argv[1], "usage")
cost = load_document(sys.argv[2], "cost")
doctor = load_document(sys.argv[3], "doctor")

validate_usage(usage)
validate_cost(cost)
validate_doctor(doctor)
print("Usage, cost, and doctor JSON command contracts verified.")
PY
