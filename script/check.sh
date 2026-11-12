#!/bin/bash
set -euo pipefail
BRIDGE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp/}MusicBridgeChecks.XXXXXX")"
trap 'rm -r "$CHECK_DIR"' EXIT
SOURCES="$BRIDGE_ROOT/MacApp/Sources/MusicBridgeApp"
swiftc -parse-as-library -swift-version 5 \
  "$SOURCES/Models.swift" "$SOURCES/BridgeModel.swift" "$SOURCES/SurfaceMotion.swift" \
  "$SOURCES/GoMusicClient.swift" "$SOURCES/AppleMusicCatalogClient.swift" \
  "$SOURCES/DownloaderRunner.swift" "$SOURCES/IPodImporter.swift" \
  "$SOURCES/PlaylistLibrary.swift" \
  "$SOURCES/NativeIPodImporter.swift" \
  "$SOURCES/NativeLibraryService.swift" "$SOURCES/NativeImportTask.swift" \
  "$SOURCES/IPodKnowledge.swift" "$SOURCES/NativeAudioPlanner.swift" "$SOURCES/NativeImportViews.swift" \
  "$BRIDGE_ROOT/MacApp/Tests/MusicBridgeChecks.swift" \
  "$BRIDGE_ROOT/MacApp/Tests/NativeEngineChecks.swift" \
  "$BRIDGE_ROOT/MacApp/Tests/NativeWorkflowChecks.swift" \
  "$BRIDGE_ROOT/MacApp/Tests/DeviceDiscoveryChecks.swift" \
  "$BRIDGE_ROOT/MacApp/Tests/IPodKnowledgeChecks.swift" -o "$CHECK_DIR/check"
"$CHECK_DIR/check"
