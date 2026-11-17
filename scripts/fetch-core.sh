#!/usr/bin/env bash
# Puts the core library of one platform in place, checked by SHA-256 (H-09: no `curl | tar` of an
# unchecked download, and never the floating `draft` release).
#
#   scripts/fetch-core.sh <platform> <dest-dir>
#     platform: android | ios | macos | windows-amd64 | linux-amd64 | linux-arm64 | ...
#
# Default: downloads hiddify-lib-<platform>.tar.gz of the release v<core.version> and checks it
# against core.<platform>.sha256 in dependencies.properties (the digests GitHub lists for the
# official release). A platform with no recorded digest is refused.
#
# A core built locally (the fork's own, recommended):
#   CORE_AAR=/path/hiddify-core.aar CORE_SHA256=<sha256> scripts/fetch-core.sh android android/app/libs
#   CORE_ARCHIVE=/path/hiddify-lib-<platform>.tar.gz CORE_SHA256=<sha256> scripts/fetch-core.sh <platform> <dest>
set -euo pipefail
platform="${1:?platform}"
dest="${2:?destination directory}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
prop() { sed -n "s/^$1=//p" "$here/dependencies.properties" | tr -d '\r' | head -1; }
sha() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
check() {
  local file="$1" expected="$2" actual
  actual="$(sha "$file")"
  if [ -z "$expected" ] || [ "$actual" != "$expected" ]; then
    echo "core: SHA-256 mismatch for $file" >&2
    echo "  expected: ${expected:-<none recorded>}" >&2
    echo "  actual:   $actual" >&2
    exit 1
  fi
  echo "core: $file sha256 $actual OK"
}
mkdir -p "$dest"
if [ -n "${CORE_AAR:-}" ]; then
  [ "$platform" = android ] || { echo "CORE_AAR is for android only" >&2; exit 1; }
  check "$CORE_AAR" "${CORE_SHA256:-}"
  cp -f "$CORE_AAR" "$dest/hiddify-core.aar"
  exit 0
fi
if [ -n "${CORE_ARCHIVE:-}" ]; then
  check "$CORE_ARCHIVE" "${CORE_SHA256:-}"
  tar xzf "$CORE_ARCHIVE" -C "$dest"
  exit 0
fi
version="$(prop core.version)"
expected="$(prop "core.$platform.sha256")"
[ -n "$expected" ] || { echo "core: no core.$platform.sha256 in dependencies.properties, refusing to download" >&2; exit 1; }
url="https://github.com/hiddify/hiddify-core/releases/download/v$version/hiddify-lib-$platform.tar.gz"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
curl -fL --retry 5 --retry-delay 5 --retry-all-errors -o "$tmp" "$url"
check "$tmp" "$expected"
tar xzf "$tmp" -C "$dest"
