#!/bin/bash
set -euo pipefail
BRIDGE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-run}"
APP="$BRIDGE_ROOT/dist/MusicBridgeApp.app"
# SwiftBuild (the default build system) fails to initialize on this machine
# with "Unknown error parsing property list" before generating any file, so
# builds pin the native build system until that toolchain issue is resolved.
swift build --build-system native --package-path "$BRIDGE_ROOT/MacApp"
BIN="$(swift build --build-system native --package-path "$BRIDGE_ROOT/MacApp" --show-bin-path)/MusicBridgeApp"
# Stop only this checkout's build, leaving the Muse installation untouched.
while IFS= read -r pid; do
  if [[ -n "$pid" ]]; then kill "$pid"; fi
done < <(pgrep -f "^$APP/Contents/MacOS/MusicBridgeApp$" || true)
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MusicBridgeApp"
if [[ -f "$BRIDGE_ROOT/MacApp/Resources/MusicBridgeIcon.png" ]]; then
  cp "$BRIDGE_ROOT/MacApp/Resources/MusicBridgeIcon.png" "$APP/Contents/Resources/MusicBridgeIcon.png"
fi
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MusicBridgeApp</string>
<key>CFBundleIdentifier</key><string>cn.unmeta.musicbridge.rebuilt</string>
<key>CFBundleName</key><string>Music Bridge</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>MusicBridgeIcon.png</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSDocumentsFolderUsageDescription</key><string>读取本项目中的歌单记录、下载音乐和导入任务，用于本地音乐管理。</string>
<key>NSRemovableVolumesUsageDescription</key><string>读取连接的 iPod 曲库；仅在确认导入或初始化后写入歌曲及数据库。</string>
</dict></plist>
PLIST
# Bind the rebuilt executable and usage descriptions to the app's stable identity.
/usr/bin/codesign --force --sign - --identifier cn.unmeta.musicbridge.rebuilt "$APP"
case "$MODE" in
  --build-only) ;;
  run) /usr/bin/open -n "$APP" ;;
  --verify)
    /usr/bin/open -n "$APP"
    sleep 1
    pgrep -fl "^$APP/Contents/MacOS/MusicBridgeApp$"
    ;;
  --logs)
    /usr/bin/open -n "$APP"
    /usr/bin/log stream --info --style compact --predicate 'subsystem == "cn.unmeta.musicbridge.rebuilt"'
    ;;
  *) echo "usage: $0 [run|--verify|--build-only|--logs]" >&2; exit 2 ;;
esac
