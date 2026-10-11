import CineEyeVideo
import CoreVideo
import Metal
import QuartzCore
import simd

/// Draws decoded frames with Metal and applies the monitoring tools (LUT, false colour, zebra).
/// `display` is called from the decode queue, the setters from the main thread.
final class VideoRenderer {
    struct Options: Equatable {
        var falseColor = false
        var zebra = false
        /// Luma level, 0–1, at and above which zebra stripes are drawn.
        var zebraLevel: Float = 0.95
        var lutEnabled = false
    }

    let layer = CAMetalLayer()

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let identityLUT: MTLTexture
    private var textureCache: CVMetalTextureCache?

    private let lock = NSLock()
    private var options = Options()
    private var lut: MTLTexture?
    private var lutSize: Float = 2
    private var lutDomainMin = SIMD3<Float>(0, 0, 0)
    private var lutDomainMax = SIMD3<Float>(1, 1, 1)
    private var lastFrame: CVPixelBuffer?
    private let start = CACurrentMediaTime()

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shaderSource, options: nil)
        else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "vertexMain")
        descriptor.fragmentFunction = library.makeFunction(name: "fragmentMain")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        samplerDescriptor.rAddressMode = .clampToEdge
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor),
              let sampler = device.makeSamplerState(descriptor: samplerDescriptor),
              let identity = Self.makeLUTTexture(device: device, size: 2, rgba: Self.identityTable)
        else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.sampler = sampler
        self.identityLUT = identity
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)

        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.backgroundColor = .black
        // The stream is Rec. 709; let the system map it to the display.
        layer.colorspace = CGColorSpace(name: CGColorSpace.itur_709)
        layer.maximumDrawableCount = 2
    }

    // MARK: - Input

    func display(_ frame: CVPixelBuffer) {
        lock.withLock { lastFrame = frame }
        draw()
    }

    func setOptions(_ new: Options) {
        let changed = lock.withLock { () -> Bool in
            defer { options = new }
            return options != new
        }
        if changed { draw() }
    }

    func setLUT(_ cube: CubeLUT?) {
        let texture = cube.flatMap { Self.makeLUTTexture(device: device, size: $0.size, rgba: $0.rgba) }
        lock.withLock {
            lut = texture
            lutSize = Float(cube?.size ?? 2)
            lutDomainMin = cube?.domainMin ?? SIMD3(0, 0, 0)
            lutDomainMax = cube?.domainMax ?? SIMD3(1, 1, 1)
        }
        draw()
    }

    func setDrawableSize(_ size: CGSize) {
        guard size.width >= 1, size.height >= 1, layer.drawableSize != size else { return }
        layer.drawableSize = size
        draw()
    }

    /// Forget the last picture, e.g. so a stale frame is not redrawn after a long gap.
    func clear() {
        lock.withLock { lastFrame = nil }
    }

    // MARK: - Drawing

    private struct Uniforms {
        var scale: SIMD2<Float>
        var zebraLevel: Float
        var time: Float
        var mode: UInt32
        var lutSize: Float
        var padding: SIMD2<Float> = .zero
        var lutMin: SIMD4<Float>
        var lutInvRange: SIMD4<Float>
    }

    private let drawLock = NSLock()

    private func draw() {
        drawLock.lock()
        defer { drawLock.unlock() }
        guard let frame = lock.withLock({ lastFrame }),
              let drawable = layer.nextDrawable(),
              let commands = queue.makeCommandBuffer(),
              encode(frame, into: drawable.texture, commands: commands, options: lock.withLock { options })
        else { return }
        commands.present(drawable)
        commands.commit()
    }

    /// Renders the current frame off screen with the given tools, at the video's own size.
    /// Used to check the shader without looking at the window.
    func snapshot(options: Options) -> CGImage? {
        drawLock.lock()
        defer { drawLock.unlock() }
        guard let frame = lock.withLock({ lastFrame }) else { return nil }
        let width = CVPixelBufferGetWidth(frame), height = CVPixelBufferGetHeight(frame)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor),
              let commands = queue.makeCommandBuffer(),
              encode(frame, into: target, commands: commands, options: options)
        else { return nil }
        commands.commit()
        commands.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        return bytes.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpace(name: CGColorSpace.itur_709)!, bitmapInfo: info)?.makeImage()
        }
    }

    private func encode(_ frame: CVPixelBuffer, into target: MTLTexture, commands: MTLCommandBuffer, options: Options) -> Bool {
        let (lut, lutSize, lutMin, lutMax) = lock.withLock { (self.lut, self.lutSize, lutDomainMin, lutDomainMax) }
        guard let textureCache,
              let luma = texture(frame, plane: 0, format: .r8Unorm, cache: textureCache),
              let chroma = texture(frame, plane: 1, format: .rg8Unorm, cache: textureCache),
              let lumaTexture = CVMetalTextureGetTexture(luma),
              let chromaTexture = CVMetalTextureGetTexture(chroma)
        else { return false }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return false }

        // Aspect-fit the picture inside the target.
        let videoAspect = Float(CVPixelBufferGetWidth(frame)) / Float(max(CVPixelBufferGetHeight(frame), 1))
        let viewAspect = Float(target.width) / Float(max(target.height, 1))
        let scale = videoAspect > viewAspect
            ? SIMD2<Float>(1, viewAspect / videoAspect)
            : SIMD2<Float>(videoAspect / viewAspect, 1)

        let useLUT = options.lutEnabled && lut != nil
        var mode: UInt32 = 0
        if useLUT { mode |= 1 }
        if options.falseColor { mode |= 2 }
        if options.zebra { mode |= 4 }
        let range = lutMax - lutMin
        var uniforms = Uniforms(
            scale: scale, zebraLevel: options.zebraLevel, time: Float(CACurrentMediaTime() - start),
            mode: mode, lutSize: lutSize,
            lutMin: SIMD4(lutMin, 0),
            lutInvRange: SIMD4(1 / max(range.x, 1e-6), 1 / max(range.y, 1e-6), 1 / max(range.z, 1e-6), 0))

        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(lumaTexture, index: 0)
        encoder.setFragmentTexture(chromaTexture, index: 1)
        encoder.setFragmentTexture(useLUT ? lut : identityLUT, index: 2)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        // Keep the pixel buffer's textures alive until the GPU is done with them.
        commands.addCompletedHandler { _ in _ = (luma, chroma) }
        return true
    }

    private func texture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat, cache: CVMetalTextureCache) -> CVMetalTexture? {
        var out: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, buffer, nil, format,
            CVPixelBufferGetWidthOfPlane(buffer, plane), CVPixelBufferGetHeightOfPlane(buffer, plane), plane, &out)
        return out
    }

    private static let identityTable: [Float] = (0..<8).flatMap { i -> [Float] in
        [Float(i & 1), Float((i >> 1) & 1), Float((i >> 2) & 1), 1]
    }

    private static func makeLUTTexture(device: MTLDevice, size: Int, rgba: [Float]) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba32Float
        descriptor.width = size
        descriptor.height = size
        descriptor.depth = size
        descriptor.usage = .shaderRead
        guard rgba.count == size * size * size * 4, let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        rgba.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake3D(0, 0, 0, size, size, size), mipmapLevel: 0, slice: 0,
                withBytes: bytes.baseAddress!, bytesPerRow: size * 16, bytesPerImage: size * size * 16)
        }
        return texture
    }

    /// The false-colour bands, shared with the on-screen legend. Levels are percent of full-range luma.
    static let falseColorBands: [(upTo: Float, name: String, rgb: SIMD3<Float>?)] = [
        (2, "Clipped black", SIMD3(0.55, 0.0, 0.75)),
        (10, "Near black", SIMD3(0.0, 0.2, 0.9)),
        (20, "Shadows", SIMD3(0.0, 0.6, 0.85)),
        (40, "", nil),
        (48, "Mid grey", SIMD3(0.1, 0.75, 0.2)),
        (55, "", nil),
        (65, "Skin", SIMD3(1.0, 0.55, 0.65)),
        (90, "", nil),
        (97, "Highlights", SIMD3(1.0, 0.95, 0.1)),
        (99.5, "Near clip", SIMD3(1.0, 0.5, 0.0)),
        (1000, "Clipped", SIMD3(1.0, 0.0, 0.0)),
    ]

    private static var shaderSource: String {
        // Generate the band ladder from the table above so the legend and the shader cannot disagree.
        let ladder = falseColorBands.map { band -> String in
            let color = band.rgb.map { "float3(\($0.x), \($0.y), \($0.z))" } ?? "float3(luma)"
            return "    if (ire < \(band.upTo)) return \(color);"
        }.joined(separator: "\n")
        return """
        #include <metal_stdlib>
        using namespace metal;

        struct Uniforms {
            float2 scale;
            float zebraLevel;
            float time;
            uint mode;
            float lutSize;
            float2 padding;
            float4 lutMin;
            float4 lutInvRange;
        };

        struct VertexOut {
            float4 position [[position]];
            float2 uv;
        };

        vertex VertexOut vertexMain(uint id [[vertex_id]], constant Uniforms &u [[buffer(0)]]) {
            float2 corner = float2(id & 1, id >> 1);
            VertexOut out;
            out.position = float4((corner * 2.0 - 1.0) * u.scale, 0.0, 1.0);
            out.uv = float2(corner.x, 1.0 - corner.y);
            return out;
        }

        static float3 falseColor(float luma) {
            float ire = luma * 100.0;
        \(ladder)
            return float3(luma);
        }

        fragment float4 fragmentMain(VertexOut in [[stage_in]],
                                     texture2d<float> lumaTexture [[texture(0)]],
                                     texture2d<float> chromaTexture [[texture(1)]],
                                     texture3d<float> lut [[texture(2)]],
                                     sampler s [[sampler(0)]],
                                     constant Uniforms &u [[buffer(0)]]) {
            // Full-range BT.709 Y'CbCr to R'G'B'.
            float y = lumaTexture.sample(s, in.uv).r;
            float2 c = chromaTexture.sample(s, in.uv).rg - 0.5;
            float3 rgb = float3(y + 1.5748 * c.y, y - 0.1873 * c.x - 0.4681 * c.y, y + 1.8556 * c.x);
            rgb = saturate(rgb);

            float3 shown = rgb;
            if (u.mode & 1) {
                float3 p = saturate((rgb - u.lutMin.rgb) * u.lutInvRange.rgb);
                shown = lut.sample(s, p * ((u.lutSize - 1.0) / u.lutSize) + 0.5 / u.lutSize).rgb;
            }
            // Exposure tools read the incoming signal, not the LUT's output.
            if (u.mode & 2) {
                shown = falseColor(y);
            }
            if ((u.mode & 4) && y >= u.zebraLevel) {
                float stripe = fract((in.position.x + in.position.y) / 14.0 + u.time * 1.5);
                shown = stripe < 0.5 ? float3(0.0) : float3(1.0);
            }
            return float4(shown, 1.0);
        }
        """
    }
}
