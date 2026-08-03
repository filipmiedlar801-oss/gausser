import ARKit
import Accelerate
import simd

struct FrameMetrics {
  var sharpness: Float          // raw laplacian variance
  var sharpness01: Float        // texture-aware 0..1
  var speed: Float              // m/s
  var angularSpeed: Float       // deg/s
  var trackingState: String     // "normal" | "limited" | "notAvailable"
  var trackingReason: String    // "" | "initializing" | "excessiveMotion" | "insufficientFeatures" | "relocalizing"
  var lux: Float
  var iso: Float
  var exposureDuration: Float   // seconds
  var motionBlurRisk: Float     // 0..1 heuristic: exposure time x angular speed
  var timestamp: TimeInterval
}

/// Computes per-frame quality metrics on a background queue.
/// Sharpness combines Laplacian variance with Tenengrad (Sobel energy),
/// normalized so blank walls are not punished as harshly as pure Laplace.
final class FrameQualityAnalyzer {
  private var lastTransform: simd_float4x4?
  private var lastTimestamp: TimeInterval = 0

  /// Rough scale so that a usable indoor frame maps to ~0.45-1.0.
  private let sharpnessNormalizer: Float = 180.0
  /// Mean Sobel magnitude typical of moderately textured indoor scenes.
  private let textureNormalizer: Float = 12.0
  /// Tenengrad (mean Gx²+Gy²) scale for sharp textured frames.
  private let tenengradNormalizer: Float = 2_800.0

  func update(frame: ARFrame) -> FrameMetrics {
    let camera = frame.camera
    let t = frame.timestamp

    var speed: Float = 0
    var angularSpeed: Float = 0
    if let last = lastTransform, lastTimestamp > 0, t > lastTimestamp {
      let dt = Float(t - lastTimestamp)
      let dp = camera.transform.columns.3 - last.columns.3
      speed = simd_length(simd_float3(dp.x, dp.y, dp.z)) / dt
      let qa = simd_quatf(last)
      let qb = simd_quatf(camera.transform)
      let dq = qb * qa.inverse
      let angle = abs(dq.angle) * 180 / .pi
      angularSpeed = min(angle, 180) / dt
    }
    lastTransform = camera.transform
    lastTimestamp = t

    var trackingState = "normal"
    var trackingReason = ""
    switch camera.trackingState {
    case .normal:
      trackingState = "normal"
    case .notAvailable:
      trackingState = "notAvailable"
    case .limited(let reason):
      trackingState = "limited"
      switch reason {
      case .initializing: trackingReason = "initializing"
      case .excessiveMotion: trackingReason = "excessiveMotion"
      case .insufficientFeatures: trackingReason = "insufficientFeatures"
      case .relocalizing: trackingReason = "relocalizing"
      @unknown default: trackingReason = "unknown"
      }
    }

    let lux = Float(frame.lightEstimate?.ambientIntensity ?? 0)
    let exposureDuration = Float(camera.exposureDuration)

    let probe = analyzeSharpness(pixelBuffer: frame.capturedImage)
    let sharpness = probe.laplacian
    let sharpness01 = probe.sharpness01

    // Motion blur risk during the shutter: angular + translational smear.
    let degDuringExposure = angularSpeed * exposureDuration
    let metersDuringExposure = speed * exposureDuration
    let angularRisk = degDuringExposure / 0.45          // ~0.45° smear → risk 1
    let linearRisk = metersDuringExposure / 0.0015      // ~1.5 mm smear → risk 1
    let motionBlurRisk = min(1.0, max(angularRisk, linearRisk))

    return FrameMetrics(
      sharpness: sharpness,
      sharpness01: sharpness01,
      speed: speed,
      angularSpeed: angularSpeed,
      trackingState: trackingState,
      trackingReason: trackingReason,
      lux: lux,
      iso: 0,
      exposureDuration: exposureDuration,
      motionBlurRisk: motionBlurRisk,
      timestamp: t
    )
  }

  // MARK: - Sharpness (Laplacian + Tenengrad via vImage)

  private struct SharpnessProbe {
    var laplacian: Float
    var sharpness01: Float
  }

  private var scaledData: [UInt8] = []
  private var convolvedData: [UInt8] = []
  private var floatData: [Float] = []
  private var sobelXData: [Float] = []
  private var sobelYData: [Float] = []
  private var sobelMagData: [Float] = []

  /// Public for KeyframeWriter re-check on the written high-res buffer.
  func laplacianVariance(pixelBuffer: CVPixelBuffer) -> Float {
    analyzeSharpness(pixelBuffer: pixelBuffer).laplacian
  }

  func sharpness01(pixelBuffer: CVPixelBuffer) -> Float {
    analyzeSharpness(pixelBuffer: pixelBuffer).sharpness01
  }

  func measureSharpness(pixelBuffer: CVPixelBuffer) -> (laplacian: Float, sharpness01: Float) {
    let probe = analyzeSharpness(pixelBuffer: pixelBuffer)
    return (probe.laplacian, probe.sharpness01)
  }

  private func analyzeSharpness(pixelBuffer: CVPixelBuffer) -> SharpnessProbe {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

    let planar = CVPixelBufferIsPlanar(pixelBuffer)
    guard let base = planar
      ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
      : CVPixelBufferGetBaseAddress(pixelBuffer) else {
      return SharpnessProbe(laplacian: 0, sharpness01: 0)
    }
    let width = planar ? CVPixelBufferGetWidthOfPlane(pixelBuffer, 0) : CVPixelBufferGetWidth(pixelBuffer)
    let height = planar ? CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) : CVPixelBufferGetHeight(pixelBuffer)
    let rowBytes = planar ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) : CVPixelBufferGetBytesPerRow(pixelBuffer)
    guard width > 16, height > 16 else {
      return SharpnessProbe(laplacian: 0, sharpness01: 0)
    }

    var src = vImage_Buffer(
      data: UnsafeMutableRawPointer(mutating: base),
      height: vImagePixelCount(height),
      width: vImagePixelCount(width),
      rowBytes: rowBytes
    )

    let dw = 384
    let dh = max(16, height * dw / width)
    let count = dw * dh
    if scaledData.count != count {
      scaledData = [UInt8](repeating: 0, count: count)
      convolvedData = [UInt8](repeating: 0, count: count)
      floatData = [Float](repeating: 0, count: count)
      sobelXData = [Float](repeating: 0, count: count)
      sobelYData = [Float](repeating: 0, count: count)
      sobelMagData = [Float](repeating: 0, count: count)
    }

    var laplacian: Float = 0
    var texture: Float = 0
    var tenengrad: Float = 0

    scaledData.withUnsafeMutableBufferPointer { scaledPtr in
      var scaled = vImage_Buffer(
        data: scaledPtr.baseAddress,
        height: vImagePixelCount(dh),
        width: vImagePixelCount(dw),
        rowBytes: dw
      )
      guard vImageScale_Planar8(&src, &scaled, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return }

      // Laplacian variance (high-frequency energy).
      convolvedData.withUnsafeMutableBufferPointer { convPtr in
        var conv = vImage_Buffer(
          data: convPtr.baseAddress,
          height: vImagePixelCount(dh),
          width: vImagePixelCount(dw),
          rowBytes: dw
        )
        var kernel: [Int16] = [0, 1, 0, 1, -4, 1, 0, 1, 0]
        guard vImageConvolve_Planar8(
          &scaled, &conv, nil, 0, 0, &kernel, 3, 3, 1, 128, vImage_Flags(kvImageEdgeExtend)
        ) == kvImageNoError else { return }

        floatData.withUnsafeMutableBufferPointer { floatPtr in
          vDSP_vfltu8(convPtr.baseAddress!, 1, floatPtr.baseAddress!, 1, vDSP_Length(count))
          var mean: Float = 0
          var meanSq: Float = 0
          vDSP_meanv(floatPtr.baseAddress!, 1, &mean, vDSP_Length(count))
          vDSP_measqv(floatPtr.baseAddress!, 1, &meanSq, vDSP_Length(count))
          laplacian = max(0, meanSq - mean * mean)
        }
      }

      // Sobel → texture (mean |G|) + Tenengrad (mean G²).
      floatData.withUnsafeMutableBufferPointer { floatPtr in
        vDSP_vfltu8(scaledPtr.baseAddress!, 1, floatPtr.baseAddress!, 1, vDSP_Length(count))
        var floatBuf = vImage_Buffer(
          data: floatPtr.baseAddress,
          height: vImagePixelCount(dh),
          width: vImagePixelCount(dw),
          rowBytes: dw * MemoryLayout<Float>.size
        )
        sobelXData.withUnsafeMutableBufferPointer { gxPtr in
          sobelYData.withUnsafeMutableBufferPointer { gyPtr in
            var gx = vImage_Buffer(
              data: gxPtr.baseAddress,
              height: vImagePixelCount(dh),
              width: vImagePixelCount(dw),
              rowBytes: dw * MemoryLayout<Float>.size
            )
            var gy = vImage_Buffer(
              data: gyPtr.baseAddress,
              height: vImagePixelCount(dh),
              width: vImagePixelCount(dw),
              rowBytes: dw * MemoryLayout<Float>.size
            )
            // Horizontal / vertical Sobel kernels (float).
            var kx: [Float] = [-1, 0, 1, -2, 0, 2, -1, 0, 1]
            var ky: [Float] = [-1, -2, -1, 0, 0, 0, 1, 2, 1]
            guard vImageConvolve_PlanarF(
              &floatBuf, &gx, nil, 0, 0, &kx, 3, 3, 0, vImage_Flags(kvImageEdgeExtend)
            ) == kvImageNoError else { return }
            guard vImageConvolve_PlanarF(
              &floatBuf, &gy, nil, 0, 0, &ky, 3, 3, 0, vImage_Flags(kvImageEdgeExtend)
            ) == kvImageNoError else { return }

            sobelMagData.withUnsafeMutableBufferPointer { magPtr in
              // |G| ≈ |Gx| + |Gy| (L1, cheaper than hypot)
              vDSP_vabs(gxPtr.baseAddress!, 1, gxPtr.baseAddress!, 1, vDSP_Length(count))
              vDSP_vabs(gyPtr.baseAddress!, 1, gyPtr.baseAddress!, 1, vDSP_Length(count))
              vDSP_vadd(gxPtr.baseAddress!, 1, gyPtr.baseAddress!, 1, magPtr.baseAddress!, 1, vDSP_Length(count))
              vDSP_meanv(magPtr.baseAddress!, 1, &texture, vDSP_Length(count))

              // Tenengrad: mean(Gx² + Gy²) — restore squares from abs'd buffers:
              // We abs'd in place; recompute from float luma via measuring squared mag.
              // Use (absGx + absGy)² as a stable proxy already in magPtr.
              var meanSq: Float = 0
              vDSP_measqv(magPtr.baseAddress!, 1, &meanSq, vDSP_Length(count))
              tenengrad = meanSq
            }
          }
        }
      }
    }

    let lap01 = min(1, laplacian / sharpnessNormalizer)
    let ten01 = min(1, tenengrad / tenengradNormalizer)
    let texture01 = min(1, texture / textureNormalizer)

    // Blank / low-texture: pure Laplace under-scores even when sharp.
    // Boost with Tenengrad and a Laplace/texture ratio so steady blank walls pass.
    let relative = laplacian / max(texture * texture, 1)
    let relative01 = min(1, relative / 10)
    let sharpness01: Float
    if texture01 < 0.22 {
      sharpness01 = min(1, max(lap01, ten01 * 0.85, relative01 * 0.9, lap01 > 0.12 ? 0.42 : lap01))
    } else {
      sharpness01 = min(1, max(0.55 * lap01 + 0.45 * ten01, relative01 * 0.5))
    }

    return SharpnessProbe(laplacian: laplacian, sharpness01: sharpness01)
  }
}
