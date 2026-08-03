import ARKit
import SceneKit
import simd

struct CoverageStats {
  var green: Float = 0
  var yellow: Float = 0
  var red: Float = 1
  var wallsGreen: Float = 0
  var ceilingGreen: Float = 0
  var floorGreen: Float = 0
  var ceilingSamples: Int = 0
  var floorSamples: Int = 0
  var medianDepth: Float = 0
  var totalSamples: Int = 0

  func toDictionary() -> [String: Any] {
    return [
      "green": green, "yellow": yellow, "red": red,
      "wallsGreen": wallsGreen, "ceilingGreen": ceilingGreen, "floorGreen": floorGreen,
      "ceilingSamples": ceilingSamples, "floorSamples": floorSamples,
      "medianDepth": medianDepth, "totalSamples": totalSamples,
    ]
  }
}

struct CoverageHole {
  var position: simd_float3
  var size: Int

  func toDictionary() -> [String: Any] {
    return ["x": position.x, "y": position.y, "z": position.z, "size": size]
  }
}

/// All mutating methods are expected to be called from a single analysis queue.
/// `refreshOverlay` builds geometry off-main and commits it on the main thread.
protocol CoverageEngine: AnyObject {
  var rootNode: SCNNode { get }
  func anchorsAdded(_ anchors: [ARAnchor])
  func anchorsUpdated(_ anchors: [ARAnchor])
  func anchorsRemoved(_ anchors: [ARAnchor])
  /// Integrate one qualifying (sharp, tracked) frame into the coverage model.
  func integrate(frame: ARFrame)
  func refreshOverlay()
  func computeStats() -> CoverageStats
  func holes(maxCount: Int) -> [CoverageHole]
  func serialize() -> Data
  func restore(from data: Data)
}

// MARK: - Shared helpers

enum CoverageColor {
  static let red = simd_float4(0.92, 0.26, 0.21, 1)
  static let yellow = simd_float4(0.98, 0.79, 0.18, 1)
  static let green = simd_float4(0.22, 0.86, 0.35, 1)

  static func forScore(_ score: Int) -> simd_float4 {
    switch score {
    case 2: return green
    case 1: return yellow
    default: return red
    }
  }
}

/// Multi-view score from accumulated view-direction octants.
/// 0 = unseen, 1 = single viewpoint (yellow), 2 = ≥2 distinct directions (green).
enum MultiViewScore {
  /// Minimum distinct view octants required for full (green) coverage.
  static let greenOctants = 2

  static func score(count: UInt16, octants: UInt8) -> Int {
    guard count > 0 else { return 0 }
    let views = octants.nonzeroBitCount
    if views >= greenOctants { return 2 }
    return 1
  }
}

/// Clusters points into a coarse voxel grid and returns the biggest clusters.
func clusterHoles(points: [simd_float3], cellSize: Float, maxCount: Int) -> [CoverageHole] {
  var cells: [SIMD3<Int32>: (sum: simd_float3, count: Int)] = [:]
  for p in points {
    let key = SIMD3<Int32>(Int32(floorf(p.x / cellSize)), Int32(floorf(p.y / cellSize)), Int32(floorf(p.z / cellSize)))
    var entry = cells[key] ?? (simd_float3.zero, 0)
    entry.sum += p
    entry.count += 1
    cells[key] = entry
  }
  let sorted = cells.values.sorted { $0.count > $1.count }
  return sorted.prefix(maxCount).map { entry in
    CoverageHole(position: entry.sum / Float(entry.count), size: entry.count)
  }
}

func buildPointCloudGeometry(positions: [simd_float3], colors: [simd_float4], pointSize: CGFloat) -> SCNGeometry {
  let vertexData = positions.withUnsafeBufferPointer { Data(buffer: $0) }
  let vertexSource = SCNGeometrySource(
    data: vertexData, semantic: .vertex, vectorCount: positions.count,
    usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4,
    dataOffset: 0, dataStride: MemoryLayout<simd_float3>.stride
  )
  let colorData = colors.withUnsafeBufferPointer { Data(buffer: $0) }
  let colorSource = SCNGeometrySource(
    data: colorData, semantic: .color, vectorCount: colors.count,
    usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: 4,
    dataOffset: 0, dataStride: MemoryLayout<simd_float4>.stride
  )
  var indices = [UInt32](0..<UInt32(positions.count))
  let indexData = indices.withUnsafeBufferPointer { Data(buffer: $0) }
  let element = SCNGeometryElement(
    data: indexData, primitiveType: .point,
    primitiveCount: positions.count, bytesPerIndex: 4
  )
  element.pointSize = pointSize
  element.minimumPointScreenSpaceRadius = max(2, pointSize * 0.6)
  element.maximumPointScreenSpaceRadius = pointSize * 3
  let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
  let material = SCNMaterial()
  material.lightingModel = .constant
  material.isDoubleSided = true
  material.writesToDepthBuffer = false
  material.readsFromDepthBuffer = false
  material.transparency = 0.92
  geometry.materials = [material]
  return geometry
}

func buildColoredMeshGeometry(vertices: [simd_float3], colors: [simd_float4], faces: [UInt32]) -> SCNGeometry {
  let vertexData = vertices.withUnsafeBufferPointer { Data(buffer: $0) }
  let vertexSource = SCNGeometrySource(
    data: vertexData, semantic: .vertex, vectorCount: vertices.count,
    usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4,
    dataOffset: 0, dataStride: MemoryLayout<simd_float3>.stride
  )
  let colorData = colors.withUnsafeBufferPointer { Data(buffer: $0) }
  let colorSource = SCNGeometrySource(
    data: colorData, semantic: .color, vectorCount: colors.count,
    usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: 4,
    dataOffset: 0, dataStride: MemoryLayout<simd_float4>.stride
  )
  let indexData = faces.withUnsafeBufferPointer { Data(buffer: $0) }
  let element = SCNGeometryElement(
    data: indexData, primitiveType: .triangles,
    primitiveCount: faces.count / 3, bytesPerIndex: 4
  )
  let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
  let material = SCNMaterial()
  material.lightingModel = .constant
  material.isDoubleSided = true
  material.transparency = 0.42
  material.writesToDepthBuffer = false
  geometry.materials = [material]
  return geometry
}

// MARK: - LiDAR hybrid coverage (planar mesh + depth point cloud)

/// Dense 5 cm voxels from LiDAR depth. Large flat surfaces (floor/wall/ceiling/table)
/// are colored on the reconstruction mesh; everything else is shown as small points.
final class MeshCoverageEngine: CoverageEngine {
  let rootNode = SCNNode()
  private let pointNode = SCNNode()

  private struct VoxelInfo {
    var count: UInt16 = 0
    var octants: UInt8 = 0
    var sum: simd_float3 = .zero
  }

  private enum SurfaceKind {
    case floor, wall, ceiling, other
  }

  private final class AnchorData {
    var vertices: [simd_float3] = []
    var normals: [simd_float3] = []
    /// Only planar (floor/wall/ceiling/table) triangle indices.
    var planarFaces: [UInt32] = []
    var planarCenters: [simd_float3] = []
    var transform = matrix_identity_float4x4
    let node = SCNNode()
    var dirty = true
    var lastRecache: TimeInterval = 0
  }

  private let voxelSize: Float = 0.05
  private let minDepth: Float = 0.25
  private let maxDepth: Float = 5.5
  private let maxPointOverlay: Int = 55_000
  private let planarProximity: Float = 0.08

  private var voxels: [SIMD3<Int32>: VoxelInfo] = [:]
  private var anchors: [UUID: AnchorData] = [:]
  private var lastMedianDepth: Float = 0
  private var cachedRedPositions: [simd_float3] = []
  private var cachedYellowPositions: [simd_float3] = []
  private var pointsDirty = true
  /// Voxel keys on / near planar mesh faces — excluded from point overlay.
  private var planarVoxelKeys = Set<SIMD3<Int32>>()
  private var referenceCameraY: Float?

  init() {
    rootNode.addChildNode(pointNode)
  }

  private func voxelKey(_ p: simd_float3) -> SIMD3<Int32> {
    SIMD3<Int32>(Int32(floorf(p.x / voxelSize)), Int32(floorf(p.y / voxelSize)), Int32(floorf(p.z / voxelSize)))
  }

  private func voxelCenter(_ key: SIMD3<Int32>) -> simd_float3 {
    simd_float3(
      (Float(key.x) + 0.5) * voxelSize,
      (Float(key.y) + 0.5) * voxelSize,
      (Float(key.z) + 0.5) * voxelSize
    )
  }

  private func voxelPosition(_ key: SIMD3<Int32>, _ info: VoxelInfo) -> simd_float3 {
    if info.count > 0 {
      return info.sum / Float(info.count)
    }
    return voxelCenter(key)
  }

  // MARK: Anchors

  func anchorsAdded(_ anchorList: [ARAnchor]) {
    for anchor in anchorList {
      guard let mesh = anchor as? ARMeshAnchor else { continue }
      let data = AnchorData()
      anchors[mesh.identifier] = data
      recache(mesh, into: data)
      let node = data.node
      let transform = mesh.transform
      DispatchQueue.main.async { [rootNode] in
        node.simdTransform = transform
        rootNode.addChildNode(node)
      }
    }
  }

  func anchorsUpdated(_ anchorList: [ARAnchor]) {
    let now = CACurrentMediaTime()
    for anchor in anchorList {
      guard let mesh = anchor as? ARMeshAnchor, let data = anchors[mesh.identifier] else {
        anchorsAdded([anchor])
        continue
      }
      data.transform = mesh.transform
      let node = data.node
      let transform = mesh.transform
      DispatchQueue.main.async { node.simdTransform = transform }
      if now - data.lastRecache > 0.7 {
        recache(mesh, into: data)
      }
    }
  }

  func anchorsRemoved(_ anchorList: [ARAnchor]) {
    for anchor in anchorList {
      guard let data = anchors.removeValue(forKey: anchor.identifier) else { continue }
      let node = data.node
      DispatchQueue.main.async { node.removeFromParentNode() }
    }
    rebuildPlanarVoxelKeys()
    pointsDirty = true
  }

  private func recache(_ mesh: ARMeshAnchor, into data: AnchorData) {
    let g = mesh.geometry
    data.vertices = copyVectors(source: g.vertices)
    data.normals = copyVectors(source: g.normals)
    let allFaces = copyFaces(element: g.faces)
    data.transform = mesh.transform

    let classifications = copyClassifications(from: g)
    var planarFaces: [UInt32] = []
    var planarCenters: [simd_float3] = []
    planarFaces.reserveCapacity(allFaces.count / 2)
    let transform = mesh.transform
    let faceCount = allFaces.count / 3

    for f in 0..<faceCount {
      let i0 = Int(allFaces[f * 3])
      let i1 = Int(allFaces[f * 3 + 1])
      let i2 = Int(allFaces[f * 3 + 2])
      guard i0 < data.vertices.count, i1 < data.vertices.count, i2 < data.vertices.count else { continue }

      let planar: Bool
      if !classifications.isEmpty, f < classifications.count {
        planar = isPlanarClassification(classifications[f])
      } else {
        planar = isPlanarByNormal(data.normals, indices: [i0, i1, i2], transform: transform)
      }
      guard planar else { continue }

      planarFaces.append(allFaces[f * 3])
      planarFaces.append(allFaces[f * 3 + 1])
      planarFaces.append(allFaces[f * 3 + 2])

      let w0 = transform * simd_float4(data.vertices[i0], 1)
      let w1 = transform * simd_float4(data.vertices[i1], 1)
      let w2 = transform * simd_float4(data.vertices[i2], 1)
      planarCenters.append(simd_float3(
        (w0.x + w1.x + w2.x) / 3,
        (w0.y + w1.y + w2.y) / 3,
        (w0.z + w1.z + w2.z) / 3
      ))
    }

    data.planarFaces = planarFaces
    data.planarCenters = planarCenters
    data.dirty = true
    data.lastRecache = CACurrentMediaTime()
    rebuildPlanarVoxelKeys()
    pointsDirty = true
  }

  private func rebuildPlanarVoxelKeys() {
    var keys = Set<SIMD3<Int32>>()
    let radius = Int(ceilf(planarProximity / voxelSize))
    for (_, data) in anchors {
      for c in data.planarCenters {
        let base = voxelKey(c)
        for dx in -radius...radius {
          for dy in -radius...radius {
            for dz in -radius...radius {
              keys.insert(SIMD3<Int32>(base.x + Int32(dx), base.y + Int32(dy), base.z + Int32(dz)))
            }
          }
        }
      }
    }
    planarVoxelKeys = keys
  }

  private func isPlanarClassification(_ c: ARMeshClassification) -> Bool {
    switch c {
    case .floor, .wall, .ceiling, .table: return true
    default: return false
    }
  }

  private func isPlanarByNormal(_ normals: [simd_float3], indices: [Int], transform: simd_float4x4) -> Bool {
    var sum = simd_float3.zero
    var n = 0
    for i in indices where i < normals.count {
      let local = normals[i]
      let world = transform * simd_float4(local.x, local.y, local.z, 0)
      sum += simd_float3(world.x, world.y, world.z)
      n += 1
    }
    guard n > 0 else { return false }
    let avg = simd_normalize(sum / Float(n))
    let upDot = abs(avg.y)
    return upDot > 0.75 || upDot < 0.25
  }

  private func surfaceKind(worldY: Float, normalY: Float) -> SurfaceKind {
    let ref = referenceCameraY ?? worldY
    if worldY > ref + 1.1 { return .ceiling }
    if worldY < ref - 0.7 { return .floor }
    if abs(normalY) < 0.45 { return .wall }
    if normalY > 0.6 { return .floor }
    if normalY < -0.6 { return .ceiling }
    return .other
  }

  private func copyVectors(source: ARGeometrySource) -> [simd_float3] {
    let count = source.count
    var out = [simd_float3](repeating: .zero, count: count)
    let buf = source.buffer.contents().advanced(by: source.offset)
    let stride = source.stride
    for i in 0..<count {
      let p = buf.advanced(by: i * stride).assumingMemoryBound(to: Float.self)
      out[i] = simd_float3(p[0], p[1], p[2])
    }
    return out
  }

  private func copyFaces(element: ARGeometryElement) -> [UInt32] {
    let indexCount = element.count * element.indexCountPerPrimitive
    var out = [UInt32](repeating: 0, count: indexCount)
    let buf = element.buffer.contents()
    if element.bytesPerIndex == 4 {
      memcpy(&out, buf, indexCount * 4)
    } else if element.bytesPerIndex == 2 {
      let p = buf.assumingMemoryBound(to: UInt16.self)
      for i in 0..<indexCount { out[i] = UInt32(p[i]) }
    }
    return out
  }

  private func copyClassifications(from geometry: ARMeshGeometry) -> [ARMeshClassification] {
    guard let source = geometry.classification else { return [] }
    let count = source.count
    var out = [ARMeshClassification](repeating: .none, count: count)
    let buf = source.buffer.contents().advanced(by: source.offset)
    let stride = source.stride
    for i in 0..<count {
      let raw = buf.advanced(by: i * stride).assumingMemoryBound(to: UInt8.self).pointee
      out[i] = ARMeshClassification(rawValue: Int(raw)) ?? .none
    }
    return out
  }

  // MARK: Integration

  func integrate(frame: ARFrame) {
    guard let depth = frame.sceneDepth else { return }
    let depthMap = depth.depthMap
    CVPixelBufferLockBaseAddress(depthMap, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
    guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return }
    let dw = CVPixelBufferGetWidth(depthMap)
    let dh = CVPixelBufferGetHeight(depthMap)
    let depthRow = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.size
    let depthPtr = depthBase.assumingMemoryBound(to: Float32.self)

    var confPtr: UnsafeMutablePointer<UInt8>? = nil
    var confRow = 0
    var confLocked = false
    if let confMap = depth.confidenceMap {
      CVPixelBufferLockBaseAddress(confMap, .readOnly)
      confLocked = true
      confPtr = CVPixelBufferGetBaseAddress(confMap)?.assumingMemoryBound(to: UInt8.self)
      confRow = CVPixelBufferGetBytesPerRow(confMap)
    }
    defer {
      if confLocked, let confMap = depth.confidenceMap {
        CVPixelBufferUnlockBaseAddress(confMap, .readOnly)
      }
    }

    let camera = frame.camera
    let intrinsics = camera.intrinsics
    let imageSize = camera.imageResolution
    let sx = Float(dw) / Float(imageSize.width)
    let sy = Float(dh) / Float(imageSize.height)
    let fx = intrinsics[0][0] * sx
    let fy = intrinsics[1][1] * sy
    let cx = intrinsics[2][0] * sx
    let cy = intrinsics[2][1] * sy
    guard fx > 0, fy > 0 else { return }

    let transform = camera.transform
    let camPos = simd_float3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
    if referenceCameraY == nil { referenceCameraY = camPos.y }

    var depthSamples: [Float] = []
    depthSamples.reserveCapacity(256)

    let forward = -simd_float3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
    let lookingUp = forward.y > 0.35
    let effectiveMaxDepth = lookingUp ? max(maxDepth, 6.5) : maxDepth

    // Plan: stride 2 for denser-than-original accumulation while staying smooth.
    let stride = 2
    var v = 0
    while v < dh {
      var u = 0
      while u < dw {
        let d = depthPtr[v * depthRow + u]
        if d.isFinite && d > minDepth && d < effectiveMaxDepth {
          if let cp = confPtr {
            if cp[v * confRow + u] < 1 { u += stride; continue }
          }
          let xc = (Float(u) - cx) * d / fx
          let yc = -(Float(v) - cy) * d / fy
          let local = simd_float4(xc, yc, -d, 1)
          let world4 = transform * local
          let world = simd_float3(world4.x, world4.y, world4.z)

          let viewDir = simd_normalize(world - camPos)
          let octant: UInt8 = (viewDir.x > 0 ? 1 : 0) | (viewDir.y > 0 ? 2 : 0) | (viewDir.z > 0 ? 4 : 0)

          let key = voxelKey(world)
          var info = voxels[key] ?? VoxelInfo()
          if info.count < 1000 {
            info.sum += world
            info.count += 1
          }
          info.octants |= UInt8(1 << (octant & 7))
          voxels[key] = info

          if depthSamples.count < 256 && (u % 16 == 0) && (v % 16 == 0) {
            depthSamples.append(d)
          }
        }
        u += stride
      }
      v += stride
    }

    if !depthSamples.isEmpty {
      depthSamples.sort()
      lastMedianDepth = depthSamples[depthSamples.count / 2]
    }
    for (_, data) in anchors { data.dirty = true }
    pointsDirty = true
  }

  private func score(worldPos: simd_float3) -> Int {
    let base = voxelKey(worldPos)
    var best = score(info: voxels[base])
    if best >= 2 { return best }
    for dx in Int32(-1)...Int32(1) {
      for dy in Int32(-1)...Int32(1) {
        for dz in Int32(-1)...Int32(1) {
          if dx == 0 && dy == 0 && dz == 0 { continue }
          let s = score(info: voxels[SIMD3<Int32>(base.x + dx, base.y + dy, base.z + dz)])
          if s > best { best = s }
          if best >= 2 { return best }
        }
      }
    }
    return best
  }

  private func score(info: VoxelInfo?) -> Int {
    guard let info = info else { return 0 }
    return MultiViewScore.score(count: info.count, octants: info.octants)
  }

  private func isNearPlanarSurface(_ world: simd_float3) -> Bool {
    planarVoxelKeys.contains(voxelKey(world))
  }

  // MARK: Overlay

  func refreshOverlay() {
    for (_, data) in anchors where data.dirty {
      data.dirty = false
      guard !data.vertices.isEmpty, !data.planarFaces.isEmpty else {
        let node = data.node
        DispatchQueue.main.async { node.geometry = nil }
        continue
      }
      let transform = data.transform
      var colors = [simd_float4](repeating: CoverageColor.red, count: data.vertices.count)
      for i in 0..<data.vertices.count {
        let local = data.vertices[i]
        let w4 = transform * simd_float4(local.x, local.y, local.z, 1)
        colors[i] = CoverageColor.forScore(score(worldPos: simd_float3(w4.x, w4.y, w4.z)))
      }
      let geometry = buildColoredMeshGeometry(vertices: data.vertices, colors: colors, faces: data.planarFaces)
      let node = data.node
      DispatchQueue.main.async {
        node.geometry = geometry
        node.simdTransform = transform
      }
    }

    if pointsDirty {
      pointsDirty = false
      refreshPointOverlay()
    }
  }

  private func refreshPointOverlay() {
    var positions: [simd_float3] = []
    var colors: [simd_float4] = []
    positions.reserveCapacity(min(voxels.count, maxPointOverlay))
    colors.reserveCapacity(min(voxels.count, maxPointOverlay))

    let step = max(1, voxels.count / maxPointOverlay)
    var i = 0
    for (key, info) in voxels {
      i += 1
      if step > 1 && (i % step) != 0 { continue }
      let world = voxelPosition(key, info)
      // Plan: only non-planar remainder as points (avoid double-draw on walls/floors).
      if isNearPlanarSurface(world) { continue }
      positions.append(world)
      colors.append(CoverageColor.forScore(score(info: info)))
      if positions.count >= maxPointOverlay { break }
    }

    let geometry: SCNGeometry? = positions.isEmpty
      ? nil
      : buildPointCloudGeometry(positions: positions, colors: colors, pointSize: 4)
    DispatchQueue.main.async { [pointNode] in
      pointNode.geometry = geometry
      pointNode.renderingOrder = 10
    }
  }

  // MARK: Stats

  func computeStats() -> CoverageStats {
    var stats = CoverageStats()
    var green = 0, yellow = 0, red = 0
    var wallTotal = 0, wallGreen = 0
    var ceilTotal = 0, ceilGreen = 0
    var floorTotal = 0, floorGreen = 0
    var redPositions: [simd_float3] = []
    var yellowPositions: [simd_float3] = []
    var countedKeys = Set<SIMD3<Int32>>()
    let refY = referenceCameraY ?? 0

    // Planar mesh samples (no double-count with nearby point voxels).
    for (_, data) in anchors {
      let transform = data.transform
      var sampled = Set<Int>()
      for fi in stride(from: 0, to: data.planarFaces.count, by: 3) {
        for offset in 0..<3 {
          let vi = Int(data.planarFaces[fi + offset])
          if sampled.contains(vi) { continue }
          sampled.insert(vi)
          guard vi < data.vertices.count else { continue }
          let local = data.vertices[vi]
          let w4 = transform * simd_float4(local.x, local.y, local.z, 1)
          let world = simd_float3(w4.x, w4.y, w4.z)
          let key = voxelKey(world)
          countedKeys.insert(key)
          let s = score(worldPos: world)
          var normalY: Float = 0
          if vi < data.normals.count {
            let n = data.normals[vi]
            let nw = transform * simd_float4(n.x, n.y, n.z, 0)
            normalY = nw.y
          }
          switch s {
          case 2: green += 1
          case 1:
            yellow += 1
            if yellowPositions.count < 20000 { yellowPositions.append(world) }
          default:
            red += 1
            if redPositions.count < 20000 { redPositions.append(world) }
          }
          switch surfaceKind(worldY: world.y, normalY: normalY) {
          case .floor: floorTotal += 1; if s == 2 { floorGreen += 1 }
          case .ceiling: ceilTotal += 1; if s == 2 { ceilGreen += 1 }
          case .wall: wallTotal += 1; if s == 2 { wallGreen += 1 }
          case .other: break
          }
        }
      }
    }

    // Non-planar voxels as point samples.
    for (key, info) in voxels {
      if countedKeys.contains(key) { continue }
      let world = voxelPosition(key, info)
      if isNearPlanarSurface(world) { continue }
      let s = score(info: info)
      switch s {
      case 2: green += 1
      case 1:
        yellow += 1
        if yellowPositions.count < 20000 { yellowPositions.append(world) }
      default:
        red += 1
        if redPositions.count < 20000 { redPositions.append(world) }
      }
      if world.y > refY + 1.1 {
        ceilTotal += 1; if s == 2 { ceilGreen += 1 }
      } else if world.y < refY - 0.7 {
        floorTotal += 1; if s == 2 { floorGreen += 1 }
      } else {
        wallTotal += 1; if s == 2 { wallGreen += 1 }
      }
    }

    let total = green + yellow + red
    stats.totalSamples = total
    if total > 0 {
      stats.green = Float(green) / Float(total)
      stats.yellow = Float(yellow) / Float(total)
      stats.red = Float(red) / Float(total)
    } else {
      stats.green = 0
      stats.yellow = 0
      stats.red = 1
    }
    stats.wallsGreen = wallTotal > 0 ? Float(wallGreen) / Float(wallTotal) : 0
    stats.ceilingGreen = ceilTotal > 0 ? Float(ceilGreen) / Float(ceilTotal) : 0
    stats.floorGreen = floorTotal > 0 ? Float(floorGreen) / Float(floorTotal) : 0
    stats.ceilingSamples = ceilTotal
    stats.floorSamples = floorTotal
    stats.medianDepth = lastMedianDepth
    cachedRedPositions = redPositions
    cachedYellowPositions = yellowPositions
    return stats
  }

  func holes(maxCount: Int) -> [CoverageHole] {
    // Prefer unseen (red); once mostly filled, guide to single-view (yellow) gaps.
    let points = cachedRedPositions.count >= 40 ? cachedRedPositions : cachedYellowPositions
    return clusterHoles(points: points, cellSize: 0.45, maxCount: maxCount)
  }

  // MARK: Persistence (voxel grid)

  func serialize() -> Data {
    var data = Data(capacity: voxels.count * 15)
    for (key, info) in voxels {
      var k = key
      var c = info.count
      var o = info.octants
      withUnsafeBytes(of: &k) { data.append(contentsOf: $0) }
      withUnsafeBytes(of: &c) { data.append(contentsOf: $0) }
      withUnsafeBytes(of: &o) { data.append(contentsOf: $0) }
    }
    return data
  }

  func restore(from data: Data) {
    let entrySize = MemoryLayout<SIMD3<Int32>>.size + 2 + 1
    var offset = 0
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      while offset + entrySize <= raw.count {
        let key = raw.loadUnaligned(fromByteOffset: offset, as: SIMD3<Int32>.self)
        let count = raw.loadUnaligned(fromByteOffset: offset + MemoryLayout<SIMD3<Int32>>.size, as: UInt16.self)
        let octants = raw.loadUnaligned(fromByteOffset: offset + MemoryLayout<SIMD3<Int32>>.size + 2, as: UInt8.self)
        voxels[key] = VoxelInfo(count: count, octants: octants, sum: voxelCenter(key) * Float(count))
        offset += entrySize
      }
    }
    pointsDirty = true
    for (_, data) in anchors { data.dirty = true }
  }
}

// MARK: - Plane-based fallback (no LiDAR)

/// Coverage on detected planes (10 cm tiles) plus ARPointCloud feature points as a
/// sparse overlay for non-planar structure.
final class PlaneCoverageEngine: CoverageEngine {
  let rootNode = SCNNode()
  private let pointNode = SCNNode()

  private struct Cell {
    var count: UInt16 = 0
    var octants: UInt8 = 0
  }

  private struct FeatureVoxel {
    var count: UInt16 = 0
    var octants: UInt8 = 0
  }

  private final class PlaneData {
    var transform = matrix_identity_float4x4
    var center = simd_float3.zero
    var extentX: Float = 0
    var extentZ: Float = 0
    var alignment: ARPlaneAnchor.Alignment = .horizontal
    var cells: [SIMD2<Int32>: Cell] = [:]
    let node = SCNNode()
    var dirty = true
  }

  private let cellSize: Float = 0.10
  private let featureVoxelSize: Float = 0.08
  private let maxPointOverlay: Int = 30_000
  private var planes: [UUID: PlaneData] = [:]
  private var featureVoxels: [SIMD3<Int32>: FeatureVoxel] = [:]
  private var lastMedianDepth: Float = 0
  private var cachedRedPositions: [simd_float3] = []
  private var cachedYellowPositions: [simd_float3] = []
  private var referenceCameraY: Float?
  private var pointsDirty = true

  init() {
    rootNode.addChildNode(pointNode)
  }

  private func featureKey(_ p: simd_float3) -> SIMD3<Int32> {
    SIMD3<Int32>(
      Int32(floorf(p.x / featureVoxelSize)),
      Int32(floorf(p.y / featureVoxelSize)),
      Int32(floorf(p.z / featureVoxelSize))
    )
  }

  private func featureCenter(_ key: SIMD3<Int32>) -> simd_float3 {
    simd_float3(
      (Float(key.x) + 0.5) * featureVoxelSize,
      (Float(key.y) + 0.5) * featureVoxelSize,
      (Float(key.z) + 0.5) * featureVoxelSize
    )
  }

  func anchorsAdded(_ anchorList: [ARAnchor]) {
    for anchor in anchorList {
      guard let plane = anchor as? ARPlaneAnchor else { continue }
      let data = PlaneData()
      update(data, from: plane)
      planes[plane.identifier] = data
      let node = data.node
      DispatchQueue.main.async { [rootNode] in
        rootNode.addChildNode(node)
      }
    }
  }

  func anchorsUpdated(_ anchorList: [ARAnchor]) {
    for anchor in anchorList {
      guard let plane = anchor as? ARPlaneAnchor else { continue }
      guard let data = planes[plane.identifier] else {
        anchorsAdded([anchor])
        continue
      }
      update(data, from: plane)
    }
  }

  func anchorsRemoved(_ anchorList: [ARAnchor]) {
    for anchor in anchorList {
      guard let data = planes.removeValue(forKey: anchor.identifier) else { continue }
      let node = data.node
      DispatchQueue.main.async { node.removeFromParentNode() }
    }
  }

  private func update(_ data: PlaneData, from plane: ARPlaneAnchor) {
    data.transform = plane.transform
    data.center = plane.center
    data.extentX = plane.planeExtent.width
    data.extentZ = plane.planeExtent.height
    data.alignment = plane.alignment
    data.dirty = true
  }

  private func isNearPlane(_ world: simd_float3) -> Bool {
    for (_, data) in planes {
      let inv = data.transform.inverse
      let local4 = inv * simd_float4(world.x, world.y, world.z, 1)
      let local = simd_float3(local4.x, local4.y, local4.z)
      let halfX = data.extentX / 2 + cellSize
      let halfZ = data.extentZ / 2 + cellSize
      if abs(local.y) < 0.12,
         local.x >= data.center.x - halfX, local.x <= data.center.x + halfX,
         local.z >= data.center.z - halfZ, local.z <= data.center.z + halfZ {
        return true
      }
    }
    return false
  }

  func integrate(frame: ARFrame) {
    let camera = frame.camera
    let transform = camera.transform
    let camPos = simd_float3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
    if referenceCameraY == nil { referenceCameraY = camPos.y }
    let imageSize = camera.imageResolution

    // ARPointCloud → feature voxels (non-planar coverage + median depth).
    if let cloud = frame.rawFeaturePoints, !cloud.points.isEmpty {
      var dists: [Float] = []
      dists.reserveCapacity(min(400, cloud.points.count))
      for p in cloud.points {
        let dist = simd_length(p - camPos)
        if dists.count < 400 { dists.append(dist) }
        if dist < 0.3 || dist > 4.5 { continue }
        if isNearPlane(p) { continue }

        let viewDir = simd_normalize(p - camPos)
        let octant: UInt8 = (viewDir.x > 0 ? 1 : 0) | (viewDir.y > 0 ? 2 : 0) | (viewDir.z > 0 ? 4 : 0)
        let key = featureKey(p)
        var info = featureVoxels[key] ?? FeatureVoxel()
        if info.count < 1000 { info.count += 1 }
        info.octants |= UInt8(1 << (octant & 7))
        featureVoxels[key] = info
      }
      if !dists.isEmpty {
        dists.sort()
        lastMedianDepth = dists[dists.count / 2]
      }
      pointsDirty = true
    }

    for (_, data) in planes {
      let planeTransform = data.transform
      let normal4 = planeTransform * simd_float4(0, 1, 0, 0)
      let normal = simd_normalize(simd_float3(normal4.x, normal4.y, normal4.z))

      let minX = data.center.x - data.extentX / 2
      let maxX = data.center.x + data.extentX / 2
      let minZ = data.center.z - data.extentZ / 2
      let maxZ = data.center.z + data.extentZ / 2

      var ix = Int32(floorf(minX / cellSize))
      let ixEnd = Int32(floorf(maxX / cellSize))
      while ix <= ixEnd {
        var iz = Int32(floorf(minZ / cellSize))
        let izEnd = Int32(floorf(maxZ / cellSize))
        while iz <= izEnd {
          let localX = (Float(ix) + 0.5) * cellSize
          let localZ = (Float(iz) + 0.5) * cellSize
          let w4 = planeTransform * simd_float4(localX, 0, localZ, 1)
          let world = simd_float3(w4.x, w4.y, w4.z)

          let toCell = world - camPos
          let dist = simd_length(toCell)
          if dist < 0.3 || dist > 4.5 { iz += 1; continue }
          let viewDir = toCell / dist
          // Viewing angle vs surface normal must be < ~65 deg.
          if abs(simd_dot(viewDir, normal)) < 0.42 { iz += 1; continue }

          let projected = camera.projectPoint(world, orientation: .landscapeRight, viewportSize: imageSize)
          if projected.x < 0 || projected.y < 0 || projected.x > imageSize.width || projected.y > imageSize.height {
            iz += 1; continue
          }
          // Reject points behind the camera: transform into camera space.
          let camSpace = simd_mul(simd_inverse(transform), simd_float4(world.x, world.y, world.z, 1))
          if camSpace.z > 0 { iz += 1; continue }

          let key = SIMD2<Int32>(ix, iz)
          var cell = data.cells[key] ?? Cell()
          if cell.count < 1000 { cell.count += 1 }
          let octant: UInt8 = (viewDir.x > 0 ? 1 : 0) | (viewDir.y > 0 ? 2 : 0) | (viewDir.z > 0 ? 4 : 0)
          cell.octants |= UInt8(1 << (octant & 7))
          data.cells[key] = cell
          data.dirty = true
          iz += 1
        }
        ix += 1
      }
    }
  }

  private func cellScore(_ cell: Cell?) -> Int {
    guard let cell = cell else { return 0 }
    return MultiViewScore.score(count: cell.count, octants: cell.octants)
  }

  private func featureScore(_ info: FeatureVoxel?) -> Int {
    guard let info = info else { return 0 }
    return MultiViewScore.score(count: info.count, octants: info.octants)
  }

  func refreshOverlay() {
    for (_, data) in planes where data.dirty {
      data.dirty = false
      guard data.extentX > 0.1, data.extentZ > 0.1 else { continue }

      let cols = max(1, Int(ceilf(data.extentX / cellSize)))
      let rows = max(1, Int(ceilf(data.extentZ / cellSize)))
      let minX = data.center.x - data.extentX / 2
      let minZ = data.center.z - data.extentZ / 2

      let scale = 8
      let size = CGSize(width: cols * scale, height: rows * scale)
      let renderer = UIGraphicsImageRenderer(size: size)
      let image = renderer.image { ctx in
        for r in 0..<rows {
          for c in 0..<cols {
            let localX = minX + (Float(c) + 0.5) * cellSize
            let localZ = minZ + (Float(r) + 0.5) * cellSize
            let key = SIMD2<Int32>(Int32(floorf(localX / cellSize)), Int32(floorf(localZ / cellSize)))
            let color = CoverageColor.forScore(cellScore(data.cells[key]))
            ctx.cgContext.setFillColor(UIColor(
              red: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z), alpha: 1
            ).cgColor)
            ctx.cgContext.fill(CGRect(x: c * scale, y: r * scale, width: scale, height: scale))
          }
        }
      }

      let plane = SCNPlane(width: CGFloat(data.extentX), height: CGFloat(data.extentZ))
      let material = SCNMaterial()
      material.diffuse.contents = image
      material.diffuse.magnificationFilter = .nearest
      material.lightingModel = .constant
      material.isDoubleSided = true
      material.transparency = 0.42
      material.writesToDepthBuffer = false
      plane.materials = [material]

      let node = data.node
      let transform = data.transform
      let center = data.center
      DispatchQueue.main.async {
        node.geometry = plane
        // SCNPlane lies in xy; rotate into the anchor's xz plane and offset to center.
        node.simdTransform = simd_mul(transform, simd_mul(
          simd_float4x4(translation: center),
          simd_float4x4(rotationX: -.pi / 2)
        ))
      }
    }

    if pointsDirty {
      pointsDirty = false
      refreshPointOverlay()
    }
  }

  private func refreshPointOverlay() {
    var positions: [simd_float3] = []
    var colors: [simd_float4] = []
    positions.reserveCapacity(min(featureVoxels.count, maxPointOverlay))
    colors.reserveCapacity(min(featureVoxels.count, maxPointOverlay))

    let step = max(1, featureVoxels.count / maxPointOverlay)
    var i = 0
    for (key, info) in featureVoxels {
      i += 1
      if step > 1 && (i % step) != 0 { continue }
      let world = featureCenter(key)
      if isNearPlane(world) { continue }
      positions.append(world)
      colors.append(CoverageColor.forScore(featureScore(info)))
      if positions.count >= maxPointOverlay { break }
    }

    let geometry: SCNGeometry? = positions.isEmpty
      ? nil
      : buildPointCloudGeometry(positions: positions, colors: colors, pointSize: 4)
    DispatchQueue.main.async { [pointNode] in
      pointNode.geometry = geometry
    }
  }

  func computeStats() -> CoverageStats {
    var stats = CoverageStats()
    var green = 0, yellow = 0, red = 0
    var wallTotal = 0, wallGreen = 0
    var ceilTotal = 0, ceilGreen = 0
    var floorTotal = 0, floorGreen = 0
    var redPositions: [simd_float3] = []
    var yellowPositions: [simd_float3] = []
    let refY = referenceCameraY ?? 0

    for (_, data) in planes {
      guard data.extentX > 0.1, data.extentZ > 0.1 else { continue }
      let cols = max(1, Int(ceilf(data.extentX / cellSize)))
      let rows = max(1, Int(ceilf(data.extentZ / cellSize)))
      let minX = data.center.x - data.extentX / 2
      let minZ = data.center.z - data.extentZ / 2

      let planeY = (data.transform * simd_float4(data.center.x, 0, data.center.z, 1)).y
      enum PlaneClass { case wall, ceiling, floor }
      let cls: PlaneClass
      if data.alignment == .vertical {
        cls = .wall
      } else if planeY > refY + 0.5 {
        cls = .ceiling
      } else {
        cls = .floor
      }

      for r in 0..<rows {
        for c in 0..<cols {
          let localX = minX + (Float(c) + 0.5) * cellSize
          let localZ = minZ + (Float(r) + 0.5) * cellSize
          let key = SIMD2<Int32>(Int32(floorf(localX / cellSize)), Int32(floorf(localZ / cellSize)))
          let s = cellScore(data.cells[key])
          switch s {
          case 2: green += 1
          case 1:
            yellow += 1
            if yellowPositions.count < 20000 {
              let w4 = data.transform * simd_float4(localX, 0, localZ, 1)
              yellowPositions.append(simd_float3(w4.x, w4.y, w4.z))
            }
          default:
            red += 1
            if redPositions.count < 20000 {
              let w4 = data.transform * simd_float4(localX, 0, localZ, 1)
              redPositions.append(simd_float3(w4.x, w4.y, w4.z))
            }
          }
          switch cls {
          case .wall: wallTotal += 1; if s == 2 { wallGreen += 1 }
          case .ceiling: ceilTotal += 1; if s == 2 { ceilGreen += 1 }
          case .floor: floorTotal += 1; if s == 2 { floorGreen += 1 }
          }
        }
      }
    }

    for (key, info) in featureVoxels {
      let world = featureCenter(key)
      if isNearPlane(world) { continue }
      let s = featureScore(info)
      switch s {
      case 2: green += 1
      case 1:
        yellow += 1
        if yellowPositions.count < 20000 { yellowPositions.append(world) }
      default:
        red += 1
        if redPositions.count < 20000 { redPositions.append(world) }
      }
    }

    let total = green + yellow + red
    stats.totalSamples = total
    if total > 0 {
      stats.green = Float(green) / Float(total)
      stats.yellow = Float(yellow) / Float(total)
      stats.red = Float(red) / Float(total)
    }
    stats.wallsGreen = wallTotal > 0 ? Float(wallGreen) / Float(wallTotal) : 0
    stats.ceilingGreen = ceilTotal > 0 ? Float(ceilGreen) / Float(ceilTotal) : 0
    stats.floorGreen = floorTotal > 0 ? Float(floorGreen) / Float(floorTotal) : 0
    stats.ceilingSamples = ceilTotal
    stats.floorSamples = floorTotal
    stats.medianDepth = lastMedianDepth
    cachedRedPositions = redPositions
    cachedYellowPositions = yellowPositions
    return stats
  }

  func holes(maxCount: Int) -> [CoverageHole] {
    let points = cachedRedPositions.count >= 40 ? cachedRedPositions : cachedYellowPositions
    return clusterHoles(points: points, cellSize: 0.55, maxCount: maxCount)
  }

  // Plane grids are cheap to rebuild; persist feature voxels only for resume continuity.
  func serialize() -> Data {
    var data = Data(capacity: featureVoxels.count * 15)
    for (key, info) in featureVoxels {
      var k = key
      var c = info.count
      var o = info.octants
      withUnsafeBytes(of: &k) { data.append(contentsOf: $0) }
      withUnsafeBytes(of: &c) { data.append(contentsOf: $0) }
      withUnsafeBytes(of: &o) { data.append(contentsOf: $0) }
    }
    return data
  }

  func restore(from data: Data) {
    let entrySize = MemoryLayout<SIMD3<Int32>>.size + 2 + 1
    var offset = 0
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      while offset + entrySize <= raw.count {
        let key = raw.loadUnaligned(fromByteOffset: offset, as: SIMD3<Int32>.self)
        let count = raw.loadUnaligned(fromByteOffset: offset + MemoryLayout<SIMD3<Int32>>.size, as: UInt16.self)
        let octants = raw.loadUnaligned(fromByteOffset: offset + MemoryLayout<SIMD3<Int32>>.size + 2, as: UInt8.self)
        featureVoxels[key] = FeatureVoxel(count: count, octants: octants)
        offset += entrySize
      }
    }
    pointsDirty = true
  }
}

// MARK: - simd helpers

extension simd_float4x4 {
  init(translation t: simd_float3) {
    self = matrix_identity_float4x4
    columns.3 = simd_float4(t.x, t.y, t.z, 1)
  }

  init(rotationX angle: Float) {
    self = matrix_identity_float4x4
    columns.1 = simd_float4(0, cos(angle), sin(angle), 0)
    columns.2 = simd_float4(0, -sin(angle), cos(angle), 0)
  }
}

private extension simd_float4 {
  init(_ v: simd_float3, _ w: Float) {
    self.init(v.x, v.y, v.z, w)
  }
}
