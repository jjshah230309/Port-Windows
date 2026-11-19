/// Static description of an emulated system. Labels are deliberately neutral (no console trademarks).
public struct SystemInfo: Sendable, Equatable {
    public var id: String
    public var label: String
    public var width: Int
    public var height: Int
    public var fpsNumerator: Int
    public var fpsDenominator: Int
    public var audioRate: Int
    public var padPorts: Int

    public init(id: String, label: String, width: Int, height: Int,
                fpsNumerator: Int, fpsDenominator: Int, audioRate: Int, padPorts: Int = 1) {
        self.id = id
        self.label = label
        self.width = width
        self.height = height
        self.fpsNumerator = fpsNumerator
        self.fpsDenominator = fpsDenominator
        self.audioRate = audioRate
        self.padPorts = padPorts
    }

    public var framesPerSecond: Double { Double(fpsNumerator) / Double(fpsDenominator) }
}
