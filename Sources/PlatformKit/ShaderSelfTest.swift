#if canImport(Metal)
import Metal

/// Proves that Metal shaders can be compiled at runtime from source strings. The `metal` offline compiler ships only
/// with Xcode, so every shader in this app is compiled this way.
public enum ShaderSelfTest {
    public static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct VOut { float4 position [[position]]; float2 uv; };

    vertex VOut fullscreen_vertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        VOut o;
        o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv = p;
        return o;
    }

    fragment float4 test_fragment(VOut in [[stage_in]]) {
        return float4(1.0, 0.0, 0.5, 1.0);
    }
    """

    public enum Outcome: Equatable {
        case passed(String)
        case skipped(String)
        case failed(String)
    }

    public static func run() -> Outcome {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return .skipped("no Metal device (virtualised runner?)")
        }
        do {
            let library = try device.makeLibrary(source: source, options: nil)
            guard let vertex = library.makeFunction(name: "fullscreen_vertex"),
                  let fragment = library.makeFunction(name: "test_fragment") else {
                return .failed("compiled library is missing its functions")
            }
            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.vertexFunction = vertex
            pipelineDescriptor.fragmentFunction = fragment
            pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            let pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)

            let size = 16
            let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
            textureDescriptor.usage = [.renderTarget]
            textureDescriptor.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: textureDescriptor),
                  let queue = device.makeCommandQueue(),
                  let buffer = queue.makeCommandBuffer() else {
                return .failed("could not create texture or command queue")
            }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else {
                return .failed("could not create render encoder")
            }
            encoder.setRenderPipelineState(pipeline)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            buffer.commit()
            buffer.waitUntilCompleted()
            guard buffer.status == .completed else { return .failed("command buffer status \(buffer.status.rawValue)") }

            var pixels = [UInt8](repeating: 0, count: size * size * 4)
            texture.getBytes(&pixels, bytesPerRow: size * 4,
                             from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
            let center = (size / 2 * size + size / 2) * 4
            // BGRA order: expect b ~ 128, g = 0, r = 255, a = 255.
            let ok = pixels[center + 2] == 255 && pixels[center + 1] == 0
                && abs(Int(pixels[center]) - 128) <= 2 && pixels[center + 3] == 255
            return ok ? .passed("compiled, rendered, centre pixel as expected on \(device.name)")
                      : .failed("unexpected centre pixel \(pixels[center...center + 3])")
        } catch {
            return .failed("shader compile or pipeline error: \(error)")
        }
    }
}
#endif
