#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

echo "Python backend tests"
(
    cd "$repo_root/backend"
    uv run --locked pytest -q tests
)

echo "Swift audio conversion and bounded-queue checks"
swift run AudioPipelineChecks
echo "Swift subtitle pairing and revision checks"
swift run SubtitleStoreChecks
echo "Swift overlay placement checks"
swift run OverlayPlacementChecks
echo "Swift backend wire and real loopback transport checks"
swift run BackendProtocolChecks --transport

echo "Build application"
swift build --product LiveSub
git diff --check
echo "All automated checks completed. Native capture and overlay UX require manual .app validation."
