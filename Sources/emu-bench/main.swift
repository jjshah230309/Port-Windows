import CoreTestSupport
import EmulatorKit
import Foundation
import GBCore

// Throughput benchmark: emu-bench gb <rom> [--frames N] [--model dmg|cgb]
// Prints emulated frames per second and the multiple of real time (native rate: 4194304 / 70224 = 59.7275 fps).
let args = CommandLine.arguments
guard args.count >= 3, args[1] == "gb" else {
    print("usage: emu-bench gb <rom> [--frames N] [--model dmg|cgb]")
    exit(2)
}
var frames = 6_000
var model = "auto"
if let j = args.firstIndex(of: "--frames"), j + 1 < args.count { frames = Int(args[j + 1]) ?? frames }
if let j = args.firstIndex(of: "--model"), j + 1 < args.count { model = args[j + 1] }

do {
    let rom = [UInt8](try Data(contentsOf: URL(fileURLWithPath: args[2])))
    let core = try GameBoyCore(media: .rom(rom), firmware: FirmwareSet(), options: CoreOptions(values: ["model": model]),
                               clock: SystemClock())
    let input = ScriptedInput(), output = NullOutput()
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<frames {
        core.runFrame(input: input, output: output)
        core.drainAudio { _ in }
    }
    let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    let fps = Double(frames) / seconds
    print(String(format: "%d frames in %.2fs = %.0f fps = %.1fx real time", frames, seconds, fps, fps / GameBoyCore.info.framesPerSecond))
} catch {
    print("error: \(error)")
    exit(2)
}
