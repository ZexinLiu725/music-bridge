#!/bin/bash
set -euo pipefail
BRIDGE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp/}MusicBridgeChecks.XXXXXX")"
trap 'rm -r "$CHECK_DIR"' EXIT
SOURCES="$BRIDGE_ROOT/MacApp/Sources/MusicBridgeApp"
# Compile every app source except the @main entry (MusicBridgeApp.swift),
# whose entry point would clash with the checks' own @main. A glob keeps
# this list from going stale as source files are added.
APP_SOURCES=()
for file in "$SOURCES"/*.swift; do
  [[ "$file" == */MusicBridgeApp.swift ]] && continue
  APP_SOURCES+=("$file")
done
swiftc -parse-as-library -swift-version 5 \
  "${APP_SOURCES[@]}" \
  "$BRIDGE_ROOT/MacApp/Tests/MusicBridgeChecks.swift" \
  "$BRIDGE_ROOT/MacApp/Tests/NativeEngineChecks.swift" \
  "$BRIDGE_ROOT/MacApp/Tests/NativeWorkflowChecks.swift" \
  "$BRIDGE_ROOT/MacApp/Tests/DeviceDiscoveryChecks.swift" \
  "$BRIDGE_ROOT/MacApp/Tests/IPodKnowledgeChecks.swift" -o "$CHECK_DIR/check"
"$CHECK_DIR/check"
