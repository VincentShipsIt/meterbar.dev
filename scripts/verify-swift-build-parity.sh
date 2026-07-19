#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 DEBUG_BUILD_SETTINGS RELEASE_BUILD_SETTINGS PACKAGE_MANIFEST" >&2
  exit 64
fi

debug_settings=$1
release_settings=$2
package_manifest=$3

for input in "$debug_settings" "$release_settings" "$package_manifest"; do
  if [ ! -f "$input" ]; then
    echo "Swift build parity input not found: $input" >&2
    exit 66
  fi
done

python3 - "$debug_settings" "$release_settings" "$package_manifest" <<'PY'
import json
from pathlib import Path
import re
import sys

debug_settings, release_settings, package_manifest = sys.argv[1:]


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


def load_xcode_settings(path_value: str, configuration: str) -> dict[str, object]:
    path = Path(path_value)
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"Xcode {configuration} build-settings JSON malformed: {error}.")

    if (
        not isinstance(payload, list)
        or not payload
        or not isinstance(payload[0], dict)
        or not isinstance(payload[0].get("buildSettings"), dict)
    ):
        fail(
            f"Xcode {configuration} build-settings JSON malformed: "
            "expected a non-empty array whose first entry contains buildSettings."
        )

    return payload[0]["buildSettings"]


def assert_xcode_setting(
    settings: dict[str, object],
    configuration: str,
    key: str,
    expected: str,
) -> None:
    if key not in settings:
        fail(f"Xcode {configuration} {key} missing; expected '{expected}'.")

    actual = str(settings[key])
    if actual != expected:
        fail(
            f"Xcode {configuration} {key} mismatch: "
            f"expected '{expected}', got '{actual}'."
        )


def matching_parenthesis(masked_source: str, opening_index: int) -> int:
    depth = 0
    for index in range(opening_index, len(masked_source)):
        character = masked_source[index]
        if character == "(":
            depth += 1
        elif character == ")":
            depth -= 1
            if depth == 0:
                return index

    fail("SwiftPM Package.swift malformed: unterminated target declaration.")
    return -1


def mask_non_code(source: str) -> str:
    masked = list(source)
    index = 0
    state = "code"
    block_comment_depth = 0

    while index < len(source):
        character = source[index]
        following = source[index + 1] if index + 1 < len(source) else ""

        if state == "line_comment":
            if character == "\n":
                state = "code"
            else:
                masked[index] = " "
        elif state == "block_comment":
            if character == "/" and following == "*":
                block_comment_depth += 1
                masked[index] = " "
                masked[index + 1] = " "
                index += 1
            elif character == "*" and following == "/":
                block_comment_depth -= 1
                masked[index] = " "
                masked[index + 1] = " "
                index += 1
                if block_comment_depth == 0:
                    state = "code"
            elif character != "\n":
                masked[index] = " "
        elif state == "string":
            if character == "\\":
                masked[index] = " "
                if index + 1 < len(source):
                    masked[index + 1] = " "
                index += 1
            elif character == '"':
                masked[index] = " "
                state = "code"
            elif character != "\n":
                masked[index] = " "
        elif character == "/" and following == "/":
            state = "line_comment"
            masked[index] = " "
            masked[index + 1] = " "
            index += 1
        elif character == "/" and following == "*":
            state = "block_comment"
            block_comment_depth = 1
            masked[index] = " "
            masked[index + 1] = " "
            index += 1
        elif character == '"':
            state = "string"
            masked[index] = " "

        index += 1

    return "".join(masked)


def package_target_blocks(source: str) -> dict[str, list[str]]:
    blocks: dict[str, list[str]] = {}
    declaration_pattern = re.compile(r"\.(?:target|testTarget)\s*\(")
    masked_source = mask_non_code(source)

    for match in declaration_pattern.finditer(masked_source):
        opening_index = match.end() - 1
        closing_index = matching_parenthesis(masked_source, opening_index)
        source_block = source[match.start():closing_index + 1]
        name_match = re.search(r'\bname\s*:\s*"([^"]+)"', source_block)
        if name_match:
            blocks.setdefault(name_match.group(1), []).append(
                masked_source[match.start():closing_index + 1]
            )

    return blocks


def require_package_directive(
    block: str,
    target: str,
    setting: str,
    pattern: str,
    expected: str,
) -> None:
    matches = re.findall(pattern, block)
    if not matches:
        fail(f"SwiftPM target '{target}' {setting} missing; expected '{expected}'.")

    actual = matches[0]
    if actual != expected:
        fail(
            f"SwiftPM target '{target}' {setting} mismatch: "
            f"expected '{expected}', got '{actual}'."
        )


def assert_package_target(blocks: dict[str, list[str]], target: str) -> None:
    matches = blocks.get(target, [])
    if len(matches) != 1:
        fail(
            f"SwiftPM target '{target}' declaration mismatch: "
            f"expected exactly one, found {len(matches)}."
        )

    block = matches[0]
    require_package_directive(
        block,
        target,
        "SWIFT_VERSION",
        r"\.swiftLanguageMode\s*\(\s*\.([A-Za-z0-9_]+)\s*\)",
        "v5",
    )
    require_package_directive(
        block,
        target,
        "SWIFT_DEFAULT_ACTOR_ISOLATION",
        r"\.defaultIsolation\s*\(\s*([A-Za-z_][A-Za-z0-9_.]*)\s*\)",
        "MainActor.self",
    )


for path_value, configuration in (
    (debug_settings, "Debug"),
    (release_settings, "Release"),
):
    settings = load_xcode_settings(path_value, configuration)
    assert_xcode_setting(settings, configuration, "SWIFT_VERSION", "5.0")
    assert_xcode_setting(
        settings,
        configuration,
        "SWIFT_DEFAULT_ACTOR_ISOLATION",
        "MainActor",
    )

try:
    package_source = Path(package_manifest).read_text(encoding="utf-8")
except (OSError, UnicodeError) as error:
    fail(f"SwiftPM Package.swift unreadable: {error}.")

targets = package_target_blocks(package_source)
assert_package_target(targets, "MeterBar")
assert_package_target(targets, "MeterBarTests")

print("SwiftPM and Xcode Swift isolation parity verified.")
PY
