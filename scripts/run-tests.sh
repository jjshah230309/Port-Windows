#!/bin/bash
# Runs the unit tests and fails when they fail OR when the suite runs zero tests.
#
# SwiftPM does not put `Testing.framework` on the framework *search* path when the active
# developer directory is the Command Line Tools. It passes -I and -L for the frameworks
# directory, but not -F, so `canImport(Testing)` is false and the generated test runner
# (runner.swift) compiles its `main` down to a no-op: the bundle exits 0 having run ZERO
# tests. Adding -F for that directory makes the runner find the framework and the tests
# actually execute.
#
# Zero tests is still a false pass, so this script also reads the summary line that
# swift-testing prints ("Test run with 56 tests in 12 suites passed" or, on Swift 6.1,
# "Test run with 56 tests passed after 12.3 seconds") and fails when the
# count is not above zero. `swift test list` and `swift test --list-tests` print the test
# names instead of running them, so they are exempt from that check.
#
# Usage: scripts/run-tests.sh [extra swift test arguments...]
#   e.g. scripts/run-tests.sh --filter CoreBehaviourTests
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

# The active developer directory decides which Testing.framework the tests link against:
# the Command Line Tools and a full Xcode each ship their own copy. Linux ships
# swift-testing as a library next to the toolchain, so it needs no search path there.
frameworks=""
interop=""
if [ "$(uname -s)" = "Darwin" ]; then
    dev_dirs=()
    active="$(xcode-select -p 2>/dev/null || true)"
    if [ -n "$active" ]; then
        dev_dirs+=("$active")
    fi
    dev_dirs+=(
        "/Library/Developer/CommandLineTools"
        "/Applications/Xcode.app/Contents/Developer"
    )

    for dev in "${dev_dirs[@]+"${dev_dirs[@]}"}"; do
        dir="$dev/Library/Developer/Frameworks"
        if [ -d "$dir/Testing.framework" ]; then
            frameworks="$dir"
            break
        fi
    done

    if [ -z "$frameworks" ]; then
        echo "error: Testing.framework not found; install the Command Line Tools or Xcode" >&2
        exit 1
    fi

    # The runtime also needs lib_TestingInterop.dylib, which the toolchain ships outside
    # the frameworks directory. Prefer the copy next to the frameworks directory we just
    # picked, so the bundle links against one consistent copy of swift-testing.
    for dev in "${dev_dirs[@]+"${dev_dirs[@]}"}"; do
        for lib_dir in "$dev/Library/Developer/usr/lib" "$dev/usr/lib"; do
            if [ -f "$lib_dir/lib_TestingInterop.dylib" ]; then
                interop="$lib_dir"
                break 2
            fi
        done
    done
fi

flags=()
if [ -n "$frameworks" ]; then
    flags+=(-Xswiftc -F -Xswiftc "$frameworks")
    flags+=(-Xlinker -F -Xlinker "$frameworks")
    flags+=(-Xlinker -rpath -Xlinker "$frameworks")
fi
if [ -n "$interop" ]; then
    flags+=(-Xlinker -rpath -Xlinker "$interop")
fi

# `swift test list` and `swift test --list-tests` print the test names instead of running
# them, so there is no summary line to check. Detect them and skip the zero-test guard.
# The options that take a separate value are listed so their values are not mistaken for
# arguments of their own.
list_mode=0
expect_value=0
for arg in "$@"; do
    if [ "$expect_value" = 1 ]; then
        expect_value=0
        continue
    fi
    case "$arg" in
        -l|--list-tests) list_mode=1 ;;
        list) list_mode=1 ;;
        -c|-d|-j|--filter|--skip|--scratch-path|--package-path|--cache-path|--config-path) expect_value=1 ;;
        --security-path|--swift-sdks-path|--toolset|--pkg-config-path|--num-workers|--xunit-output) expect_value=1 ;;
        --traits|--configuration|--sanitize|--swift-sdk|--manifest-cache|--toolchain|--sdk) expect_value=1 ;;
        --arch|--triple|--swift-version|--destination) expect_value=1 ;;
    esac
done

# The banner goes to stderr so it can never be mistaken for test output.
echo "==> swift test${frameworks:+ (Testing.framework from $frameworks)}" >&2

log="$(mktemp "${TMPDIR:-/tmp}/attic-tests.XXXXXX")"
trap 'rm -f "$log"' EXIT

set +e
swift test "${flags[@]+"${flags[@]}"}" "$@" 2>&1 | tee "$log"
status="${PIPESTATUS[0]}"
set -e

if [ "$status" -ne 0 ]; then
    echo "error: swift test failed (exit $status)" >&2
    exit "$status"
fi

if [ "$list_mode" = 1 ]; then
    exit 0
fi

# swift-testing prints "Test run with 56 tests in 12 suites passed" (newer toolchains) or
# "Test run with 56 tests passed after 12.3 seconds" (Swift 6.1); XCTest prints
# "Executed 56 tests, with 0 failures". Take the larger of the two counts.
swift_tests="$(sed -nE 's/.*Test run with ([0-9]+) tests?( |$).*/\1/p' "$log" | tail -n 1)"
xctest_tests="$(sed -nE 's/.*Executed ([0-9]+) tests?.*/\1/p' "$log" | tail -n 1)"

count=0
summary=0
for n in "$swift_tests" "$xctest_tests"; do
    if [ -n "$n" ]; then
        summary=1
        if [ "$n" -gt "$count" ]; then
            count="$n"
        fi
    fi
done

if [ "$summary" = 0 ]; then
    echo "error: no test summary was printed, so the test bundle ran no tests at all" >&2
    echo "       (the silent false pass: the runner compiled to a no-op and exited 0)" >&2
    exit 1
fi

if [ "$count" -eq 0 ]; then
    echo "error: the test run reported 0 tests" >&2
    exit 1
fi

echo "==> swift test ran $count tests" >&2
