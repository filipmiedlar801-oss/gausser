import ExpoModulesCore
import ARKit

public class GaussianScanModule: Module {
  public func definition() -> ModuleDefinition {
    Name("GaussianScan")

    Function("hasLiDAR") { () -> Bool in
      ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }

    AsyncFunction("listSessions") { () -> [[String: Any]] in
      SessionStore.listSessions()
    }

    AsyncFunction("deleteSession") { (id: String) in
      try SessionStore.deleteSession(id: id)
    }

    AsyncFunction("exportZip") { (id: String, promise: Promise) in
      SessionStore.exportZip(id: id) { result in
        switch result {
        case .success(let url):
          promise.resolve(url.absoluteString)
        case .failure(let error):
          promise.reject("EXPORT_FAILED", error.localizedDescription)
        }
      }
    }

    View(ScanView.self) {
      Events("onMetrics", "onGuidance", "onCoverage", "onKeyframe", "onSessionState")

      Prop("mode") { (view: ScanView, mode: String) in
        view.pendingMode = mode
      }

      Prop("sessionId") { (view: ScanView, sessionId: String?) in
        view.pendingSessionId = sessionId
      }

      OnViewDidUpdateProps { (view: ScanView) in
        view.applyProps()
      }

      AsyncFunction("startScan") { (view: ScanView, sessionId: String, resume: Bool) in
        try view.controller.startScan(sessionId: sessionId, resume: resume)
      }.runOnQueue(.main)

      AsyncFunction("stopScan") { (view: ScanView, promise: Promise) in
        view.controller.stopScan { result in
          switch result {
          case .success(let summary):
            promise.resolve(summary)
          case .failure(let error):
            promise.reject("STOP_FAILED", error.localizedDescription)
          }
        }
      }.runOnQueue(.main)

      AsyncFunction("lockExposure") { (view: ScanView) in
        try view.controller.lockExposure()
      }.runOnQueue(.main)

      AsyncFunction("unlockExposure") { (view: ScanView) in
        try view.controller.unlockExposure()
      }.runOnQueue(.main)

      AsyncFunction("setWaypoint") { (view: ScanView, x: Double, y: Double, z: Double) in
        view.controller.setWaypoint(x: Float(x), y: Float(y), z: Float(z))
      }.runOnQueue(.main)

      AsyncFunction("clearWaypoint") { (view: ScanView) in
        view.controller.clearWaypoint()
      }.runOnQueue(.main)
    }
  }
}
