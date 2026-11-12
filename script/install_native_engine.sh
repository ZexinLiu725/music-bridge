#!/bin/bash
set -euo pipefail
BRIDGE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
case "$(uname -m)" in
  arm64) TARGET="darwin-arm64" ;;
  x86_64) TARGET="darwin-x64" ;;
  *) echo "Unsupported Mac architecture" >&2; exit 1 ;;
esac
ENGINE_DIR="$BRIDGE_ROOT/work/native-tools/podkit-0.6.0"
if [[ -x "$ENGINE_DIR/podkit" ]]; then
  "$ENGINE_DIR/podkit" --version
  exit 0
fi
STAGING="$(mktemp -d "${TMPDIR:-/tmp/}MusicBridgeEngine.XXXXXX")"
trap 'rm -r "$STAGING"' EXIT
curl --fail --location --retry 2 --connect-timeout 20 --max-time 600 \
  "https://github.com/jvgomg/podkit/releases/download/podkit%400.6.0/podkit-$TARGET.tar.gz" \
  -o "$STAGING/engine.tar.gz"
tar -xzf "$STAGING/engine.tar.gz" -C "$STAGING" podkit
[[ "$("$STAGING/podkit" --version)" == "0.6.0" ]]
mkdir -p "$ENGINE_DIR"
cp -n "$STAGING/podkit" "$ENGINE_DIR/podkit"
echo "Installed podkit 0.6.0 for Music Bridge. No device was changed."
