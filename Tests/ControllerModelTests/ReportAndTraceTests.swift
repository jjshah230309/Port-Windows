import Testing
import EmuSupport
import EmulatorKit
@testable import ControllerModel

@Suite struct ReportAndTraceTests {
    @Test func sonyCRCRoundTrip() {
        let body: [UInt8] = [0x31, 0x02, 0x0F, 0x15, 0x00, 0x40]
        let report = SonyReports.appendingCRC(seed: SonyReports.outputSeed, to: body)
        #expect(report.count == body.count + 4)
        #expect(SonyReports.verifyCRC(seed: SonyReports.outputSeed, report: report))
        #expect(!SonyReports.verifyCRC(seed: SonyReports.inputSeed, report: report))
        var bad = report
        bad[2] ^= 0x01
        #expect(!SonyReports.verifyCRC(seed: SonyReports.outputSeed, report: bad))
    }

    @Test func crcMatchesSeedPlusPayload() {
        let payload: [UInt8] = [1, 2, 3]
        #expect(SonyReports.crc(seed: 0xA2, payload: payload[...]) == CRC32.checksum([0xA2, 1, 2, 3]))
    }

    @Test func traceRoundTrip() throws {
        var a = RawControllerState()
        a.buttons = PadButtons([.east, .l1]).rawValue
        a.leftStick = SIMD2(0.25, -0.75)
        a.rightTrigger = 0.5
        let trace = ControllerTrace(frames: [a, RawControllerState()])
        #expect(try ControllerTrace.parse(trace.serialized()) == trace)
    }

    @Test func traceRejectsBadInput() {
        #expect(throws: TraceError.badHeader) { _ = try ControllerTrace.parse("nonsense\n") }
        #expect(throws: TraceError.badLine(2)) {
            _ = try ControllerTrace.parse("\(ControllerTrace.header)\n1 2 3\n")
        }
    }

    @Test func replayHoldsLastFrame() {
        var a = RawControllerState()
        a.buttons = 7
        var r = TraceReplayer(trace: ControllerTrace(frames: [a]))
        #expect(r.nextFrame().buttons == 7)
        #expect(r.isFinished)
        #expect(r.nextFrame().buttons == 7)
    }

    @Test func mailboxPublishesLatest() {
        let box = InputMailbox()
        #expect(box.latest().sequence == 0)
        var s = RawControllerState()
        s.buttons = 5
        box.publish(s)
        let got = box.latest()
        #expect(got.sequence == 1 && got.state.buttons == 5)
        let out = OutputMailbox()
        out.set(low: 0.5, high: 1)
        #expect(out.current().rumbleLow == 0.5 && out.current().rumbleHigh == 1)
    }

    @Test func capabilityNames() {
        let caps: ControllerCapabilities = [.rumble, .adaptiveTriggers]
        #expect(caps.names == ["rumble", "adaptive triggers"])
    }
}
