import ARKit
import CoreImage
import simd

/// Selects and persists training keyframes: only sharp frames with enough baseline
/// versus *all* existing keyframes (not just the last one), at the highest resolution
/// the device supports.
final class KeyframeWriter {
  private let store: SessionStore
  private weak var session: ARSession?
  private let ciContext = CIContext(options: [.cacheIntermediates: false])
  private let writeQueue = DispatchQueue(label: "gaussianscan.keyframes", qos: .utility)

  // Selection thresholds — must differ from every existing pose, not only the last.
  // Pose spacing: 0.14 m is ~2× denser than the old 0.28 m gate and still above
  // Apple Spatial Capture’s ~0.08 m default — enough overlap for room-scale 3DGS
  // without flooding near-duplicates. When the camera is near a coverage hole
  // *and looking toward it*, tighten to 0.10 m so gap-filling walks get extra
  // multi-view density without densifying mere pass-bys. Blur/speed gates stay
  // strict; coverage alone never fires a capture.
  private let minTranslation: Float = 0.14      // m
  private let minTranslationTowardHole: Float = 0.10 // m — looking-toward-hole only
  private let minRotationDeg: Float = 18
  private let minSharpness01: Float = 0.38
  private let minSharpnessRaw: Float = 45
  private let maxMotionBlurRisk: Float = 0.38
  private let maxSpeed: Float = 0.45            // m/s
  private let maxAngularSpeed: Float = 28       // deg/s
  private let minCaptureInterval: TimeInterval = 0.9

  private let sharpnessProbe = FrameQualityAnalyzer()
  private var keyframeTransforms: [simd_float4x4] = []
  private var lastCaptureTime: TimeInterval = 0
  private var captureInFlight = false
  private var entries: [[String: Any]] = []
  private(set) var frameIndex = 0

  var onKeyframeSaved: ((_ index: Int, _ path: String, _ sharpness: Float, _ total: Int) -> Void)?

  init(store: SessionStore, session: ARSession, resume: Bool) {
    self.store = store
    self.session = session
    if resume, let manifest = store.readJSON(from: store.manifestURL) as? [String: Any],
       let existing = manifest["frames"] as? [[String: Any]] {
      entries = existing
      frameIndex = existing.count
      keyframeTransforms = existing.compactMap { entry in
        guard let arr = entry["transform"] as? [Double], arr.count == 16 else {
          if let arr = entry["transform"] as? [NSNumber], arr.count == 16 {
            return float4x4(fromColumnMajor: arr.map { $0.floatValue })
          }
          if let arr = entry["transform"] as? [Float], arr.count == 16 {
            return float4x4(fromColumnMajor: arr)
          }
          return nil
        }
        return float4x4(fromColumnMajor: arr.map { Float($0) })
      }
    }
  }

  var keyframeCount: Int { entries.count }

  /// True when `candidate` is too close (pose) to any already-saved keyframe.
  private func isTooSimilar(to candidate: simd_float4x4, minTranslationMeters: Float) -> Bool {
    let camPos = simd_float3(candidate.columns.3.x, candidate.columns.3.y, candidate.columns.3.z)
    let camQuat = simd_quatf(candidate)
    for existing in keyframeTransforms {
      let ep = simd_float3(existing.columns.3.x, existing.columns.3.y, existing.columns.3.z)
      let translation = simd_length(camPos - ep)
      if translation < minTranslationMeters {
        let dq = camQuat * simd_quatf(existing).inverse
        let rotationDeg = abs(dq.angle) * 180 / .pi
        if rotationDeg < minRotationDeg {
          return true
        }
      }
    }
    return false
  }

  /// Called on the analysis queue for every analyzed frame.
  /// - Parameter lookingTowardCoverageHole: when true (near a gap and facing it),
  ///   use a tighter translation baseline so sparse regions accumulate more sharp
  ///   views. Does not bypass blur/speed/sharpness/interval gates.
  func consider(frame: ARFrame, metrics: FrameMetrics, lookingTowardCoverageHole: Bool = false) {
    guard metrics.trackingState == "normal" else { return }
    guard metrics.motionBlurRisk <= maxMotionBlurRisk else { return }
    guard metrics.speed <= maxSpeed, metrics.angularSpeed <= maxAngularSpeed else { return }
    guard isSharpEnough(sharpness01: metrics.sharpness01, sharpnessRaw: metrics.sharpness, motionBlurRisk: metrics.motionBlurRisk) else { return }
    guard !captureInFlight else { return }

    let now = CACurrentMediaTime()
    guard now - lastCaptureTime >= minCaptureInterval else { return }

    let transform = frame.camera.transform
    let translationGate = lookingTowardCoverageHole ? minTranslationTowardHole : minTranslation
    if !keyframeTransforms.isEmpty, isTooSimilar(to: transform, minTranslationMeters: translationGate) {
      return
    }

    captureInFlight = true
    lastCaptureTime = now
    keyframeTransforms.append(transform)

    let index = frameIndex
    frameIndex += 1

    DispatchQueue.main.async { [weak self] in
      guard let self = self, let session = self.session else { return }
      session.captureHighResolutionFrame { [weak self] highResFrame, _ in
        guard let self = self else { return }
        if let hf = highResFrame {
          self.saveIfSharp(pixelBuffer: hf.capturedImage, camera: hf.camera, timestamp: hf.timestamp, index: index, highRes: true)
        } else if let current = session.currentFrame {
          self.saveIfSharp(pixelBuffer: current.capturedImage, camera: current.camera, timestamp: current.timestamp, index: index, highRes: false)
        } else {
          self.abortCapture()
        }
      }
    }
  }

  private func isSharpEnough(sharpness01: Float, sharpnessRaw: Float, motionBlurRisk: Float) -> Bool {
    // Texture-aware sharpness01 already softens blank walls; raw Laplace is a secondary floor.
    if sharpness01 >= minSharpness01 && sharpnessRaw >= minSharpnessRaw { return true }
    if motionBlurRisk <= 0.22 && sharpness01 >= 0.32 && sharpnessRaw >= 28 { return true }
    return false
  }

  private func abortCapture() {
    captureInFlight = false
    if !keyframeTransforms.isEmpty {
      keyframeTransforms.removeLast()
    }
    frameIndex = max(0, frameIndex - 1)
  }

  /// Final gate: re-measure sharpness on the exact buffer we would write.
  private func saveIfSharp(pixelBuffer: CVPixelBuffer, camera: ARCamera, timestamp: TimeInterval, index: Int, highRes: Bool) {
    writeQueue.async { [weak self] in
      guard let self = self else { return }

      let measured = self.sharpnessProbe.measureSharpness(pixelBuffer: pixelBuffer)
      let raw = measured.laplacian
      let sharpness01 = measured.sharpness01
      // High-res buffers score differently; use a slightly softer absolute floor.
      // Motion already passed on the preview frame.
      let ok = (sharpness01 >= self.minSharpness01 * 0.85 && raw >= self.minSharpnessRaw * 0.85)
        || (sharpness01 >= 0.30 && raw >= 28)
      guard ok else {
        self.abortCapture()
        return
      }

      defer { self.captureInFlight = false }

      // Rotate to portrait so exported photos match what the user saw.
      let image = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
      let url = self.store.imageURL(index: index)
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
      do {
        try self.ciContext.writeJPEGRepresentation(
          of: image, to: url, colorSpace: colorSpace,
          options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.92]
        )
      } catch {
        // Sharpness passed but encode failed — drop reserved pose.
        if !self.keyframeTransforms.isEmpty {
          self.keyframeTransforms.removeLast()
        }
        self.frameIndex = max(0, self.frameIndex - 1)
        return
      }

      let t = camera.transform
      let transformArray: [Float] = [
        t.columns.0.x, t.columns.0.y, t.columns.0.z, t.columns.0.w,
        t.columns.1.x, t.columns.1.y, t.columns.1.z, t.columns.1.w,
        t.columns.2.x, t.columns.2.y, t.columns.2.z, t.columns.2.w,
        t.columns.3.x, t.columns.3.y, t.columns.3.z, t.columns.3.w,
      ]
      let k = camera.intrinsics
      let intrinsicsArray: [Float] = [
        k.columns.0.x, k.columns.0.y, k.columns.0.z,
        k.columns.1.x, k.columns.1.y, k.columns.1.z,
        k.columns.2.x, k.columns.2.y, k.columns.2.z,
      ]

      let entry: [String: Any] = [
        "file": "images/\(url.lastPathComponent)",
        "index": index,
        "timestamp": timestamp,
        "transform": transformArray,
        "intrinsics": intrinsicsArray,
        "width": Int(camera.imageResolution.width),
        "height": Int(camera.imageResolution.height),
        "sharpness": sharpness01,
        "sharpnessRaw": raw,
        "highRes": highRes,
      ]
      self.entries.append(entry)
      if self.entries.count % 10 == 0 {
        self.flushManifest()
      }
      self.onKeyframeSaved?(index, url.path, sharpness01, self.entries.count)
    }
  }

  private func flushManifest() {
    store.writeJSON(["frames": entries], to: store.manifestURL)
  }

  func finalize() {
    writeQueue.sync {
      self.flushManifest()
    }
  }
}

private extension simd_float4x4 {
  init(fromColumnMajor values: [Float]) {
    self.init(
      SIMD4<Float>(values[0], values[1], values[2], values[3]),
      SIMD4<Float>(values[4], values[5], values[6], values[7]),
      SIMD4<Float>(values[8], values[9], values[10], values[11]),
      SIMD4<Float>(values[12], values[13], values[14], values[15])
    )
  }
}
