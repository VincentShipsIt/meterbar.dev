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

print(f"Signed-release workflow contract verified at coverage threshold {next(iter(thresholds.values()))}%.")
PYTHON
