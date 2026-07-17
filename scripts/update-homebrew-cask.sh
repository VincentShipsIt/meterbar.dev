#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "Usage: $0 CASK_PATH VERSION SHA256 REPOSITORY" >&2
  exit 64
fi

cask_path=$1
version=$2
sha256=$3
repository=$4
canonical_repository="VincentShipsIt/meterbar.dev"

if [ ! -f "$cask_path" ]; then
  echo "Homebrew cask not found: $cask_path" >&2
  exit 66
fi

if [[ ! "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "Homebrew cask version must match canonical MAJOR.MINOR.PATCH syntax." >&2
  exit 64
fi

if [[ ! "$sha256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "Homebrew cask SHA256 must be a lowercase 64-hex digest." >&2
  exit 64
fi

if [ "$repository" != "$canonical_repository" ]; then
  echo "Homebrew cask repository must be $canonical_repository, got $repository." >&2
  exit 64
fi

python3 - "$cask_path" "$version" "$sha256" "$repository" <<'PY'
import os
from pathlib import Path
import re
import stat
import sys
import tempfile

cask_path = Path(sys.argv[1])
version = sys.argv[2]
sha256 = sys.argv[3]
repository = sys.argv[4]
original = cask_path.read_text(encoding="utf-8")


def replace_once(text: str, pattern: str, replacement: str, label: str) -> str:
    updated, count = re.subn(pattern, replacement, text, flags=re.MULTILINE)
    if count != 1:
        raise SystemExit(
            f"Expected exactly one canonical {label} declaration in {cask_path}; found {count}."
        )
    return updated


updated = replace_once(
    original,
    r'^(?P<indent>[ \t]*)version "[^"\n]+"[ \t]*$',
    rf'\g<indent>version "{version}"',
    "version",
)
updated = replace_once(
    updated,
    r'^(?P<indent>[ \t]*)sha256 "[0-9a-fA-F]{64}"[ \t]*$',
    rf'\g<indent>sha256 "{sha256}"',
    "SHA256",
)
updated = replace_once(
    updated,
    (
        r'^(?P<indent>[ \t]*)url "https://github\.com/'
        r'[^/\s"]+/[^/\s"]+/releases/download/v#\{version\}/'
        r'MeterBar-v#\{version\}\.zip"[ \t]*$'
    ),
    (
        rf'\g<indent>url "https://github.com/{repository}/releases/download/'
        r'v#{version}/MeterBar-v#{version}.zip"'
    ),
    "release URL",
)

descriptor, temporary_name = tempfile.mkstemp(
    prefix=f".{cask_path.name}.",
    dir=cask_path.parent,
)
try:
    with os.fdopen(descriptor, "w", encoding="utf-8") as temporary_file:
        temporary_file.write(updated)
    os.chmod(temporary_name, stat.S_IMODE(cask_path.stat().st_mode))
    os.replace(temporary_name, cask_path)
except BaseException:
    try:
        os.unlink(temporary_name)
    except FileNotFoundError:
        pass
    raise
PY
