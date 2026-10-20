#!/bin/bash
# Runs the unit tests with the Command Line Tools only (no Xcode).
#
# SwiftPM does not put `Testing.framework` on the framework *search* path when the active
# developer directory is the Command Line Tools. It passes -I and -L for the frameworks
# directory, but not -F, so `canImport(Testing)` is false and the generated test runner
# (runner.swift) compiles its `main` down to a no-op: the bundle exits 0 having run ZERO
# tests. Adding -F for that directory makes the runner find the framework and the tests
# actually execute.
#
# Usage: scripts/run-tests.sh [extra swift test arguments...]
#   e.g. scripts/run-tests.sh --filter CoreBehaviourTests
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

frameworks=""
for dir in \
    "/Library/Developer/CommandLineTools/Library/Developer/Frameworks" \
    "/Applications/Xcode.app/Contents/Developer/Library/Developer/Frameworks"
do
    if [ -d "$dir/Testing.framework" ]; then
        frameworks="$dir"
        break
    fi
done

if [ -z "$frameworks" ]; then
    echo "error: Testing.framework not found; install the Command Line Tools or Xcode" >&2
    exit 1
fi

# The runtime also needs lib_TestingInterop.dylib, which the Command Line Tools ship
# outside the frameworks directory.
rpaths=()
for dir in \
    "/Library/Developer/CommandLineTools/Library/Developer/usr/lib" \
    "/Applications/Xcode.app/Contents/Developer/usr/lib"
do
    if [ -f "$dir/lib_TestingInterop.dylib" ]; then
        rpaths+=("$dir")
        break
    fi
done

link=()
for dir in "${rpaths[@]+"${rpaths[@]}"}"; do
    link+=(-Xlinker -rpath -Xlinker "$dir")
done

echo "==> swift test (Testing.framework from $frameworks)"
exec swift test \
    -Xswiftc -F -Xswiftc "$frameworks" \
    -Xlinker -F -Xlinker "$frameworks" \
    "${link[@]+"${link[@]}"}" \
    "$@"
