#!/bin/zsh
# One-shot actual SwiftUI renders with synthetic transcript data. No audio is started.
# Requires the project's existing debug module objects (swift build).
# Windows are drawn off screen; nothing is shown and focus is not taken.
set -euo pipefail
project_root="${0:A:h:h}"
cd "$project_root"
scratch_dir="$(mktemp -d /tmp/livesub-design.XXXXXX)"
trap 'rm -rf "$scratch_dir"' EXIT
sed '/^@main$/d' app/LiveSub/App/LiveSubApp.swift > "$scratch_dir/LiveSubApp.swift"
swiftc -swift-version 6 -parse-as-library -I .build/debug \
  .build/debug/LiveSubAudio.o .build/debug/LiveSubBackend.o \
  .build/debug/LiveSubOverlay.o .build/debug/LiveSubSubtitles.o \
  .build/debug/SpeakerKit.o .build/debug/WhisperKit.o .build/debug/ArgmaxCore.o \
  app/LiveSub/App/AppController.swift app/LiveSub/App/TerminologySettingsView.swift \
  app/LiveSub/App/Theme.swift app/LiveSub/App/RuntimeSetup.swift \
  "$scratch_dir/LiveSubApp.swift" app/LiveSub/MainWindow/TranscriptView.swift \
  app/LiveSub/MainWindow/RuntimeSetupView.swift \
  script/render_design.swift -o "$scratch_dir/render"
"$scratch_dir/render" "$@"
if [[ "${1:-}" != "--settings-only" ]]; then
  swiftc -swift-version 6 -parse-as-library -I .build/debug .build/debug/LiveSubSubtitles.o \
    app/LiveSub/Overlay/OverlayView.swift app/LiveSub/Overlay/OverlayTextWindow.swift \
    script/render_overlay.swift -o "$scratch_dir/render-overlay"
  "$scratch_dir/render-overlay"
fi
