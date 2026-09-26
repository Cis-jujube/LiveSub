#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
cd "$project_root"

mode="${1:---run}"
case "$mode" in
  --build-only|--verify|--run) ;;
  *)
    print -u2 "Usage: $0 [--build-only|--verify|--run]"
    exit 2
    ;;
esac

swift build -c release --product LiveSub
binary_dir="$(swift build -c release --show-bin-path)"
app_dir="$project_root/dist/LiveSub.app"
macos_dir="$app_dir/Contents/MacOS"
resources_dir="$app_dir/Contents/Resources"
backend_dir="$resources_dir/backend"

if pgrep -x LiveSub >/dev/null; then
  print -u2 "Quit LiveSub before replacing dist/LiveSub.app."
  exit 1
fi
rm -rf "$app_dir"
mkdir -p "$macos_dir" "$backend_dir"
cp "$binary_dir/LiveSub" "$macos_dir/LiveSub"
rsync -a --exclude '__pycache__/' --exclude '*.pyc' backend/livesub/ "$backend_dir/livesub/"
cp backend/pyproject.toml backend/uv.lock "$backend_dir/"

# SwiftPM resource bundles must accompany the staged executable if later targets add them.
for bundle in "$binary_dir"/*.bundle(N); do
  ditto "$bundle" "$resources_dir/${bundle:t}"
  ditto "$bundle" "$macos_dir/${bundle:t}"
done

cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>LiveSub</string>
  <key>CFBundleIdentifier</key><string>local.jujube.livesub</string>
  <key>CFBundleName</key><string>LiveSub</string>
  <key>CFBundleDisplayName</key><string>LiveSub</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>LiveSub needs microphone access to transcribe your speech locally.</string>
  <key>NSScreenCaptureUsageDescription</key><string>LiveSub needs screen and system audio recording access to transcribe audio playing on this Mac locally. It does not save video.</string>
</dict></plist>
PLIST

plutil -lint "$app_dir/Contents/Info.plist"
codesign --force --deep --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"
test -x "$macos_dir/LiveSub"
test -f "$backend_dir/uv.lock"
print "$app_dir"

if [[ "$mode" == "--verify" ]]; then
  print "Verified: release build, Info.plist, bundled backend, executable, and ad hoc signature; app not launched."
elif [[ "$mode" == "--run" ]]; then
  open "$app_dir"
fi
