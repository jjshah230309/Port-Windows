#!/bin/bash
# Downloads freely redistributable Game Boy test ROMs into .cache/test-roms (never committed), verifying SHA-256.
#   scripts/fetch-test-roms.sh            dmg-acid2, cgb-acid2 (MIT) and the Mooneye test suite (MIT)
#   scripts/fetch-test-roms.sh --blargg   additionally Blargg's test ROMs (no explicit license: local use only)
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
dest="$root/.cache/test-roms"
mkdir -p "$dest/acid2" "$dest/blargg" "$dest/mooneye"

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

# fetch <url> <output> <sha256>
fetch() {
  local url="$1" out="$2" want="$3"
  if [ -f "$out" ] && [ "$(sha256 "$out")" = "$want" ]; then return 0; fi
  for attempt in 1 2 3 4; do
    if curl -fsSL --max-time 120 -o "$out.part" "$url"; then break; fi
    echo "retry $attempt for $url" >&2; sleep $((attempt * 2))
  done
  local got; got="$(sha256 "$out.part")"
  if [ "$got" != "$want" ]; then echo "checksum mismatch for $url: got $got, want $want" >&2; rm -f "$out.part"; exit 1; fi
  mv "$out.part" "$out"
}

fetch "https://github.com/mattcurrie/dmg-acid2/releases/download/v1.0/dmg-acid2.gb" \
  "$dest/acid2/dmg-acid2.gb" 464e14b7d42e7feea0b7ede42be7071dc88913f75b9ffa444299424b63d1dff1
fetch "https://github.com/mattcurrie/cgb-acid2/releases/download/v1.1/cgb-acid2.gbc" \
  "$dest/acid2/cgb-acid2.gbc" 197fb0bcec544f0400527fc707e0a94f55435974986e6986b424ace5de81720e

mts="mts-20240926-1737-443f6e1"
fetch "https://gekkio.fi/files/mooneye-test-suite/$mts/$mts.zip" \
  "$dest/mooneye/mts.zip" 5cf50314cd3d42ec8f423b0a71b9ab6dbfad2386d8d88f03687af1b5b5baba71
if [ ! -d "$dest/mooneye/$mts" ]; then unzip -q -o "$dest/mooneye/mts.zip" -d "$dest/mooneye"; fi

if [ "${1:-}" = "--blargg" ]; then
  base="https://raw.githubusercontent.com/retrio/gb-test-roms/master"
  fetch "$base/cpu_instrs/cpu_instrs.gb" "$dest/blargg/cpu_instrs.gb" 8c5e12f41e0ba5bbca796944f92ffe6de28809198682c4332e38d1b3cf56fcf2
  fetch "$base/instr_timing/instr_timing.gb" "$dest/blargg/instr_timing.gb" 646067b3d6c79fda810e9c3f1cb7c0efd5abb0a7ac06437c54e65720c15d9925
  fetch "$base/mem_timing/mem_timing.gb" "$dest/blargg/mem_timing.gb" 791cb418fd054b482a6ada5017e2405b96c2373a0f3914c6b23afeee76fa98ce
  fetch "$base/mem_timing-2/mem_timing.gb" "$dest/blargg/mem_timing-2.gb" ab9daf4c51f417c468ad0a61dab66872cf8b5a50e6eb08d989b581d15f3cf461
fi
echo "Test ROMs ready in $dest"
