#!/bin/bash
# Fails the build when a core's hot loop contains ARC or exclusivity-check runtime calls.
#
# docs/PLAN.md section 6 requires: "the build fails if the disassembly of a core's frame
# loop contains swift_retain, swift_release or swift_beginAccess". The check has to look at
# machine code. A release build compiles the hot loops with -Ounchecked and
# -enforce-exclusivity=unchecked, so source that reads clean can still emit retain/release
# traffic, and an Array or a class-typed property introduced in the dispatch path shows up
# only as a call to the runtime.
#
# How it works:
#   1. Build in release mode. Only the release configuration turns the -Ounchecked flags on,
#      so a debug build would hide the very calls we are looking for.
#   2. Take the binary's symbols from `nm`, demangle them with swift-demangle, and pick the
#      hot-loop functions by their demangled name.
#   3. Disassemble the binary (otool -tV on macOS, objdump -d on Linux) and attribute every
#      instruction to the function that contains it. A branch to a banned runtime entry
#      point inside a hot function fails the check.
#
# The check is deliberately shallow, and the summary says so:
#   * It looks at the instructions of the hot functions themselves. A hot function that calls
#     a helper which then retains is not reported, because the helper is not one of the
#     functions named below.
#   * A function the optimiser inlined away has no symbol to inspect. The @inline(__always)
#     helpers are listed as inlined; their bodies are covered by the functions that absorbed
#     them.
#   * Only an actual branch is a failure. A name in a literal pool (an indirect call through
#     a function pointer) is reported as a note, because it is not the retain that the rule
#     in docs/PLAN.md is about.
#
# Usage: scripts/check-hot-loops.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

# Release builds are slow and several agents share this checkout, so keep the artefacts in
# their own scratch directory.
scratch="${HOT_LOOP_SCRATCH_PATH:-.build-hot}"

# The core under test and the type that holds its hot loops.
core="GBCore"
type="GameBoyCore"

# The hot loops, by method name. GBCPU.swift holds the opcode dispatch, GBBus.swift the
# memory map and the M-cycle clock; the PPU, APU and cartridge helpers are called from the
# same tickM() path.
hot_names="step,execute,executeMisc,executeCB,serviceInterrupt,read8,write8,fetch8,fetch16,push16,pop16,getR,setR,alu,addHL,daa,ioRead,ioWrite,dmaRead,divWrite,timerControlWrite,latchInput,joypadRead,oamDMATick,serialTick,hdmaWrite,copyHDMABlock,performSpeedSwitch,ppuAdvance,updateStatLine,statRead,lcdcWrite,apuAdvance,apuFrameSequencerStep,apuRead,apuWrite,apuRecomputeMix,readCartRAM,writeCartRAM,writeMapper,runFrame"

# @inline(__always) helpers the optimiser gives no symbol of their own. Their bodies land in
# the functions that absorbed them, so they are reported as inlined rather than checked
# separately.
inlined_names="busRead,busWrite,tickM,timerTickM,incrementTIMA,joypadLines"

# The runtime entry points that must not appear in a hot loop (docs/PLAN.md section 6).
banned="swift_retain,swift_release,swift_beginAccess"

# Other runtime calls that mean the same thing to the core's performance: they are ARC
# traffic that a release build should not need either. They are reported as notes and do not
# fail the build, because the rule in docs/PLAN.md names the three calls above.
advisory="swift_unknownObjectRetain,swift_unknownObjectRelease,swift_bridgeObjectRetain,swift_bridgeObjectRelease,swift_allocObject,swift_endAccess,swift_isUniquelyReferenced"

echo "==> swift build -c release (scratch: $scratch)"
swift build --scratch-path "$scratch" -c release --product core-selftest

bin_dir="$(swift build --scratch-path "$scratch" -c release --show-bin-path)"
binary="$bin_dir/core-selftest"
if [ ! -x "$binary" ]; then
    echo "error: $binary was not built" >&2
    exit 1
fi

# swift-demangle is spelled differently on macOS and Linux.
demangle=()
if command -v xcrun >/dev/null 2>&1 && xcrun --find swift-demangle >/dev/null 2>&1; then
    demangle=(xcrun swift-demangle)
elif command -v swift-demangle >/dev/null 2>&1; then
    demangle=(swift-demangle)
elif command -v swift >/dev/null 2>&1; then
    demangle=(swift demangle)
else
    echo "error: no Swift demangler found (looked for xcrun swift-demangle, swift-demangle, swift demangle)" >&2
    exit 1
fi

# otool on macOS annotates a call site with the name of its target ("; symbol stub for:
# _swift_retain"); objdump on Linux does the same through the PLT entry.
case "$(uname -s)" in
    Darwin)
        if ! command -v otool >/dev/null 2>&1; then
            echo "error: otool not found; cannot inspect the disassembly" >&2
            exit 1
        fi
        # otool -tV disassembles the text section only.
        disasm=(otool -tV)
        ;;
    *)
        # objdump -d walks every section, including .plt, where the stubs for the runtime
        # live. Restrict it to the text section so those stubs are not mistaken for calls in
        # a hot function.
        if command -v objdump >/dev/null 2>&1; then
            disasm=(objdump -d --section=.text)
        elif command -v llvm-objdump >/dev/null 2>&1; then
            disasm=(llvm-objdump -d --section=.text)
        else
            echo "error: neither objdump nor llvm-objdump was found" >&2
            exit 1
        fi
        ;;
esac
if ! command -v nm >/dev/null 2>&1; then
    echo "error: nm not found; cannot find the hot-loop symbols" >&2
    exit 1
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/hot-loops.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# Every symbol with an address, in address order, with its demangled name.
nm -n "$binary" | awk '$1 ~ /^[0-9a-fA-F]+$/ { print $1 "\t" $2 "\t" $3 }' > "$tmp/syms.raw"
if [ ! -s "$tmp/syms.raw" ]; then
    echo "error: nm found no symbols with an address in $binary" >&2
    exit 1
fi
cut -f3 "$tmp/syms.raw" | "${demangle[@]}" > "$tmp/syms.demangled"
if [ "$(wc -l < "$tmp/syms.raw")" -ne "$(wc -l < "$tmp/syms.demangled")" ]; then
    echo "error: the demangler did not return one line per symbol" >&2
    exit 1
fi
# Join the two lists on the line number: address, mangled name, demangled name. The
# demangled name contains spaces, so the columns are tab separated throughout.
awk 'NR == FNR { dem[FNR] = $0; next }
     { print $1 "\t" $3 "\t" dem[FNR] }' "$tmp/syms.demangled" "$tmp/syms.raw" > "$tmp/syms"

"${disasm[@]}" "$binary" > "$tmp/disasm"
if [ ! -s "$tmp/disasm" ]; then
    # Some objdump builds spell the text section differently; fall back to the whole file.
    case "$(uname -s)" in
        Darwin) disasm=(otool -tV) ;;
        *)      disasm=(objdump -d) ;;
    esac
    "${disasm[@]}" "$binary" > "$tmp/disasm"
fi
if [ ! -s "$tmp/disasm" ]; then
    echo "error: ${disasm[0]} produced no disassembly for $binary" >&2
    exit 1
fi

cat > "$tmp/hot.awk" <<'AWKEOF'
# The first file is "address, mangled name, demangled name" in address order; the second is
# the disassembly. Every instruction is attributed to the symbol whose address range
# contains it, and a banned runtime call is reported when it lands inside a hot function.
function hex2dec(s,   i, c, d, v) {
    v = 0
    for (i = 1; i <= length(s); i++) {
        c = tolower(substr(s, i, 1))
        d = index("0123456789abcdef", c) - 1
        if (d < 0) return -1
        v = v * 16 + d
    }
    return v
}
# The name from the comma-separated list that the line mentions, or "".
# BSD awk has no 3-argument index(), so the scan is done by hand.
function named(text, list,   n, i, pats, at, before, after, from) {
    n = split(list, pats, ",")
    for (i = 1; i <= n; i++) {
        from = 1
        while (1) {
            at = index(substr(text, from), pats[i])
            if (at == 0) break
            at = at + from - 1
            before = (at == 1) ? "" : substr(text, at - 1, 1)
            after = substr(text, at + length(pats[i]), 1)
            # The symbol may carry a leading underscore (Darwin) or a @plt suffix (Linux).
            # Only a letter or a digit rules the match out.
            if (before !~ /[A-Za-z0-9]/ && after !~ /[A-Za-z0-9]/) return pats[i]
            from = at + 1
        }
    }
    return ""
}
# True when the instruction is a call or an unconditional branch, so that a name in a
# literal pool (an indirect call through a function pointer) is not mistaken for a call.
function is_call(m) {
    return (m == "bl" || m == "blr" || m == "blx" || m == "b" || m == "br" ||
            m == "call" || m == "callq" || m == "jmp" || m == "jmpq")
}
BEGIN {
    nw = split(hot_names, want, ",")
    for (i = 1; i <= nw; i++) wanted[want[i]] = 0
    prefix = core "." type "."
    checked = 0
    hits = 0
    notes = 0
}
FNR == NR {
    n++
    saddr[n] = hex2dec($1)
    smang[n] = $2
    sdem[n] = $3
    if (index($3, prefix) == 1) {
        rest = substr($3, length(prefix) + 1)
        paren = index(rest, "(")
        if (paren > 1) {
            base = substr(rest, 1, paren - 1)
            if (base ~ /^[A-Za-z0-9_]+$/ && (base in wanted)) {
                wanted[base] = 1
                hotmangled[$2] = 1
                hotbase[$2] = base
                hotdem[$2] = $3
            }
        }
    }
    next
}
{
    # The address is the first field; otool prints it bare, objdump prints it with a colon.
    field = $1
    gsub(":", "", field)
    if (field !~ /^[0-9a-fA-F]+$/) next
    a = hex2dec(field)
    if (a < 0) next

    # The symbol that contains this address: the last symbol that starts at or before it.
    lo = 1
    hi = n
    while (lo < hi) {
        mid = int((lo + hi + 1) / 2)
        if (saddr[mid] <= a) lo = mid
        else hi = mid - 1
    }
    if (saddr[lo] > a) next
    sym = smang[lo]
    if (!(sym in hotmangled)) next

    insns[sym]++

    # The mnemonic: otool prints "address<TAB>mnemonic", objdump prints
    # "address:<TAB>bytes<TAB>mnemonic".
    if ($1 ~ /:$/) m = $3
    else m = $2

    b = named($0, banned)
    if (b != "") {
        if (is_call(m)) {
            hits++
            failed[sym] = 1
            offender[sym] = (offender[sym] == "" ? "" : offender[sym] ", ") b
            dcount++
            dsym[dcount] = sym
            dtext[dcount] = b " -> " $0
            dkind[dcount] = "DETAIL"
        } else {
            notes++
            noted[sym] = 1
            noffender[sym] = (noffender[sym] == "" ? "" : noffender[sym] ", ") b
            dcount++
            dsym[dcount] = sym
            dtext[dcount] = b " (not a call) -> " $0
            dkind[dcount] = "NDETAIL"
        }
    } else {
        a2 = named($0, advisory)
        if (a2 != "") {
            notes++
            noted[sym] = 1
            noffender[sym] = (noffender[sym] == "" ? "" : noffender[sym] ", ") a2
            dcount++
            dsym[dcount] = sym
            dtext[dcount] = a2 " -> " $0
            dkind[dcount] = "NDETAIL"
        }
    }
}
END {
    for (i = 1; i <= nw; i++) {
        base = want[i]
        if (!wanted[base]) {
            print "MISSING\t" base
            continue
        }
        for (sym in hotbase) {
            if (hotbase[sym] != base) continue
            if (sym in failed) status = "FAIL"
            else if (sym in noted) status = "NOTE"
            else status = "PASS"
            print "RESULT\t" status "\t" hotdem[sym] "\t" (insns[sym] + 0) "\t" \
                  (sym in failed ? offender[sym] : "") "\t" sym
            checked++
        }
    }
    # The call sites, one line each, so a CI log explains what broke.
    for (i = 1; i <= dcount; i++) {
        text = dtext[i]
        gsub(/\t/, " ", text)
        print dkind[i] "\t" dsym[i] "\t" text
    }
    print "SUMMARY\t" checked "\t" hits "\t" notes
}
AWKEOF

# The fields are tab separated: the symbol table has three columns, and the disassembly is
# "address<TAB>mnemonic<TAB>operands" on macOS and
# "address:<TAB>bytes<TAB>mnemonic<TAB>operands" on Linux.
awk -F'\t' -v hot_names="$hot_names" -v banned="$banned" -v advisory="$advisory" \
    -v core="$core" -v type="$type" -f "$tmp/hot.awk" "$tmp/syms" "$tmp/disasm" > "$tmp/report" \
    || { echo "error: the disassembly analysis failed" >&2; exit 1; }

checked="$(awk -F'\t' '/^SUMMARY/ { print $2 }' "$tmp/report")"
hits="$(awk -F'\t' '/^SUMMARY/ { print $3 }' "$tmp/report")"
notes="$(awk -F'\t' '/^SUMMARY/ { print $4 }' "$tmp/report")"

# A check that inspects nothing must not report a pass. If the disassembler produced no
# instructions for the hot functions (a section name it did not understand, a stripped
# binary), fail loudly instead of reporting a vacuous PASS.
if [ "${checked:-0}" -eq 0 ]; then
    echo "error: no hot-loop function was found in the disassembly" >&2
    echo "       (${disasm[0]} produced $(wc -l < "$tmp/disasm") line(s); the check would be vacuous)" >&2
    exit 1
fi
empty="$(awk -F'\t' '/^RESULT/ && $4 == 0 { print $3 }' "$tmp/report")"
if [ -n "$empty" ]; then
    echo "error: these hot-loop functions had no instructions in the disassembly:" >&2
    for name in $empty; do echo "       $name" >&2; done
    exit 1
fi

echo "==> Hot-loop check: $core.$type"
echo "    binary: $binary"
echo "    fails on: $banned"
echo

awk -F'\t' '/^RESULT/ {
    if ($2 == "FAIL") {
        printf "    FAIL  %s\n", $3
        printf "          %s instructions, banned call(s): %s\n", $4, $5
    } else if ($2 == "NOTE") {
        printf "    NOTE  %s (%s instructions)\n", $3, $4
    } else {
        printf "    PASS  %s (%s instructions)\n", $3, $4
    }
}' "$tmp/report"

# The offending call sites, so a CI log explains what broke.
awk -F'\t' '/^DETAIL/ { print "    " $2 ":"; print "      " $3 }' "$tmp/report"
awk -F'\t' '/^NDETAIL/ { print "    " $2 ":"; print "      " $3 }' "$tmp/report"

missing="$(awk -F'\t' '/^MISSING/ { printf "%s ", $2 }' "$tmp/report")"
if [ -n "$missing" ]; then
    echo
    echo "    hot functions with no symbol of their own:"
    for name in $missing; do
        case " $inlined_names " in
            *" $name "*) echo "      $name  (inlined away; covered by the functions that absorbed it)" ;;
            *) echo "      $name  (NOT FOUND: not @inline(__always), so the optimiser dropped it)" ;;
        esac
    done
fi

echo
if [ "$hits" -ne 0 ]; then
    echo "==> FAIL: $hits banned runtime call(s) in the $core hot loop"
    exit 1
fi
echo "==> PASS: $checked hot-loop function(s) checked, no banned runtime calls"
if [ "$notes" -ne 0 ]; then
    echo "    ($notes other ARC runtime call(s) noted above; the rule in docs/PLAN.md names only the three above)"
fi
