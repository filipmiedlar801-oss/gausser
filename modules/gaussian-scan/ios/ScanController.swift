import ARKit
import SceneKit
import simd

/// Owns the ARSession lifecycle and wires the analyzer, coverage engine,
/// keyframe writer and guidance engine together.
final class ScanController: NSObject, ARSessionDelegate {
  enum Mode: String {
    case idle, wizard, scanning, review
  }

  private weak var view: ScanView?
  private var arView: ARSCNView? { view?.arView }

  private let analysisQueue = DispatchQueue(label: "gaussianscan.analysis", qos: .userInitiated)
  private let analyzer = FrameQualityAnalyzer()
  private let guidance = GuidanceEngine()
  private var coverage: CoverageEngine?
  private var keyframes: KeyframeWriter?
  private var store: SessionStore?

  private(set) var mode: Mode = .idle
  private var sessionId: String?
  private var scanStartTime: TimeInterval = 0
  private var analyzing = false
  private var lastAnalysis: TimeInterval = 0
  private var lastIntegrate: TimeInterval = 0
  private var lastOverlayRefresh: TimeInterval = 0
  private var lastStatsTime: TimeInterval = 0
  private var cachedStats = CoverageStats()
  private var cachedHoles: [CoverageHole] = []
  private var exposureLocked = false
  private weak var captureDevice: AVCaptureDevice?
  /// Keep forcing ultra-wide for a few seconds — ARKit often resets zoom after `run`.
  private var zoomEnforceUntil: TimeInterval = 0

  private var waypoint: simd_float3?
  private var waypointNode: SCNNode?

  init(view: ScanView) {
    self.view = view
    super.init()
  }

  var hasLiDAR: Bool {
    ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
  }

  // MARK: - Configuration

  private func makeConfiguration(scan: Bool) -> ARWorldTrackingConfiguration {
    let config = ARWorldTrackingConfiguration()
    config.planeDetection = [.horizontal, .vertical]
    config.environmentTexturing = .none
    config.isAutoFocusEnabled = true
    if scan {
      if hasLiDAR {
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
          config.sceneReconstruction = .meshWithClassification
        } else {
          config.sceneReconstruction = .mesh
        }
      }
      if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
        config.frameSemantics.insert(.sceneDepth)
      }
    }
    // Prefer the default ARKit video format so multi-cam ultra-wide zoom stays available.
    // High-res stills still come from `captureHighResolutionFrame` in KeyframeWriter.
    if config.videoFormat.isVideoHDRSupported {
      config.videoHDRAllowed = false
    }
    return config
  }

  // MARK: - Modes

  func startWizard() {
    guard let arView = arView else { return }
    mode = .wizard
    arView.session.delegate = self
    arView.allowsCameraControl = false
    let config = makeConfiguration(scan: false)
    arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    captureDevice = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera
    beginUltraWideZoomEnforcement()
    emitState("wizard")
  }

  func startScan(sessionId: String, resume: Bool) throws {
    guard let arView = arView else {
      throw NSError(domain: "GaussianScan", code: 1, userInfo: [NSLocalizedDescriptionKey: "Widok AR niedostępny"])
    }
    let store = try SessionStore(id: sessionId)
    self.store = store
    self.sessionId = sessionId

    let engine: CoverageEngine = hasLiDAR
      ? MeshCoverageEngine()
      : PlaneCoverageEngine()
    coverage = engine
    arView.scene.rootNode.addChildNode(engine.rootNode)

    keyframes = KeyframeWriter(store: store, session: arView.session, resume: resume)
    keyframes?.onKeyframeSaved = { [weak self] index, path, sharpness, total in
      DispatchQueue.main.async {
        self?.view?.onKeyframe([
          "index": index,
          "uri": "file://\(path)",
          "sharpness": sharpness,
          "total": total,
        ])
      }
    }

    guidance.reset()
    let config = makeConfiguration(scan: true)
    var runOptions: ARSession.RunOptions = [.resetTracking, .removeExistingAnchors]

    if resume {
      if let binData = try? Data(contentsOf: store.coverageBinURL) {
        engine.restore(from: binData)
      }
      if let mapData = try? Data(contentsOf: store.worldMapURL),
         let map = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: mapData) {
        config.initialWorldMap = map
        runOptions = [.removeExistingAnchors]
      }
    } else {
      store.writeMeta([
        "createdAt": Date().timeIntervalSince1970 * 1000,
        "state": "scanning",
        "hasLiDAR": hasLiDAR,
      ])
    }

    mode = .scanning
    scanStartTime = CACurrentMediaTime()
    arView.session.delegate = self
    arView.allowsCameraControl = false
    arView.session.run(config, options: runOptions)
    captureDevice = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera
    beginUltraWideZoomEnforcement()
    emitState("scanning")
  }

  func stopScan(completion: @escaping (Result<[String: Any], Error>) -> Void) {
    guard mode == .scanning, let arView = arView, let store = store, let engine = coverage else {
      completion(.failure(NSError(domain: "GaussianScan", code: 2, userInfo: [NSLocalizedDescriptionKey: "Skan nie jest aktywny"])))
      return
    }
    mode = .idle

    keyframes?.finalize()
    let keyframeCount = keyframes?.keyframeCount ?? 0
    let session = arView.session

    analysisQueue.async { [weak self] in
      guard let self = self else { return }
      let stats = engine.computeStats()
      let holes = engine.holes(maxCount: 12)
      engine.refreshOverlay()

      let coverageJSON: [String: Any] = [
        "stats": stats.toDictionary(),
        "holes": holes.map { $0.toDictionary() },
      ]
      store.writeJSON(coverageJSON, to: store.coverageURL)
      try? engine.serialize().write(to: store.coverageBinURL)

      DispatchQueue.main.async {
        // Snapshot the colored coverage model for the review screen.
        let scene = SCNScene()
        scene.rootNode.addChildNode(engine.rootNode.clone())
        scene.write(to: store.sceneURL, options: nil, delegate: nil, progressHandler: nil)

        session.getCurrentWorldMap { map, _ in
          if let map = map,
             let data = try? NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true) {
            try? data.write(to: store.worldMapURL)
          }
          DispatchQueue.main.async {
            session.pause()
            let summary: [String: Any] = [
              "sessionId": store.id,
              "frameCount": keyframeCount,
              "coverage": stats.toDictionary(),
              "holes": holes.map { $0.toDictionary() },
            ]
            store.writeMeta([
              "state": "done",
              "frameCount": keyframeCount,
              "coverage": stats.toDictionary(),
              "finishedAt": Date().timeIntervalSince1970 * 1000,
            ])
            self.emitState("stopped")
            completion(.success(summary))
          }
        }
      }
    }
  }

  func startReview(sessionId: String) {
    guard let arView = arView else { return }
    mode = .review
    self.sessionId = sessionId
    arView.session.pause()

    let dir = SessionStore.scansRoot().appendingPathComponent(sessionId, isDirectory: true)
    let sceneURL = dir.appendingPathComponent("scene.scn")
    if let scene = try? SCNScene(url: sceneURL, options: nil) {
      scene.background.contents = UIColor(white: 0.07, alpha: 1)
      arView.scene = scene
      arView.allowsCameraControl = true
      arView.autoenablesDefaultLighting = true
    }

    // Emit persisted coverage so the review HUD can render stats.
    let coverageURL = dir.appendingPathComponent("coverage.json")
    if let data = try? Data(contentsOf: coverageURL),
       let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
      var payload = json
      payload["final"] = true
      view?.onCoverage(payload)
    }
    emitState("review")
  }

  func teardown() {
    arView?.session.pause()
    mode = .idle
  }

  // MARK: - Zoom

  /// On dual/triple virtual devices, Camera-app "0.5×" is `minAvailableVideoZoomFactor`
  /// (often 1.0), while Camera-app "1×" is the first `virtualDeviceSwitchOver` (often 2.0).
  private func beginUltraWideZoomEnforcement() {
    zoomEnforceUntil = CACurrentMediaTime() + 4.0
    applyUltraWideZoom()
    // ARKit frequently overwrites zoom right after `run` — retry while settling.
    for delay in [0.05, 0.15, 0.35, 0.7, 1.2, 2.0, 3.0] as [TimeInterval] {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        guard let self = self, self.mode == .wizard || self.mode == .scanning else { return }
        self.captureDevice = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera
        self.applyUltraWideZoom()
      }
    }
  }

  private func applyUltraWideZoom() {
    guard let device = captureDevice ?? ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else {
      return
    }
    let target = device.minAvailableVideoZoomFactor
    guard abs(device.videoZoomFactor - target) > 0.02 else { return }
    do {
      try device.lockForConfiguration()
      device.videoZoomFactor = target
      device.unlockForConfiguration()
    } catch {
      // Device may not allow zoom changes while ARKit holds the session — ignore.
    }
  }

  // MARK: - Exposure

  func lockExposure() throws {
    guard let device = captureDevice ?? ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else {
      throw NSError(domain: "GaussianScan", code: 3, userInfo: [NSLocalizedDescriptionKey: "Kamera nie wspiera blokady ekspozycji"])
    }
    try device.lockForConfiguration()
    if device.isExposureModeSupported(.locked) {
      device.exposureMode = .locked
    }
    if device.isWhiteBalanceModeSupported(.locked) {
      device.whiteBalanceMode = .locked
    }
    device.unlockForConfiguration()
    exposureLocked = true
  }

  func unlockExposure() throws {
    guard let device = captureDevice ?? ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else { return }
    try device.lockForConfiguration()
    if device.isExposureModeSupported(.continuousAutoExposure) {
      device.exposureMode = .continuousAutoExposure
    }
    if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
      device.whiteBalanceMode = .continuousAutoWhiteBalance
    }
    device.unlockForConfiguration()
    exposureLocked = false
  }

  // MARK: - Waypoint

  func setWaypoint(x: Float, y: Float, z: Float) {
    let position = simd_float3(x, y, z)
    analysisQueue.async { [weak self] in self?.waypoint = position }
    DispatchQueue.main.async { [weak self] in
      guard let self = self, let arView = self.arView else { return }
      self.waypointNode?.removeFromParentNode()
      let sphere = SCNSphere(radius: 0.10)
      let material = SCNMaterial()
      material.diffuse.contents = UIColor.systemGreen
      material.emission.contents = UIColor.systemGreen
      material.lightingModel = .constant
      sphere.materials = [material]
      let node = SCNNode(geometry: sphere)
      node.simdPosition = position
      node.opacity = 0.85
      let pulse = SCNAction.repeatForever(.sequence([
        .scale(to: 1.5, duration: 0.6),
        .scale(to: 1.0, duration: 0.6),
      ]))
      node.runAction(pulse)
      arView.scene.rootNode.addChildNode(node)
      self.waypointNode = node
    }
  }

  func clearWaypoint() {
    analysisQueue.async { [weak self] in self?.waypoint = nil }
    DispatchQueue.main.async { [weak self] in
      self?.waypointNode?.removeFromParentNode()
      self?.waypointNode = nil
    }
  }

  // MARK: - ARSessionDelegate

  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    guard mode == .wizard || mode == .scanning else { return }
    let now = frame.timestamp
    guard !analyzing, now - lastAnalysis >= 0.1 else { return }
    analyzing = true
    lastAnalysis = now

    analysisQueue.async { [weak self] in
      guard let self = self else { return }
      defer { self.analyzing = false }
      self.analyze(frame: frame)
    }
  }

  func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
    guard mode == .scanning, let engine = coverage else { return }
    analysisQueue.async { engine.anchorsAdded(anchors) }
  }

  func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
    guard mode == .scanning, let engine = coverage else { return }
    analysisQueue.async { engine.anchorsUpdated(anchors) }
  }

  func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
    guard mode == .scanning, let engine = coverage else { return }
    analysisQueue.async { engine.anchorsRemoved(anchors) }
  }

  // MARK: - Analysis (runs on analysisQueue)

  private func analyze(frame: ARFrame) {
    let metrics = analyzer.update(frame: frame)
    let now = CACurrentMediaTime()

    // Re-assert ultra-wide while ARKit is still settling the capture pipeline.
    if now < zoomEnforceUntil {
      DispatchQueue.main.async { [weak self] in self?.applyUltraWideZoom() }
    }

    if mode == .scanning, let engine = coverage {
      // Coverage should accumulate whenever tracking is healthy — sharpness is only for keyframes.
      let trackingOk = metrics.trackingState == "normal"
      if trackingOk, now - lastIntegrate >= 0.12 {
        lastIntegrate = now
        engine.integrate(frame: frame)
      }
      if now - lastOverlayRefresh >= 0.45 {
        lastOverlayRefresh = now
        engine.refreshOverlay()
      }
      if now - lastStatsTime >= 1.0 {
        lastStatsTime = now
        cachedStats = engine.computeStats()
        cachedHoles = engine.holes(maxCount: 8)
        emitCoverage()
      }
      // Match GuidanceEngine `more_angles`: once walls are mostly seen from a single
      // direction, densify walk baseline so green (≥2 octants) can fill via center-ring
      // / grid repositioning — not pure spin. Coverage still cannot fire captures alone.
      let scanDuration = now - scanStartTime
      let needsMoreAngles = scanDuration > 35
        && cachedStats.totalSamples > 0
        && cachedStats.yellow > 0.28
        && cachedStats.red < 0.22
        && cachedStats.green < 0.55
      keyframes?.consider(frame: frame, metrics: metrics, needsMoreAngles: needsMoreAngles)
    }

    // Waypoint bearing relative to the camera
    var waypointPayload: [String: Any]? = nil
    var waypointDistance: Float? = nil
    if let wp = waypoint {
      let t = frame.camera.transform
      let camPos = simd_float3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
      let forward = -simd_float3(t.columns.2.x, t.columns.2.y, t.columns.2.z)
      let delta = wp - camPos
      let distance = simd_length(delta)
      waypointDistance = distance

      let flatDelta = simd_float3(delta.x, 0, delta.z)
      let flatForward = simd_float3(forward.x, 0, forward.z)
      var bearing: Float = 0
      if simd_length(flatDelta) > 0.001, simd_length(flatForward) > 0.001 {
        let a = simd_normalize(flatForward)
        let b = simd_normalize(flatDelta)
        let cross = a.x * b.z - a.z * b.x
        bearing = atan2(cross, simd_dot(a, b)) * 180 / .pi
      }
      let elevation = atan2(delta.y, simd_length(flatDelta)) * 180 / .pi
      waypointPayload = ["bearing": bearing, "elevation": elevation, "distance": distance]
    }

    var iso: Float = 0
    if let device = captureDevice {
      iso = device.iso
    }

    var payload: [String: Any] = [
      "sharpness": metrics.sharpness,
      "sharpness01": metrics.sharpness01,
      "speed": metrics.speed,
      "angularSpeed": metrics.angularSpeed,
      "trackingState": metrics.trackingState,
      "trackingReason": metrics.trackingReason,
      "lux": metrics.lux,
      "iso": iso,
      "exposureDuration": metrics.exposureDuration,
      "exposureLocked": exposureLocked,
      "motionBlurRisk": metrics.motionBlurRisk,
      "medianDepth": cachedStats.medianDepth,
      "keyframes": keyframes?.keyframeCount ?? 0,
    ]
    if let wp = waypointPayload {
      payload["waypoint"] = wp
    }
    let metricsPayload = payload
    DispatchQueue.main.async { [weak self] in
      self?.view?.onMetrics(metricsPayload)
    }

    if mode == .scanning {
      let t = frame.camera.transform
      let forward = -simd_float3(t.columns.2.x, t.columns.2.y, t.columns.2.z)
      let lookUp = forward.y
      let input = GuidanceInput(
        trackingState: metrics.trackingState,
        trackingReason: metrics.trackingReason,
        speed: metrics.speed,
        angularSpeed: metrics.angularSpeed,
        lux: metrics.lux,
        medianDepth: cachedStats.medianDepth,
        sharpness01: metrics.sharpness01,
        motionBlurRisk: metrics.motionBlurRisk,
        lookUp: lookUp,
        stats: cachedStats.totalSamples > 0 ? cachedStats : nil,
        scanDuration: now - scanStartTime,
        waypointDistance: waypointDistance,
        holeCount: cachedHoles.count
      )
      let hints = guidance.tick(input, now: now)
      if !hints.isEmpty {
        DispatchQueue.main.async { [weak self] in
          for hint in hints {
            var p = hint.params
            p["code"] = hint.code
            self?.view?.onGuidance(p)
          }
        }
      }
      // Auto-clear the waypoint once reached.
      if let wd = waypointDistance, wd < 1.0 {
        waypoint = nil
        DispatchQueue.main.async { [weak self] in
          self?.waypointNode?.removeFromParentNode()
          self?.waypointNode = nil
        }
      }
    }
  }

  private func emitCoverage() {
    let payload: [String: Any] = [
      "stats": cachedStats.toDictionary(),
      "holes": cachedHoles.map { $0.toDictionary() },
    ]
    DispatchQueue.main.async { [weak self] in
      self?.view?.onCoverage(payload)
    }
  }

  private func emitState(_ state: String) {
    let payload: [String: Any] = [
      "state": state,
      "sessionId": sessionId ?? "",
      "hasLiDAR": hasLiDAR,
    ]
    DispatchQueue.main.async { [weak self] in
      self?.view?.onSessionState(payload)
    }
  }
}
