#!/usr/bin/env bash
# Fetches a pinned binary listed in tools.lock, verifies its sha256, and installs it into .tools/bin.
# Usage: scripts/fetch-tool.sh <tool>. Fails on an unknown tool or platform, or on any hash mismatch.
# In GitHub Actions, .tools/bin is also appended to $GITHUB_PATH.
set -euo pipefail

tool="${1:?usage: scripts/fetch-tool.sh <tool>}"
root="$(cd "$(dirname "$0")/.." && pwd)"

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) platform=linux-x64 ;;
  Darwin-arm64) platform=darwin-arm64 ;;
  *) echo "fetch-tool: unsupported platform $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

entry="$(awk -v t="$tool" -v p="$platform" '$1 == t && $3 == p { print $4, $5; exit }' "$root/tools.lock")"
if [ -z "$entry" ]; then
  echo "fetch-tool: no pinned $tool for $platform in tools.lock" >&2
  exit 1
fi
read -r sha256 url <<<"$entry"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
archive="$work/$(basename "$url")"
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --retry 3 -o "$archive" "$url"
echo "$sha256  $archive" | shasum -a 256 -c - >/dev/null || {
  echo "fetch-tool: sha256 mismatch for $tool ($url)" >&2
  exit 1
}

mkdir -p "$work/x" "$root/.tools/bin"
case "$archive" in
  *.tar.xz) tar -xJf "$archive" -C "$work/x" ;;
  *.tar.gz) tar -xzf "$archive" -C "$work/x" ;;
  *) echo "fetch-tool: unknown archive type $archive" >&2; exit 1 ;;
esac
case "$tool" in
  aderyn) install -m 0755 "$(find "$work/x" -type f -name aderyn | head -1)" "$root/.tools/bin/aderyn" ;;
  foundry) for bin in forge cast anvil chisel; do install -m 0755 "$work/x/$bin" "$root/.tools/bin/$bin"; done ;;
  *) echo "fetch-tool: no install rule for $tool" >&2; exit 1 ;;
esac

if [ -n "${GITHUB_PATH:-}" ]; then echo "$root/.tools/bin" >>"$GITHUB_PATH"; fi
echo "fetch-tool: $tool verified ($sha256) -> .tools/bin"
