#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
cd "$project_root"

mode="${1:---run}"
case "$mode" in
  --build-only|--verify|--run)
    app_dir="$project_root/dist/LiveSub.app"
    bundle_id="local.jujube.livesub"
    display_name="LiveSub"
    sign_identity="${LIVESUB_SIGNING_IDENTITY:-}"
    if [[ -z "$sign_identity" || "$sign_identity" == "-" ]]; then
      print -u2 "Set LIVESUB_SIGNING_IDENTITY to the SHA-1 of a valid code-signing certificate before building LiveSub. The formal app cannot use ad hoc signing."
      exit 1
    fi
    ;;
  --verify-preview)
    app_dir="$project_root/dist/previews/LiveSub-icon-preview.app"
    bundle_id="local.jujube.livesub.preview.icon"
    display_name="LiveSub Icon Preview"
    sign_identity="${LIVESUB_PREVIEW_SIGNING_IDENTITY:--}"
    ;;
  --verify-ui-preview)
    app_dir="$project_root/dist/previews/LiveSub-ui-preview.app"
    bundle_id="local.jujube.livesub.preview.ui"
    display_name="LiveSub UI Preview"
    sign_identity="${LIVESUB_PREVIEW_SIGNING_IDENTITY:--}"
    ;;
  --verify-qwen-preview)
    app_dir="$project_root/dist/previews/LiveSub-qwen-preview.app"
    bundle_id="local.jujube.livesub.preview.qwen"
    display_name="LiveSub Qwen Preview"
    sign_identity="${LIVESUB_PREVIEW_SIGNING_IDENTITY:--}"
    ;;
  --verify-native-preview)
    app_dir="$project_root/dist/previews/LiveSub-native-preview.app"
    bundle_id="local.jujube.livesub.preview.native"
    display_name="LiveSub Native Preview"
    sign_identity="${LIVESUB_PREVIEW_SIGNING_IDENTITY:--}"
    ;;
  *)
    print -u2 "Usage: $0 [--build-only|--verify|--run|--verify-preview|--verify-ui-preview|--verify-qwen-preview|--verify-native-preview]"
    exit 2
    ;;
esac

# Keep the previous package until the user accepts its replacement. One slot
# per identity prevents a chain of unreviewed backup bundles.
previous_app_dir="$project_root/.build/previous-app-bundle/$bundle_id.app"
if [[ -e "$previous_app_dir" ]]; then
  print -u2 "The previous package is still awaiting version acceptance at $previous_app_dir. Preserve/accept the current iteration before building another replacement."
  exit 1
fi

if [[ "$sign_identity" != "-" ]]; then
  if [[ ! "$sign_identity" =~ '^[[:xdigit:]]{40}$' ]] ||
      ! security find-identity -v -p codesigning | grep -Fq "$sign_identity"; then
    print -u2 "Code-signing identity $sign_identity is not a valid available certificate. Check Keychain and LIVESUB_SIGNING_IDENTITY."
    exit 1
  fi
fi
if pgrep -f "$app_dir/Contents/MacOS/LiveSub" >/dev/null; then
  print -u2 "Quit $app_dir before replacing it."
  exit 1
fi

swift build -c release --product LiveSub
binary_dir="$(swift build -c release --show-bin-path)"
icon_source="$project_root/assets/app-icon/LiveSubIcon.png"

test -f "$icon_source"
target_app_dir="$app_dir"
mkdir -p "${target_app_dir:h}"
stage_root="$(mktemp -d "${target_app_dir:h}/.livesub-stage.XXXXXX")"
app_dir="$stage_root/${target_app_dir:t}"
icon_temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/livesub-icon.XXXXXX")"
cleanup() {
  rm -rf "$icon_temp_dir"
  if [[ -e "$previous_app_dir" && ! -e "$target_app_dir" ]]; then
    if ! mv "$previous_app_dir" "$target_app_dir"; then
      print -u2 "Could not restore the previous app; it remains at $previous_app_dir."
      return
    fi
  fi
  rm -rf "$stage_root"
}
trap cleanup EXIT
macos_dir="$app_dir/Contents/MacOS"
resources_dir="$app_dir/Contents/Resources"
backend_dir="$resources_dir/backend"
mkdir -p "$macos_dir" "$backend_dir"
cp "$binary_dir/LiveSub" "$macos_dir/LiveSub"
# Installed system models only. The main app still runs on macOS 15;
# the helper checks macOS 26.4 and missing languages fall back to Qwen.
xcrun swiftc -O -parse-as-library -target arm64-apple-macos15.0 \
  script/native_translation_helper.swift -o "$resources_dir/LiveSubNativeTranslation"
rsync -a \
  --exclude '__pycache__/' --exclude '*.pyc' \
  --exclude 'asr/r2t2.py' --exclude 'asr/download_model.py' \
  --exclude 'translation/benchmark.py' \
  backend/livesub/ "$backend_dir/livesub/"
cp backend/pyproject.toml backend/uv.lock "$backend_dir/"
# First-launch setup (RuntimeSetup.swift) uses a bundled, self-contained uv to create the
# Python runtime from uv.lock, then downloads the pinned models with the scripts above.
uv_source="${LIVESUB_UV:-$(command -v uv || true)}"
uv_source="${uv_source:A}"
if [[ ! -x "$uv_source" ]] || otool -L "$uv_source" | tail -n +2 | grep -qv -e '/usr/lib/' -e '/System/Library/'; then
  print -u2 "A self-contained uv binary is required (set LIVESUB_UV). Found: ${uv_source:-none}"
  exit 1
fi
mkdir -p "$resources_dir/bin"
cp "$uv_source" "$resources_dir/bin/uv"
chmod 755 "$resources_dir/bin/uv"

iconset_dir="$icon_temp_dir/LiveSubIcon.iconset"
mkdir -p "$iconset_dir"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$icon_source" --out "$iconset_dir/icon_${size}x${size}.png" >/dev/null
  double_size=$((size * 2))
  sips -z "$double_size" "$double_size" "$icon_source" --out "$iconset_dir/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns -o "$resources_dir/LiveSubIcon.icns" "$iconset_dir"

# SwiftPM resource bundles must accompany the staged executable if later targets add them.
for bundle in "$binary_dir"/*.bundle(N); do
  ditto "$bundle" "$resources_dir/${bundle:t}"
  ditto "$bundle" "$macos_dir/${bundle:t}"
done

cat > "$app_dir/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>LiveSub</string>
  <key>CFBundleIdentifier</key><string>$bundle_id</string>
  <key>CFBundleName</key><string>$display_name</string>
  <key>CFBundleDisplayName</key><string>$display_name</string>
  <key>CFBundleIconFile</key><string>LiveSubIcon.icns</string>
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
codesign --force --sign "$sign_identity" "$resources_dir/LiveSubNativeTranslation"
codesign --force --sign "$sign_identity" "$resources_dir/bin/uv"
codesign --force --deep --sign "$sign_identity" "$app_dir"
codesign --verify --deep --strict "$app_dir"
test -x "$macos_dir/LiveSub"
test -f "$backend_dir/uv.lock"
test -x "$resources_dir/bin/uv"
test -f "$backend_dir/livesub/asr/download_qwen.py"
test -f "$backend_dir/livesub/translation/download_model.py"
test -s "$resources_dir/LiveSubIcon.icns"
if [[ -e "$target_app_dir" ]]; then
  mkdir -p "${previous_app_dir:h}"
  mv "$target_app_dir" "$previous_app_dir"
fi
mv "$app_dir" "$target_app_dir"
app_dir="$target_app_dir"
print "$app_dir"
if [[ -e "$previous_app_dir" ]]; then
  print "Retained previous package pending user acceptance: $previous_app_dir"
fi

if [[ "$mode" != "--run" ]]; then
  print "Verified: release build, Info.plist, app icon, bundled backend, executable, and signature ($sign_identity); app not launched."
elif [[ "$mode" == "--run" ]]; then
  open "$app_dir"
fi
