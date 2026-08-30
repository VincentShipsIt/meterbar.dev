#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd "$script_dir/.." && pwd)

python3 - "$repository_root" <<'PYTHON'
import re
import sys
from pathlib import Path

repository_root = Path(sys.argv[1])
ci_path = repository_root / ".github/workflows/ci.yml"
e2e_path = repository_root / ".github/workflows/e2e.yml"
nightly_path = repository_root / ".github/workflows/nightly.yml"
release_path = repository_root / ".github/workflows/release.yml"
signed_path = repository_root / ".github/workflows/_build-signed.yml"
workflows_dir = repository_root / ".github/workflows"
xcode_action_dir = ".github/actions/select-xcode"
xcode_action_path = repository_root / xcode_action_dir / "action.yml"


def read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError as error:
        raise SystemExit(f"Unable to read workflow {path}: {error}") from error


def job_block(workflow: str, job_name: str, path: Path) -> str:
    match = re.search(
        rf"(?ms)^  {re.escape(job_name)}:\s*\n(?P<body>.*?)(?=^  [A-Za-z0-9_-]+:\s*\n|\Z)",
        workflow,
    )
    if match is None:
        raise SystemExit(f"{path}: missing jobs.{job_name}")
    return match.group("body")


def require(pattern: str, text: str, message: str) -> None:
    if re.search(pattern, text, re.MULTILINE) is None:
        raise SystemExit(message)


def require_checkout_input(job: str, name: str, value_pattern: str, path: Path, job_name: str) -> None:
    pattern = (
        r"^ {8}uses:\s*actions/checkout@[^\n]+\n"
        r"^ {8}with:\s*\n"
        r"(?:^ {10}[^\n]*\n)*?"
        rf"^ {{10}}{re.escape(name)}:\s*{value_pattern}\s*$"
    )
    require(pattern, job, f"{path}: jobs.{job_name} checkout must set {name}")


def require_ancestry_step(job: str, path: Path, job_name: str) -> None:
    pattern = (
        r"^ {6}- name:[^\n]*\n"
        r"^ {8}env:\s*\n"
        r"(?:^ {10}[^\n]*\n)*?"
        r"^ {10}RELEASE_COMMIT:\s*\$\{\{\s*github\.sha\s*\}\}\s*\n"
        r"(?:^ {10}[^\n]*\n)*?"
        r'^ {8}run:\s*scripts/verify-release-ancestry\.sh "\$RELEASE_COMMIT"\s*$'
    )
    require(pattern, job, f"{path}: jobs.{job_name} must verify github.sha ancestry")


def coverage_threshold(workflow: str, path: Path) -> str:
    matches = re.findall(r"^\s+COVERAGE_THRESHOLD:\s*([0-9]+(?:\.[0-9]+)?)\s*$", workflow, re.MULTILINE)
    if len(matches) != 1:
        raise SystemExit(f"{path}: expected exactly one numeric COVERAGE_THRESHOLD, found {len(matches)}")
    return matches[0]


def jobs_in(workflow: str, path: Path) -> dict[str, str]:
    """Every `jobs.<name>` block, keyed by job name.

    Scoped to the text after the top-level `jobs:` key so two-space keys under
    `on:` (push, pull_request, schedule, workflow_call) are not mistaken for jobs.
    """
    start = re.search(r"(?m)^jobs:\s*$", workflow)
    if start is None:
        raise SystemExit(f"{path}: missing top-level jobs:")
    body = workflow[start.end():]
    blocks = re.findall(
        r"(?ms)^  (?P<name>[A-Za-z0-9_-]+):\s*\n(?P<body>.*?)(?=^  [A-Za-z0-9_-]+:\s*\n|\Z)",
        body,
    )
    return {name: block for name, block in blocks}


def pinned_xcode_version() -> str:
    """The one place the toolchain version is written down."""
    try:
        action = xcode_action_path.read_text(encoding="utf-8")
    except OSError as error:
        raise SystemExit(
            f"{xcode_action_path}: composite Xcode action is missing ({error}). "
            "Workflows depend on it for the pinned toolchain."
        ) from error
    match = re.search(r"(?m)^    default:\s*\"([0-9]+(?:\.[0-9]+)*)\"\s*$", action)
    if match is None:
        raise SystemExit(
            f"{xcode_action_path}: expected a quoted `default: \"<version>\"` "
            "for the Xcode version input"
        )
    return match.group(1)


def require_single_source_xcode(workflows: dict[Path, str]) -> str:
    """No workflow may pin Xcode itself; toolchain users must use the action.

    Xcode 26.2 built a v1.8.41 release artifact that crashed at launch (#493).
    Validation and distribution drifting onto different toolchains is the
    failure this guards, so the version is bumped in exactly one file and every
    job that compiles or tests Swift goes through it.
    """
    for path, workflow in workflows.items():
        hardcoded = re.findall(r"(?m)^.*(?:/Applications/Xcode|xcode-select\s+-s).*$", workflow)
        if hardcoded:
            raise SystemExit(
                f"{path}: workflows must not select Xcode directly; "
                f"use `uses: ./{xcode_action_dir}` so the version stays "
                f"single-sourced in {xcode_action_dir}/action.yml. "
                f"Found: {[line.strip() for line in hardcoded]}"
            )

        for job_name, job in jobs_in(workflow, path).items():
            needs_toolchain = re.search(r"xcodebuild|scripts/check-coverage\.sh", job)
            if needs_toolchain is None:
                continue
            if re.search(rf"(?m)^\s+uses:\s*\./{re.escape(xcode_action_dir)}\s*$", job) is None:
                raise SystemExit(
                    f"{path}: jobs.{job_name} builds or tests Swift but never runs "
                    f"`uses: ./{xcode_action_dir}`, so it would use whatever Xcode "
                    "the runner image defaults to"
                )

    return pinned_xcode_version()


ci = read(ci_path)
e2e = read(e2e_path)
nightly = read(nightly_path)
release = read(release_path)
signed = read(signed_path)
nightly_version_job = job_block(nightly, "version", nightly_path)
version_job = job_block(release, "version", release_path)
nightly_build_job = job_block(nightly, "build", nightly_path)
release_build_job = job_block(release, "build", release_path)
test_job = job_block(signed, "test", signed_path)
build_job = job_block(signed, "build", signed_path)

thresholds = {
    ci_path: coverage_threshold(ci, ci_path),
    e2e_path: coverage_threshold(e2e, e2e_path),
    signed_path: coverage_threshold(signed, signed_path),
}
if len(set(thresholds.values())) != 1:
    details = ", ".join(f"{path.name}={value}" for path, value in thresholds.items())
    raise SystemExit(f"Coverage thresholds must match across broad validation workflows: {details}")

# Every workflow, not just the release path: a new macOS job that skips the
# action would silently build on the runner image default.
xcode_version = require_single_source_xcode(
    {path: read(path) for path in sorted(workflows_dir.glob("*.yml"))}
)

release_publishers = re.findall(
    r"^\s+uses:\s*softprops/action-gh-release@([0-9a-f]{40})\s+#\s+(v[0-9.]+)\s*$",
    build_job,
    re.MULTILINE,
)
expected_release_publishers = [
    ("3d0d9888cb7fd7b750713d6e236d1fcb99157228", "v3.0.2"),
]
if release_publishers != expected_release_publishers:
    raise SystemExit(
        f"{signed_path}: release publisher must pin Node 24 action "
        "softprops/action-gh-release@3d0d9888cb7fd7b750713d6e236d1fcb99157228 # v3.0.2; "
        f"found {release_publishers}"
    )

require(
    r"^\s+run:\s*bash scripts/check-coverage\.sh\s*$",
    test_job,
    f"{signed_path}: test must run scripts/check-coverage.sh",
)
require_checkout_input(
    test_job,
    "ref",
    r"\$\{\{\s*github\.sha\s*\}\}",
    signed_path,
    "test",
)
if re.search(r"^\s+environment:\s*", test_job, re.MULTILINE) is not None:
    raise SystemExit(f"{signed_path}: test must not enter the release environment")
require(
    r"^\s{4}needs:\s*test\s*$",
    build_job,
    f"{signed_path}: build must declare needs: test",
)
require(
    r"^\s{4}environment:\s*release\s*$",
    build_job,
    f"{signed_path}: build must keep signing credentials in the release environment",
)
for required_cloudkit_release_token in (
    "DEVELOPER_ID_PROVISIONING_PROFILE_BASE64",
    "Contents/embedded.provisionprofile",
    "security cms -D -i",
    "ProvisionsAllDevices",
    "com.apple.developer.icloud-container-identifiers",
    "com.apple.developer.icloud-services",
):
    if required_cloudkit_release_token not in build_job:
        raise SystemExit(
            f"{signed_path}: jobs.build must validate and embed the CloudKit "
            f"Developer ID profile ({required_cloudkit_release_token})"
        )
require_checkout_input(
    build_job,
    "ref",
    r"\$\{\{\s*github\.sha\s*\}\}",
    signed_path,
    "build",
)
require_checkout_input(version_job, "fetch-depth", "0", release_path, "version")
require_checkout_input(version_job, "ref", r"\$\{\{\s*github\.sha\s*\}\}", release_path, "version")
require_ancestry_step(version_job, release_path, "version")
require_checkout_input(nightly_version_job, "fetch-depth", "0", nightly_path, "version")
require_checkout_input(
    nightly_version_job,
    "ref",
    r"\$\{\{\s*github\.sha\s*\}\}",
    nightly_path,
    "version",
)
require_ancestry_step(nightly_version_job, nightly_path, "version")
require(
    r"^ {4}needs:\s*version\s*$",
    release_build_job,
    f"{release_path}: jobs.build must declare needs: version",
)
require(
    r"^ {4}needs:\s*version\s*$",
    nightly_build_job,
    f"{nightly_path}: jobs.build must declare needs: version",
)

print(
    "Signed-release workflow contract verified at coverage threshold "
    f"{next(iter(thresholds.values()))}% on Xcode {xcode_version}."
)
PYTHON
