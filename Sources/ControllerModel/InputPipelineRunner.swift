import EmulatorKit

/// Runs raw controller state through the input pipeline, keeping the two pieces of state that
/// have to survive from one frame to the next: the trigger hysteresis, and the emulated frame
/// number the turbo settings count on.
///
/// A value type, so the caller keeps it behind whatever lock it already has. Running the
/// pipeline without this would reset the trigger on every frame and leave the turbo buttons
/// stuck on whichever phase they started in.
public struct InputPipelineRunner: Sendable {
    /// The live pipeline, including the trigger states it is currently holding.
    public private(set) var pipeline: InputPipeline
    /// The emulated frame the turbo settings count on. It advances once per processed frame.
    public private(set) var frame: Int = 0

    public init(pipeline: InputPipeline = InputPipeline()) {
        self.pipeline = pipeline
    }

    /// Replaces the settings. The frame counter is kept, because turbo is relative to the frame
    /// and a settings change should not restart the rhythm; the trigger states are reset,
    /// because they were measured against thresholds that have just moved.
    public mutating func update(pipeline newPipeline: InputPipeline) {
        pipeline = newPipeline
    }

    /// Runs one frame of raw state through the pipeline and counts the frame.
    public mutating func process(_ raw: RawControllerState) -> InputSnapshot {
        let snapshot = pipeline.process(raw, frame: frame)
        frame &+= 1
        return snapshot
    }

    /// The number of frames processed so far. The frame counter the runner uses is the one
    /// before the increment, so this is one past the frame the last snapshot was produced for.
    public var framesProcessed: Int { frame }
}
