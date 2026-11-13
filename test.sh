#!/bin/bash
# Runs the tests. With only the Xcode Command Line Tools installed, the compiler has to be
# told where the Swift Testing plugin is; with full Xcode it finds it by itself.
set -euo pipefail
cd "$(dirname "$0")"

args=()
plugins="$(xcode-select -p 2>/dev/null)/usr/lib/swift/host/plugins/testing"
if [[ "$(xcode-select -p 2>/dev/null)" == */CommandLineTools && -d "$plugins" ]]; then
    args=(-Xswiftc -plugin-path -Xswiftc "$plugins")
fi
swift test ${args[@]+"${args[@]}"} "$@"
