#!/bin/zsh
# Package the signed dist/LiveSub.app into a drag-to-install DMG for GitHub Releases.
# Build the app first:  LIVESUB_SIGNING_IDENTITY=… ./script/build_and_run.sh --verify
# Models and the Python runtime are not in the DMG; the app downloads them on first launch.
set -euo pipefail

project_root="${0:A:h:h}"
cd "$project_root"

app="dist/LiveSub.app"
sign_identity="${LIVESUB_SIGNING_IDENTITY:-}"
if [[ -z "$sign_identity" ]]; then
  print -u2 "Set LIVESUB_SIGNING_IDENTITY to the certificate used for $app."
  exit 1
fi
if [[ ! -d "$app" ]]; then
  print -u2 "$app is missing; build it with ./script/build_and_run.sh --verify first."
  exit 1
fi
codesign --verify --deep --strict "$app"
test -x "$app/Contents/Resources/bin/uv"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
dmg="dist/LiveSub-$version.dmg"
stage="$(mktemp -d "${TMPDIR:-/tmp}/livesub-dmg.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

ditto "$app" "$stage/LiveSub.app"
ln -s /Applications "$stage/Applications"
cat > "$stage/打不开？If it won't open.txt" <<'TEXT'
LiveSub 没有经过 Apple 公证，第一次打开时 macOS 会提示“无法验证开发者”。
1. 把 LiveSub 拖进“应用程序”文件夹，然后双击打开一次，在提示里点“完成”。
2. 打开“系统设置 → 隐私与安全性”，在页面下方找到 LiveSub，点“仍要打开”。
3. 再次确认“打开”。之后就可以像普通 App 一样直接打开。

LiveSub is not notarized by Apple, so macOS warns the first time you open it.
1. Drag LiveSub into Applications, double-click it once, and click "Done" in the warning.
2. Open System Settings → Privacy & Security, scroll down to LiveSub and click "Open Anyway".
3. Confirm "Open". From then on it opens like any other app.
TEXT

rm -f "$dmg"
hdiutil create -volname "LiveSub" -srcfolder "$stage" -fs HFS+ -format ULMO -ov "$dmg" >/dev/null
codesign --force --sign "$sign_identity" "$dmg"
codesign --verify "$dmg"
hdiutil verify "$dmg" >/dev/null

print "$dmg"
print "SHA-256  $(shasum -a 256 "$dmg" | cut -d' ' -f1)"
print "Size     $(du -h "$dmg" | cut -f1)"
