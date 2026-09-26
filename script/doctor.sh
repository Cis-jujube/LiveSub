#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

printf 'Project: %s\n' "$repo_root"
printf 'Git status:\n'
git -C "$repo_root" status --short --branch
printf '\nSystem:\n'
sw_vers
printf 'Architecture: %s\n' "$(uname -m)"
printf 'Memory: %s bytes\n' "$(sysctl -n hw.memsize)"
printf '\nDeveloper tools:\n'
xcode-select -p
swift --version
xcrun --sdk macosx --show-sdk-version
if xcodebuild -version >/dev/null 2>&1; then
    xcodebuild -version
else
    printf 'Full Xcode unavailable; SwiftPM with Command Line Tools is required.\n'
fi
printf '\nPython:\n'
uv --version
uv python find 3.12
printf '\nStorage:\n'
df -h "$repo_root"
printf '\nAudio devices:\n'
system_profiler SPAudioDataType | sed -n '1,80p'
