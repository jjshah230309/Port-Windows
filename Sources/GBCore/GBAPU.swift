// Audio: two square channels (one with sweep), a wave channel and a noise channel, driven by a 512 Hz frame
// sequencer clocked from DIV, mixed and box-filtered down to 48 kHz stereo.

private let squarePatterns: [UInt8] = [0x80, 0x81, 0xE1, 0x7E]   // bit n = output at duty position n
private let noiseDivisors: [Int] = [8, 16, 32, 48, 64, 80, 96, 112]
private let outputRate = 48_000
private let cpuClock = 4_194_304

struct SquareChannel {
    var enabled = false
    var dac = false
    var duty = 0
    var dutyPos = 0
    var freq = 0
    var timer = 0
    var length = 0
    var lengthEnabled = false
    var volume = 0
    var envInitial = 0
    var envAdd = false
    var envPeriod = 0
    var envTimer = 0
    // Sweep (channel 1 only)
    var sweepPeriod = 0
    var sweepNegate = false
    var sweepShift = 0
    var sweepTimer = 0
    var sweepShadow = 0
    var sweepEnabled = false

    @inline(__always) var digital: Int {
        (enabled && dac) ? Int((squarePatterns[duty] >> UInt8(dutyPos)) & 1) * volume : 0
    }

    @inline(__always) mutating func step(_ dots: Int) {
        timer -= dots
        while timer <= 0 {
            timer += (2048 - freq) * 4
            dutyPos = (dutyPos + 1) & 7
        }
    }

    mutating func clockLength() {
        if lengthEnabled && length > 0 {
            length -= 1
            if length == 0 { enabled = false }
        }
    }

    mutating func clockEnvelope() {
        if envTimer > 0 { envTimer -= 1 }
        if envTimer == 0 {
            envTimer = envPeriod == 0 ? 8 : envPeriod
            if envPeriod != 0 {
                if envAdd && volume < 15 { volume += 1 } else if !envAdd && volume > 0 { volume -= 1 }
            }
        }
    }

    func sweepCalculation() -> Int {
        let delta = sweepShadow >> sweepShift
        return sweepNegate ? sweepShadow - delta : sweepShadow + delta
    }

    mutating func clockSweep() {
        if sweepTimer > 0 { sweepTimer -= 1 }
        if sweepTimer == 0 {
            sweepTimer = sweepPeriod == 0 ? 8 : sweepPeriod
            if sweepEnabled && sweepPeriod > 0 {
                let new = sweepCalculation()
                if new > 2047 {
                    enabled = false
                } else if sweepShift > 0 {
                    sweepShadow = new
                    freq = new
                    if sweepCalculation() > 2047 { enabled = false }
                }
            }
        }
    }

    mutating func trigger(hasSweep: Bool, nextStepClocksLength: Bool) {
        enabled = dac
        if length == 0 {
            length = 64
            if lengthEnabled && !nextStepClocksLength { length = 63 }
        }
        timer = (2048 - freq) * 4
        volume = envInitial
        envTimer = envPeriod == 0 ? 8 : envPeriod
        if hasSweep {
            sweepShadow = freq
            sweepTimer = sweepPeriod == 0 ? 8 : sweepPeriod
            sweepEnabled = sweepPeriod > 0 || sweepShift > 0
            if sweepShift > 0 && sweepCalculation() > 2047 { enabled = false }
        }
    }
}

struct WaveChannel {
    var enabled = false
    var dac = false
    var freq = 0
    var timer = 0
    var pos = 0
    var length = 0
    var lengthEnabled = false
    var volumeCode = 0
}

struct NoiseChannel {
    var enabled = false
    var dac = false
    var lfsr = 0x7FFF
    var timer = 0
    var length = 0
    var lengthEnabled = false
    var volume = 0
    var envInitial = 0
    var envAdd = false
    var envPeriod = 0
    var envTimer = 0
    var clockShift = 0
    var widthMode = false
    var divisorCode = 0

    @inline(__always) var period: Int { noiseDivisors[divisorCode] << clockShift }
    @inline(__always) var digital: Int { (enabled && dac) ? (~lfsr & 1) * volume : 0 }

    @inline(__always) mutating func step(_ dots: Int) {
        guard clockShift < 14 else { return }
        timer -= dots
        while timer <= 0 {
            timer += period
            let x = (lfsr & 1) ^ ((lfsr >> 1) & 1)
            lfsr = (lfsr >> 1) | (x << 14)
            if widthMode { lfsr = (lfsr & ~0x40) | (x << 6) }
        }
    }

    mutating func clockLength() {
        if lengthEnabled && length > 0 {
            length -= 1
            if length == 0 { enabled = false }
        }
    }

    mutating func clockEnvelope() {
        if envTimer > 0 { envTimer -= 1 }
        if envTimer == 0 {
            envTimer = envPeriod == 0 ? 8 : envPeriod
            if envPeriod != 0 {
                if envAdd && volume < 15 { volume += 1 } else if !envAdd && volume > 0 { volume -= 1 }
            }
        }
    }
}

struct APUState {
    var power = true
    var frameStep = 0
    var ch1 = SquareChannel()
    var ch2 = SquareChannel()
    var ch3 = WaveChannel()
    var ch4 = NoiseChannel()
    var nr50: UInt8 = 0
    var nr51: UInt8 = 0
}

/// Which bits read back as 1 for FF10...FF26 (unused or write-only bits).
private let readMasks: [UInt8] = [
    0x80, 0x3F, 0x00, 0xFF, 0xBF,
    0xFF, 0x3F, 0x00, 0xFF, 0xBF,
    0x7F, 0xFF, 0x9F, 0xFF, 0xBF,
    0xFF, 0xFF, 0x00, 0x00, 0xBF,
    0x00, 0x00, 0x70,
]

extension GameBoyCore {
    func apuPowerOnDefaults() {
        apu = APUState()
        for i in 0..<0x30 { apuRegs[i] = 0 }
        apuWrite(0xFF26, 0x80)
        let defaults: [(UInt16, UInt8)] = [
            (0xFF10, 0x80), (0xFF11, 0xBF), (0xFF12, 0xF3), (0xFF13, 0xFF), (0xFF14, 0xBF),
            (0xFF16, 0x3F), (0xFF17, 0x00), (0xFF18, 0xFF), (0xFF19, 0xBF),
            (0xFF1A, 0x7F), (0xFF1B, 0xFF), (0xFF1C, 0x9F), (0xFF1D, 0xFF), (0xFF1E, 0xBF),
            (0xFF20, 0xFF), (0xFF21, 0x00), (0xFF22, 0x00), (0xFF23, 0xBF),
            (0xFF24, 0x77), (0xFF25, 0xF3),
        ]
        for (addr, v) in defaults { apuWrite(addr, v) }
        apu.ch1.enabled = true      // the boot sequence leaves channel 1 flagged as playing (NR52 = $F1)
        apu.ch1.volume = 0
        apuSamplePhase = 0; apuAccumL = 0; apuAccumR = 0; apuAccumCount = 0
    }

    // MARK: Register access

    func apuRead(_ addr: UInt16) -> UInt8 {
        if addr >= 0xFF30 {
            if apu.ch3.enabled { return apuRegs[0x20 + (apu.ch3.pos >> 1)] }
            return apuRegs[Int(addr) - 0xFF10]
        }
        if addr > 0xFF26 { return 0xFF }
        if addr == 0xFF26 {
            var v: UInt8 = 0x70
            if apu.power { v |= 0x80 }
            if apu.ch1.enabled { v |= 1 }
            if apu.ch2.enabled { v |= 2 }
            if apu.ch3.enabled { v |= 4 }
            if apu.ch4.enabled { v |= 8 }
            return v
        }
        return apuRegs[Int(addr) - 0xFF10] | readMasks[Int(addr) - 0xFF10]
    }

    @inline(__always) var nextStepClocksLength: Bool { apu.frameStep & 1 == 0 }

    func apuWrite(_ addr: UInt16, _ v: UInt8) {
        if addr >= 0xFF30 {
            apuRegs[Int(addr) - 0xFF10] = v
            return
        }
        if addr == 0xFF26 {
            let on = v & 0x80 != 0
            if on && !apu.power {
                apu.power = true
                apu.frameStep = 0
            } else if !on && apu.power {
                for i in 0..<0x16 { apuRegs[i] = 0 }
                let c1 = apu.ch1.length, c2 = apu.ch2.length, c3 = apu.ch3.length, c4 = apu.ch4.length
                apu = APUState()
                apu.power = false
                if !isCGB {      // DMG keeps length counters across power cycles
                    apu.ch1.length = c1; apu.ch2.length = c2; apu.ch3.length = c3; apu.ch4.length = c4
                }
            }
            return
        }
        if !apu.power {
            if !isCGB {
                switch addr {      // length counters stay writable on DMG while powered off
                case 0xFF11: apu.ch1.length = 64 - Int(v & 0x3F)
                case 0xFF16: apu.ch2.length = 64 - Int(v & 0x3F)
                case 0xFF1B: apu.ch3.length = 256 - Int(v)
                case 0xFF20: apu.ch4.length = 64 - Int(v & 0x3F)
                default: break
                }
            }
            return
        }
        guard addr >= 0xFF10 else { return }
        apuRegs[Int(addr) - 0xFF10] = v
        switch addr {
        case 0xFF10:
            apu.ch1.sweepPeriod = Int((v >> 4) & 7)
            apu.ch1.sweepNegate = v & 8 != 0
            apu.ch1.sweepShift = Int(v & 7)
        case 0xFF11:
            apu.ch1.duty = Int(v >> 6)
            apu.ch1.length = 64 - Int(v & 0x3F)
        case 0xFF12: writeEnvelope(&apu.ch1, v)
        case 0xFF13: apu.ch1.freq = (apu.ch1.freq & 0x700) | Int(v)
        case 0xFF14:
            apu.ch1.freq = (apu.ch1.freq & 0xFF) | (Int(v & 7) << 8)
            squareLengthAndTrigger(&apu.ch1, v, hasSweep: true)
        case 0xFF16:
            apu.ch2.duty = Int(v >> 6)
            apu.ch2.length = 64 - Int(v & 0x3F)
        case 0xFF17: writeEnvelope(&apu.ch2, v)
        case 0xFF18: apu.ch2.freq = (apu.ch2.freq & 0x700) | Int(v)
        case 0xFF19:
            apu.ch2.freq = (apu.ch2.freq & 0xFF) | (Int(v & 7) << 8)
            squareLengthAndTrigger(&apu.ch2, v, hasSweep: false)
        case 0xFF1A:
            apu.ch3.dac = v & 0x80 != 0
            if !apu.ch3.dac { apu.ch3.enabled = false }
        case 0xFF1B: apu.ch3.length = 256 - Int(v)
        case 0xFF1C: apu.ch3.volumeCode = Int((v >> 5) & 3)
        case 0xFF1D: apu.ch3.freq = (apu.ch3.freq & 0x700) | Int(v)
        case 0xFF1E:
            apu.ch3.freq = (apu.ch3.freq & 0xFF) | (Int(v & 7) << 8)
            let wasEnabled = apu.ch3.lengthEnabled
            apu.ch3.lengthEnabled = v & 0x40 != 0
            if !wasEnabled && apu.ch3.lengthEnabled && !nextStepClocksLength && apu.ch3.length > 0 {
                apu.ch3.length -= 1
                if apu.ch3.length == 0 && v & 0x80 == 0 { apu.ch3.enabled = false }
            }
            if v & 0x80 != 0 {
                apu.ch3.enabled = apu.ch3.dac
                if apu.ch3.length == 0 {
                    apu.ch3.length = 256
                    if apu.ch3.lengthEnabled && !nextStepClocksLength { apu.ch3.length = 255 }
                }
                apu.ch3.timer = (2048 - apu.ch3.freq) * 2 + 6
                apu.ch3.pos = 0
            }
        case 0xFF20: apu.ch4.length = 64 - Int(v & 0x3F)
        case 0xFF21:
            apu.ch4.envInitial = Int(v >> 4)
            apu.ch4.envAdd = v & 8 != 0
            apu.ch4.envPeriod = Int(v & 7)
            apu.ch4.dac = v & 0xF8 != 0
            if !apu.ch4.dac { apu.ch4.enabled = false }
        case 0xFF22:
            apu.ch4.clockShift = Int(v >> 4)
            apu.ch4.widthMode = v & 8 != 0
            apu.ch4.divisorCode = Int(v & 7)
        case 0xFF23:
            let wasEnabled = apu.ch4.lengthEnabled
            apu.ch4.lengthEnabled = v & 0x40 != 0
            if !wasEnabled && apu.ch4.lengthEnabled && !nextStepClocksLength && apu.ch4.length > 0 {
                apu.ch4.length -= 1
                if apu.ch4.length == 0 && v & 0x80 == 0 { apu.ch4.enabled = false }
            }
            if v & 0x80 != 0 {
                apu.ch4.enabled = apu.ch4.dac
                if apu.ch4.length == 0 {
                    apu.ch4.length = 64
                    if apu.ch4.lengthEnabled && !nextStepClocksLength { apu.ch4.length = 63 }
                }
                apu.ch4.timer = apu.ch4.period
                apu.ch4.lfsr = 0x7FFF
                apu.ch4.volume = apu.ch4.envInitial
                apu.ch4.envTimer = apu.ch4.envPeriod == 0 ? 8 : apu.ch4.envPeriod
            }
        case 0xFF24: apu.nr50 = v
        case 0xFF25: apu.nr51 = v
        default: break
        }
    }

    private func writeEnvelope(_ ch: inout SquareChannel, _ v: UInt8) {
        ch.envInitial = Int(v >> 4)
        ch.envAdd = v & 8 != 0
        ch.envPeriod = Int(v & 7)
        ch.dac = v & 0xF8 != 0
        if !ch.dac { ch.enabled = false }
    }

    private func squareLengthAndTrigger(_ ch: inout SquareChannel, _ v: UInt8, hasSweep: Bool) {
        let wasEnabled = ch.lengthEnabled
        ch.lengthEnabled = v & 0x40 != 0
        if !wasEnabled && ch.lengthEnabled && !nextStepClocksLength && ch.length > 0 {
            ch.length -= 1
            if ch.length == 0 && v & 0x80 == 0 { ch.enabled = false }
        }
        if v & 0x80 != 0 { ch.trigger(hasSweep: hasSweep, nextStepClocksLength: nextStepClocksLength) }
    }

    // MARK: Frame sequencer

    func apuFrameSequencerStep() {
        guard apu.power else { return }
        let step = apu.frameStep
        if step & 1 == 0 {
            apu.ch1.clockLength(); apu.ch2.clockLength(); clockWaveLength(); apu.ch4.clockLength()
        }
        if step == 2 || step == 6 { apu.ch1.clockSweep() }
        if step == 7 {
            apu.ch1.clockEnvelope(); apu.ch2.clockEnvelope(); apu.ch4.clockEnvelope()
        }
        apu.frameStep = (step + 1) & 7
    }

    private func clockWaveLength() {
        if apu.ch3.lengthEnabled && apu.ch3.length > 0 {
            apu.ch3.length -= 1
            if apu.ch3.length == 0 { apu.ch3.enabled = false }
        }
    }

    // MARK: Per-M-cycle advance and mixing

    @inline(__always) func apuAdvance(_ dots: Int) {
        var left = 0, right = 0
        if apu.power {
            apu.ch1.step(dots)
            apu.ch2.step(dots)
            // Wave channel: advance through the 32 four-bit samples.
            apu.ch3.timer -= dots
            while apu.ch3.timer <= 0 {
                apu.ch3.timer += (2048 - apu.ch3.freq) * 2
                apu.ch3.pos = (apu.ch3.pos + 1) & 31
            }
            apu.ch4.step(dots)

            let n51 = apu.nr51
            var s1 = 0, s2 = 0, s3 = 0, s4 = 0
            if apu.ch1.dac { s1 = apu.ch1.digital * 2 - 15 }
            if apu.ch2.dac { s2 = apu.ch2.digital * 2 - 15 }
            if apu.ch3.dac {
                var sample = 0
                if apu.ch3.enabled {
                    let byte = apuRegs[0x20 + (apu.ch3.pos >> 1)]
                    sample = Int(apu.ch3.pos & 1 == 0 ? byte >> 4 : byte & 0x0F)
                    switch apu.ch3.volumeCode {
                    case 0: sample = 0
                    case 1: break
                    case 2: sample >>= 1
                    default: sample >>= 2
                    }
                }
                s3 = sample * 2 - 15
            }
            if apu.ch4.dac { s4 = apu.ch4.digital * 2 - 15 }
            if n51 & 0x10 != 0 { left += s1 }
            if n51 & 0x20 != 0 { left += s2 }
            if n51 & 0x40 != 0 { left += s3 }
            if n51 & 0x80 != 0 { left += s4 }
            if n51 & 0x01 != 0 { right += s1 }
            if n51 & 0x02 != 0 { right += s2 }
            if n51 & 0x04 != 0 { right += s3 }
            if n51 & 0x08 != 0 { right += s4 }
            left *= (Int((apu.nr50 >> 4) & 7) + 1) * 64
            right *= (Int(apu.nr50 & 7) + 1) * 64
        }
        apuAccumL &+= left * dots
        apuAccumR &+= right * dots
        apuAccumCount &+= dots
        apuSamplePhase &+= dots * outputRate
        if apuSamplePhase >= cpuClock {
            apuSamplePhase -= cpuClock
            if audioCount + 2 <= audioCapacity {
                audioBuf[audioCount] = Int16(clamping: apuAccumL / max(apuAccumCount, 1))
                audioBuf[audioCount + 1] = Int16(clamping: apuAccumR / max(apuAccumCount, 1))
                audioCount += 2
            }
            apuAccumL = 0; apuAccumR = 0; apuAccumCount = 0
        }
    }
}
