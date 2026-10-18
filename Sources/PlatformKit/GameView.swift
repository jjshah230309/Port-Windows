#if canImport(MetalKit)
import AppKit
import Metal
import MetalKit

public enum ScalingMode: Int, Sendable {
    /// Whole-number scale factors only: perfectly sharp pixels with black borders.
    case integer = 0
    /// Integer-prescaled with a thin blend at pixel edges: sharp, but fills the window.
    case sharpBilinear = 1
}

private struct Uniforms {
    var viewSize: SIMD2<Float>
    var sourceSize: SIMD2<Float>
    var layoutScale: Float
    var prescale: Float
    var mode: Int32
    var padding: Int32 = 0
}

/// Shows the newest emulator frame. Shaders are compiled at runtime from source because the offline `metal` compiler
/// ships only with Xcode.
public final class GameView: MTKView, MTKViewDelegate {
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 viewSize;
        float2 sourceSize;
        float layoutScale;
        float prescale;
        int mode;
        int padding;
    };
    struct VOut { float4 position [[position]]; float2 uv; };

    vertex VOut game_vertex(uint vid [[vertex_id]], constant Uniforms& u [[buffer(0)]]) {
        float2 c = float2(float(vid & 1), float(vid >> 1));
        float2 size = u.sourceSize * u.layoutScale;
        float2 origin = floor((u.viewSize - size) * 0.5);
        float2 px = origin + c * size;
        float2 ndc = px / u.viewSize * 2.0 - 1.0;
        VOut o;
        o.position = float4(ndc.x, -ndc.y, 0.0, 1.0);
        o.uv = c;
        return o;
    }

    fragment float4 game_fragment(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]],
                                  constant Uniforms& u [[buffer(0)]]) {
        constexpr sampler nearestSampler(filter::nearest, address::clamp_to_edge);
        constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
        if (u.mode == 0) { return tex.sample(nearestSampler, in.uv); }
        float2 texel = in.uv * u.sourceSize;
        float2 base = floor(texel);
        float2 s = texel - base;
        float2 region = 0.5 - 0.5 / u.prescale;
        float2 d = s - 0.5;
        float2 f = (d - clamp(d, -region, region)) * u.prescale + 0.5;
        return tex.sample(linearSampler, (base + f) / u.sourceSize);
    }
    """

    private let mailbox: FrameMailbox
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var texture: MTLTexture?
    private var lastSerial: UInt64 = 0
    public var scalingMode: ScalingMode = .integer
    /// Receives every key event: (event, isDown). Set by the app to route keyboard input.
    public var keyHandler: ((NSEvent, Bool) -> Void)?

    public init?(mailbox: FrameMailbox) {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.mailbox = mailbox
        super.init(frame: .zero, device: device)
        delegate = self
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        preferredFramesPerSecond = 60
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        queue = device.makeCommandQueue()
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "game_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "game_fragment")
            descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            NSLog("Attic: could not build the video pipeline: \(error)")
            return nil
        }
    }

    public required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Keyboard

    public override var acceptsFirstResponder: Bool { true }
    public override func keyDown(with event: NSEvent) { keyHandler?(event, true) }
    public override func keyUp(with event: NSEvent) { keyHandler?(event, false) }
    public override func flagsChanged(with event: NSEvent) {
        // Modifier keys (such as the right Shift used for Select) arrive here; treat "flag present" as down.
        let down: Bool
        switch event.keyCode {
        case 56, 60: down = event.modifierFlags.contains(.shift)
        default: down = false
        }
        keyHandler?(event, down)
    }

    // MARK: MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        guard let queue, let pipeline,
              let drawable = currentDrawable,
              let pass = currentRenderPassDescriptor,
              let commands = queue.makeCommandBuffer() else { return }

        var sourceSize = SIMD2<Float>(160, 144)
        mailbox.withLatest { pixels, width, height, pitch, serial in
            sourceSize = SIMD2(Float(width), Float(height))
            if texture == nil || texture?.width != width || texture?.height != height {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
                d.usage = [.shaderRead]
                texture = device?.makeTexture(descriptor: d)
                lastSerial = 0
            }
            if serial != lastSerial {
                texture?.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                                 withBytes: pixels, bytesPerRow: pitch)
                lastSerial = serial
            }
        }

        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        if let texture {
            let view = SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height))
            let fit = min(view.x / sourceSize.x, view.y / sourceSize.y)
            let whole = max(floor(fit), 1)
            var uniforms = Uniforms(
                viewSize: view, sourceSize: sourceSize,
                layoutScale: scalingMode == .integer ? whole : max(fit, 1),
                prescale: whole, mode: Int32(scalingMode.rawValue))
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }
}
#endif
