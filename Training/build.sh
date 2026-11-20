#!/bin/zsh
# Builds one of the training tools with the app's own audio code, so the tools hear audio exactly as the app does.
# Usage: Training/build.sh MakeDataset|Train|Evaluate
set -euo pipefail
root="${0:A:h:h}"
tool="$1"
work="$root/.build/tools/$tool"
mkdir -p "$work"
cp "$root/Training/$tool.swift" "$work/main.swift"
app="$root/ABS Radio Maker"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" xcrun swiftc -O \
    -o "$work/$tool" \
    "$app"/Models/*.swift \
    "$app/Services/AudioClip.swift" "$app/Services/AudioProcessor.swift" \
    "$app/Services/ContentDetector.swift" "$app/Services/Performance.swift" \
    "$app/Services/TalkDetector.swift" \
    "$work/main.swift"
echo "$work/$tool"
