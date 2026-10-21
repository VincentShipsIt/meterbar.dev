#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "Usage: $0 OUTPUT_PATH [SCRATCH_DIRECTORY]" >&2
  exit 64
fi

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd "$script_dir/.." && pwd)
package_path="$repository_root/MeterBarCLI"
output_path="$1"
scratch_root="${2:-${TMPDIR:-/tmp}/meterbar-cli-universal}"
deployment_target="${MACOSX_DEPLOYMENT_TARGET:-26.0}"

mkdir -p "$(dirname "$output_path")" "$scratch_root"

build_architecture() {
  local architecture="$1"
  local triple="${architecture}-apple-macosx${deployment_target}"
  local scratch_path="$scratch_root/$architecture"

  echo "Building MeterBar CLI for $architecture ($triple)" >&2
  swift build \
    --package-path "$package_path" \
    --configuration release \
    --triple "$triple" \
    --scratch-path "$scratch_path" >&2

  swift build \
    --package-path "$package_path" \
    --configuration release \
    --triple "$triple" \
    --scratch-path "$scratch_path" \
    --show-bin-path
}

arm64_bin_dir=$(build_architecture arm64)
x86_64_bin_dir=$(build_architecture x86_64)

arm64_binary="$arm64_bin_dir/meterbar"
x86_64_binary="$x86_64_bin_dir/meterbar"

for binary in "$arm64_binary" "$x86_64_binary"; do
  if [ ! -x "$binary" ]; then
    echo "Expected CLI executable not found: $binary" >&2
    exit 1
  fi
done

lipo -create "$arm64_binary" "$x86_64_binary" -output "$output_path"
chmod 755 "$output_path"
# Verify each required slice separately: some toolchain versions parse a
# multi-architecture -verify_arch invocation as multiple input files.
for architecture in arm64 x86_64; do
  lipo "$output_path" -verify_arch "$architecture"
done

echo "Universal CLI architectures: $(lipo -archs "$output_path")"
