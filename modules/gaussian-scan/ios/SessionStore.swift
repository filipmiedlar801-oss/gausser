import Foundation

/// Manages on-disk storage of scan sessions:
/// Documents/scans/<id>/{images/, manifest.json, meta.json, coverage.json, coverage.bin, scene.scn, worldmap.bin}
final class SessionStore {
  let id: String
  let dir: URL
  let imagesDir: URL

  static func scansRoot() -> URL {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    return docs.appendingPathComponent("scans", isDirectory: true)
  }

  init(id: String) throws {
    self.id = id
    self.dir = SessionStore.scansRoot().appendingPathComponent(id, isDirectory: true)
    self.imagesDir = dir.appendingPathComponent("images", isDirectory: true)
    try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
  }

  var manifestURL: URL { dir.appendingPathComponent("manifest.json") }
  var metaURL: URL { dir.appendingPathComponent("meta.json") }
  var coverageURL: URL { dir.appendingPathComponent("coverage.json") }
  var coverageBinURL: URL { dir.appendingPathComponent("coverage.bin") }
  var sceneURL: URL { dir.appendingPathComponent("scene.scn") }
  var worldMapURL: URL { dir.appendingPathComponent("worldmap.bin") }

  func imageURL(index: Int) -> URL {
    imagesDir.appendingPathComponent(String(format: "frame_%05d.jpg", index))
  }

  func writeJSON(_ object: Any, to url: URL) {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]) else { return }
    try? data.write(to: url, options: .atomic)
  }

  func readJSON(from url: URL) -> Any? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONSerialization.jsonObject(with: data)
  }

  func writeMeta(_ meta: [String: Any]) {
    var merged = (readJSON(from: metaURL) as? [String: Any]) ?? [:]
    for (k, v) in meta { merged[k] = v }
    merged["id"] = id
    writeJSON(merged, to: metaURL)
  }

  // MARK: - Static session management

  static func listSessions() -> [[String: Any]] {
    let root = scansRoot()
    guard let items = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
      return []
    }
    var result: [[String: Any]] = []
    for item in items {
      let metaURL = item.appendingPathComponent("meta.json")
      guard let data = try? Data(contentsOf: metaURL),
            var meta = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
      meta["id"] = item.lastPathComponent
      result.append(meta)
    }
    result.sort { (a, b) in
      let ta = (a["createdAt"] as? Double) ?? 0
      let tb = (b["createdAt"] as? Double) ?? 0
      return ta > tb
    }
    return result
  }

  static func deleteSession(id: String) throws {
    let dir = scansRoot().appendingPathComponent(id, isDirectory: true)
    try FileManager.default.removeItem(at: dir)
  }

  /// Zips the images folder of a session using the NSFileCoordinator forUploading trick.
  static func exportZip(id: String, completion: @escaping (Result<URL, Error>) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
      let imagesDir = scansRoot().appendingPathComponent(id, isDirectory: true)
        .appendingPathComponent("images", isDirectory: true)
      guard FileManager.default.fileExists(atPath: imagesDir.path) else {
        completion(.failure(NSError(domain: "GaussianScan", code: 404, userInfo: [NSLocalizedDescriptionKey: "Brak zdjęć dla sesji \(id)"])))
        return
      }
      let coordinator = NSFileCoordinator()
      var coordError: NSError?
      var resultURL: URL?
      var copyError: Error?
      coordinator.coordinate(readingItemAt: imagesDir, options: [.forUploading], error: &coordError) { zippedURL in
        do {
          let exportsDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("exports", isDirectory: true)
          try FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)
          let dest = exportsDir.appendingPathComponent("skan_\(id).zip")
          if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
          }
          try FileManager.default.copyItem(at: zippedURL, to: dest)
          resultURL = dest
        } catch {
          copyError = error
        }
      }
      if let url = resultURL {
        completion(.success(url))
      } else {
        completion(.failure(copyError ?? coordError ?? NSError(domain: "GaussianScan", code: 500, userInfo: [NSLocalizedDescriptionKey: "Eksport nie powiódł się"])))
      }
    }
  }
}
