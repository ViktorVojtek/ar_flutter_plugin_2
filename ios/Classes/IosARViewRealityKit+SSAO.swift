import ARKit
import RealityKit
import Metal
import simd
import Foundation

// MARK: - SSAO Post-Process Extension
//
// Registers a Metal compute-based Screen-Space Ambient Occlusion pass
// via ARView.renderCallbacks.postProcess (requires iOS 15+).
//
// Algorithm:
//   1. ssaoCompute kernel reads the reverse-Z depth buffer, reconstructs
//      view-space geometry, and samples a 32-point hemisphere around each
//      pixel to produce an R8Unorm occlusion factor texture.
//   2. ssaoBlurAndComposite kernel depth-blurs the raw AO (5×5, edge-aware)
//      and multiplies it into the source colour, writing to targetColorTexture.
//
// On iOS < 15 this extension compiles but setupSSAO() is a no-op, so the
// rest of the app is unaffected.

extension IosARViewRealityKit {

    // MARK: - Public Entry Points (iOS-version-agnostic signatures)

    /// Call from setupEnhancedLighting(). Activates SSAO on iOS 15+.
    func setupSSAO() {
        if #available(iOS 15.0, *) {
            setupSSAOiOS15()
        } else {
            print("⚠️ SSAO: requires iOS 15+, skipping")
        }
    }

    /// Call from cleanupEnhancedLighting(). Tears down SSAO on iOS 15+.
    func cleanupSSAO() {
        if #available(iOS 15.0, *) {
            cleanupSSAOiOS15()
        }
    }

    // MARK: - iOS 15+ Implementation

    @available(iOS 15.0, *)
    private func setupSSAOiOS15() {
        print("🎨 SSAO: setting up Metal post-process pass...")

        // Generate hemisphere sample kernel (done once)
        ssaoSampleKernel = generateSSAOSampleKernel(count: 32)

        // prepareWithDevice is called once before the first rendered frame.
        // Use it to build the MTLComputePipelineState objects (expensive).
        arView.renderCallbacks.prepareWithDevice = { [weak self] device in
            guard let self = self else { return }
            self.prepareSSAOPipelines(device: device)
        }

        // postProcess is called every frame after RealityKit finishes rendering.
        arView.renderCallbacks.postProcess = { [weak self] context in
            guard let self = self, self.ssaoEnabled else { return }
            self.applySSAOPostProcess(context: context)
        }

        ssaoEnabled = true
        print("✅ SSAO: renderCallbacks registered (prepareWithDevice + postProcess)")
    }

    @available(iOS 15.0, *)
    private func cleanupSSAOiOS15() {
        // Unregister callbacks so they don't fire after disposal
        arView.renderCallbacks.prepareWithDevice = nil
        arView.renderCallbacks.postProcess = nil

        ssaoEnabled = false
        ssaoComputePipeline = nil
        ssaoBlurCompositePipeline = nil
        ssaoTexture = nil
        ssaoSampleKernel = []
        print("🧹 SSAO: pipelines and callbacks cleared")
    }

    // MARK: - Pipeline Setup

    private func prepareSSAOPipelines(device: MTLDevice) {
        print("🎨 SSAO: building MTLComputePipelineState objects...")

        // Locate the Metal library that contains our SSAO kernels.
        // In CocoaPods static framework builds the library lives inside the pod bundle,
        // NOT in the app's main bundle. Try several locations in order.
        guard let library = findMetalLibrary(device: device) else {
            print("❌ SSAO: could not locate Metal library — SSAO disabled")
            return
        }

        guard let computeFn = library.makeFunction(name: "ssaoCompute") else {
            print("❌ SSAO: 'ssaoCompute' function not found in Metal library")
            return
        }
        guard let blurFn = library.makeFunction(name: "ssaoBlurAndComposite") else {
            print("❌ SSAO: 'ssaoBlurAndComposite' function not found in Metal library")
            return
        }

        do {
            ssaoComputePipeline = try device.makeComputePipelineState(function: computeFn)
            ssaoBlurCompositePipeline = try device.makeComputePipelineState(function: blurFn)
            print("✅ SSAO: both compute pipelines created successfully")
        } catch {
            ssaoComputePipeline = nil
            ssaoBlurCompositePipeline = nil
            print("❌ SSAO: pipeline creation failed: \(error.localizedDescription)")
        }
    }

    /// Returns the Metal library containing `ssaoCompute` and `ssaoBlurAndComposite`.
    ///
    /// Strategy:
    ///   1. Pre-compiled default.metallib in the class / plugin bundle (fastest; present when
    ///      the Xcode Metal Toolchain is installed and the pod builds .metal sources).
    ///   2. **Runtime compilation from the embedded Metal source string** — always works,
    ///      requires no Xcode Metal Toolchain on the developer's machine.
    private func findMetalLibrary(device: MTLDevice) -> MTLLibrary? {
        // 1. Class bundle (set by CocoaPods static framework when .metal files compiled)
        //    makeDefaultLibrary(bundle:) throws and returns non-optional; use try?
        if let lib = try? device.makeDefaultLibrary(bundle: Bundle(for: IosARViewRealityKit.self)) {
            return lib
        }

        // 2. System default library (monolithic / non-CocoaPods builds)
        if let lib = device.makeDefaultLibrary() { return lib }

        // 3. Exhaustive bundle search for a pre-compiled .metallib
        for bundle in Bundle.allBundles {
            if let path = bundle.path(forResource: "default", ofType: "metallib"),
               let lib = try? device.makeLibrary(URL: URL(fileURLWithPath: path)) {
                print("💡 SSAO: found pre-compiled metallib in bundle: \(bundle.bundlePath)")
                return lib
            }
        }

        // 4. Runtime compilation from embedded source string.
        //    The Metal source is compiled on-device (no Xcode toolchain needed).
        //    Takes ~50-200 ms on first call; result is cached in the pipeline state objects.
        print("💡 SSAO: no pre-compiled metallib found — compiling from embedded source...")
        let options = MTLCompileOptions()
        options.languageVersion = .version2_1
        do {
            let lib = try device.makeLibrary(source: kSSAOMetalSource, options: options)
            print("✅ SSAO: runtime Metal compilation succeeded")
            return lib
        } catch {
            print("❌ SSAO: runtime Metal compilation failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Per-Frame Post-Process

    @available(iOS 15.0, *)
    private func applySSAOPostProcess(context: ARView.PostProcessContext) {
        guard let computePipeline = ssaoComputePipeline,
              let blurPipeline    = ssaoBlurCompositePipeline else { return }

        let colorTex = context.sourceColorTexture
        let depthTex = context.sourceDepthTexture
        let targetTex = context.targetColorTexture
        let cmdBuf   = context.commandBuffer

        let W = colorTex.width
        let H = colorTex.height

        // --- Lazily create/recreate the intermediate R8Unorm SSAO texture ---
        if ssaoTexture == nil || ssaoTexture!.width != W || ssaoTexture!.height != H {
            let device = cmdBuf.device  // MTLCommandBuffer.device is non-optional
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r8Unorm,
                width: W, height: H,
                mipmapped: false
            )
            desc.usage = [.shaderRead, .shaderWrite]
            desc.storageMode = .private
            ssaoTexture = device.makeTexture(descriptor: desc)
        }
        guard let ssaoTex = ssaoTexture else { return }

        // --- Build SSAOScalarParams ---
        var scalarParams = SSAOScalarParams(
            screenSize: SIMD2<Float>(Float(W), Float(H)),
            radius:      0.05,   // 5 cm — tuned for product-scale AR models
            bias:        0.005,  // prevents surface self-occlusion
            intensity:   1.5,    // power applied to the final AO value
            sampleCount: 32,
            pad:         .zero
        )

        // --- Projection and inverse projection ---
        var projMatrix    = context.projection
        var invProjMatrix = simd_inverse(context.projection)

        // --- Sample kernel: flat array of SIMD4<Float> ---
        var kernel = ssaoSampleKernel  // [SIMD4<Float>], 32 elements

        let threadGroupSize = MTLSize(width: 8, height: 8, depth: 1)
        let threadGridSize  = MTLSize(width: W, height: H, depth: 1)

        // ---------------------------------------------------------------
        // Pass 1 — ssaoCompute: depthTex → ssaoTex
        // ---------------------------------------------------------------
        if let encoder = cmdBuf.makeComputeCommandEncoder() {
            encoder.label = "SSAO_Compute"
            encoder.setComputePipelineState(computePipeline)

            encoder.setTexture(depthTex, index: 0)
            encoder.setTexture(ssaoTex,  index: 1)

            encoder.setBytes(&projMatrix,    length: MemoryLayout<simd_float4x4>.stride, index: 0)
            encoder.setBytes(&invProjMatrix, length: MemoryLayout<simd_float4x4>.stride, index: 1)
            encoder.setBytes(&kernel,        length: MemoryLayout<SIMD4<Float>>.stride * kernel.count,
                             index: 2)
            encoder.setBytes(&scalarParams,  length: MemoryLayout<SSAOScalarParams>.stride, index: 3)

            encoder.dispatchThreads(threadGridSize, threadsPerThreadgroup: threadGroupSize)
            encoder.endEncoding()
        }

        // ---------------------------------------------------------------
        // Pass 2 — ssaoBlurAndComposite: ssaoTex + colorTex → targetTex
        // ---------------------------------------------------------------
        if let encoder = cmdBuf.makeComputeCommandEncoder() {
            encoder.label = "SSAO_Blur_Composite"
            encoder.setComputePipelineState(blurPipeline)

            encoder.setTexture(ssaoTex,   index: 0)
            encoder.setTexture(colorTex,  index: 1)
            encoder.setTexture(targetTex, index: 2)
            encoder.setTexture(depthTex,  index: 3)

            encoder.dispatchThreads(threadGridSize, threadsPerThreadgroup: threadGroupSize)
            encoder.endEncoding()
        }
    }

    // MARK: - Hemisphere Sample Kernel Generation

    /// Generates `count` (≤ 32) hemisphere sample vectors stored as SIMD4<Float>.
    /// Points are distributed so more samples cluster near the origin
    /// (z > 0, in tangent space), giving fine contact-shadow detail.
    func generateSSAOSampleKernel(count: Int) -> [SIMD4<Float>] {
        var samples = [SIMD4<Float>]()
        samples.reserveCapacity(count)

        // Simple LCG for reproducible pseudo-random numbers (no seeding needed,
        // the same kernel is reused every frame).
        var seed: UInt32 = 12345
        func rand01() -> Float {
            seed = seed &* 1664525 &+ 1013904223
            return Float(seed >> 8) / Float(1 << 24)
        }

        for i in 0..<count {
            // Random direction in the upper hemisphere (z > 0 = toward surface normal)
            var sample = SIMD3<Float>(
                rand01() * 2.0 - 1.0,   // x ∈ [-1, 1]
                rand01() * 2.0 - 1.0,   // y ∈ [-1, 1]
                rand01()                 // z ∈ [0, 1] — upper hemisphere only
            )
            sample = normalize(sample)
            sample *= rand01()           // random distance within sphere

            // Accelerating interpolation: more samples near the origin
            let scale = Float(i) / Float(count)
            let accel = 0.1 + 0.9 * scale * scale  // lerp(0.1 → 1.0) with quadratic bias
            sample *= accel

            samples.append(SIMD4<Float>(sample.x, sample.y, sample.z, 0.0))
        }

        return samples
    }
}

// MARK: - SSAOScalarParams (must match Metal struct layout byte-for-byte)

/// Mirror of `SSAOScalarParams` in the embedded Metal source.
/// Total: 8 + 4 + 4 + 4 + 4 + 8 = 32 bytes (naturally aligned).
struct SSAOScalarParams {
    var screenSize:  SIMD2<Float>   // 8 bytes  — float(width), float(height)
    var radius:      Float          // 4 bytes  — sampling radius (metres)
    var bias:        Float          // 4 bytes  — depth bias vs self-occlusion
    var intensity:   Float          // 4 bytes  — power exponent on final AO
    var sampleCount: Int32          // 4 bytes  — number of hemisphere samples
    var pad:         SIMD2<Float>   // 8 bytes  — alignment padding
}

// MARK: - Embedded Metal Source

/// The Metal shader source for SSAO, embedded so it can be compiled at runtime
/// via `device.makeLibrary(source:options:)` without requiring the Xcode Metal Toolchain.
private let kSSAOMetalSource: String = #"""
#include <metal_stdlib>
using namespace metal;

struct SSAOScalarParams {
    float2 screenSize;
    float  radius;
    float  bias;
    float  intensity;
    int    sampleCount;
    float2 pad;
};

static inline float2 hashCoord(uint2 coord) {
    float2 p = float2(coord) * float2(127.1f, 311.7f);
    float2 h = fract(sin(float2(dot(p, float2(127.1f, 311.7f)),
                               dot(p, float2(269.5f, 183.3f)))) * 43758.5453f);
    return h * 2.0f - 1.0f;
}

static inline float3 viewPosFromDepth(float depth, float2 ndc, constant float4x4& invProj) {
    float4 clipPos = float4(ndc.x, ndc.y, depth, 1.0f);
    float4 viewPos = invProj * clipPos;
    return viewPos.xyz / viewPos.w;
}

static inline float2 pixelToNDC(float2 pixelCenter, float2 screenSize) {
    return float2(
        (pixelCenter.x / screenSize.x) * 2.0f - 1.0f,
        1.0f - (pixelCenter.y / screenSize.y) * 2.0f
    );
}

kernel void ssaoCompute(
    texture2d<float, access::read>  depthTex   [[ texture(0) ]],
    texture2d<float, access::write> ssaoOut    [[ texture(1) ]],
    constant float4x4&              proj       [[ buffer(0) ]],
    constant float4x4&              invProj    [[ buffer(1) ]],
    constant float4*                sampleKernel [[ buffer(2) ]],
    constant SSAOScalarParams&      params     [[ buffer(3) ]],
    uint2                           gid        [[ thread_position_in_grid ]])
{
    uint W = depthTex.get_width();
    uint H = depthTex.get_height();
    if (gid.x >= W || gid.y >= H) { ssaoOut.write(float4(1.0f), gid); return; }

    float depth = depthTex.read(gid).r;
    if (depth <= 0.001f) { ssaoOut.write(float4(1.0f), gid); return; }

    float2 sz     = float2(float(W), float(H));
    float2 ndc    = pixelToNDC(float2(gid) + 0.5f, sz);
    float3 origin = viewPosFromDepth(depth, ndc, invProj);

    float2 ndcR  = pixelToNDC(float2(gid.x + 1, gid.y) + 0.5f, sz);
    float2 ndcD  = pixelToNDC(float2(gid.x, gid.y + 1) + 0.5f, sz);
    float depthR = (gid.x + 1 < W) ? depthTex.read(uint2(gid.x + 1, gid.y)).r : depth;
    float depthD = (gid.y + 1 < H) ? depthTex.read(uint2(gid.x, gid.y + 1)).r : depth;
    float3 posR  = viewPosFromDepth(depthR > 0.001f ? depthR : depth, ndcR, invProj);
    float3 posD  = viewPosFromDepth(depthD > 0.001f ? depthD : depth, ndcD, invProj);

    float3 normal = normalize(cross(posD - origin, posR - origin));
    if (normal.z > 0.0f) normal = -normal;

    float2 rvec      = hashCoord(gid);
    float3 randVec   = normalize(float3(rvec.x, rvec.y, 0.0f));
    float3 tangent   = normalize(randVec - normal * dot(randVec, normal));
    float3 bitangent = cross(normal, tangent);
    float3x3 TBN     = float3x3(tangent, bitangent, normal);

    int   n          = min(params.sampleCount, 32);
    float occlusion  = 0.0f;

    for (int i = 0; i < n; ++i) {
        float3 sampleVec = TBN * sampleKernel[i].xyz;
        float3 samplePos = origin + sampleVec * params.radius;

        float4 clip = proj * float4(samplePos, 1.0f);
        clip.xyz /= clip.w;

        if (clip.x < -1.0f || clip.x > 1.0f || clip.y < -1.0f || clip.y > 1.0f) continue;

        float2 sUV = float2((clip.x + 1.0f) * 0.5f, (1.0f - clip.y) * 0.5f);
        uint2  sPx = clamp(uint2(uint(sUV.x * float(W)), uint(sUV.y * float(H))),
                           uint2(0), uint2(W - 1, H - 1));

        float sampledDepth = depthTex.read(sPx).r;
        if (sampledDepth <= 0.001f) continue;

        float2 sNDC          = pixelToNDC(float2(sPx) + 0.5f, sz);
        float3 sampledViewPos = viewPosFromDepth(sampledDepth, sNDC, invProj);

        float rangeCheck = smoothstep(0.0f, 1.0f,
                                      params.radius / max(abs(origin.z - sampledViewPos.z), 0.0001f));
        if (sampledViewPos.z >= samplePos.z + params.bias) {
            occlusion += rangeCheck;
        }
    }

    occlusion    /= float(n);
    float aoValue = pow(clamp(1.0f - occlusion, 0.0f, 1.0f), params.intensity);
    ssaoOut.write(float4(aoValue, aoValue, aoValue, 1.0f), gid);
}

kernel void ssaoBlurAndComposite(
    texture2d<float, access::read>  ssaoTex   [[ texture(0) ]],
    texture2d<float, access::read>  colorTex  [[ texture(1) ]],
    texture2d<float, access::write> targetTex [[ texture(2) ]],
    texture2d<float, access::read>  depthTex  [[ texture(3) ]],
    uint2                           gid       [[ thread_position_in_grid ]])
{
    uint W = colorTex.get_width();
    uint H = colorTex.get_height();
    if (gid.x >= W || gid.y >= H) return;

    float4 color       = colorTex.read(gid);
    float  centerDepth = depthTex.read(gid).r;

    if (centerDepth <= 0.001f) { targetTex.write(color, gid); return; }

    float aoSum     = 0.0f;
    float weightSum = 0.0f;
    const int   R              = 2;
    const float kDepthThresh   = 0.008f;

    for (int dy = -R; dy <= R; ++dy) {
        for (int dx = -R; dx <= R; ++dx) {
            int sx = int(gid.x) + dx;
            int sy = int(gid.y) + dy;
            if (sx < 0 || sy < 0 || sx >= int(W) || sy >= int(H)) continue;
            uint2 nc = uint2(sx, sy);
            float nd = depthTex.read(nc).r;
            if (abs(centerDepth - nd) > kDepthThresh) continue;
            aoSum     += ssaoTex.read(nc).r;
            weightSum += 1.0f;
        }
    }

    float ao = (weightSum > 0.0f) ? (aoSum / weightSum) : ssaoTex.read(gid).r;
    targetTex.write(float4(color.rgb * ao, color.a), gid);
}
"""#
