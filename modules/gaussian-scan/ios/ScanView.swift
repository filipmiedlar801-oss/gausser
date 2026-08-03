import ExpoModulesCore
import ARKit
import SceneKit

class ScanView: ExpoView {
  let onMetrics = EventDispatcher()
  let onGuidance = EventDispatcher()
  let onCoverage = EventDispatcher()
  let onKeyframe = EventDispatcher()
  let onSessionState = EventDispatcher()

  let arView = ARSCNView(frame: .zero)
  lazy var controller = ScanController(view: self)

  var pendingMode: String = ""
  var pendingSessionId: String?
  private var appliedMode: String?

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    clipsToBounds = true
    arView.automaticallyUpdatesLighting = true
    arView.rendersContinuously = true
    addSubview(arView)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    arView.frame = bounds
  }

  func applyProps() {
    guard !pendingMode.isEmpty, appliedMode != pendingMode else { return }
    appliedMode = pendingMode
    switch pendingMode {
    case "wizard":
      controller.startWizard()
    case "scan":
      // The actual session starts when JS calls startScan(sessionId, resume).
      break
    case "review":
      if let id = pendingSessionId {
        controller.startReview(sessionId: id)
      }
    default:
      break
    }
  }

  override func willMove(toWindow newWindow: UIWindow?) {
    super.willMove(toWindow: newWindow)
    if newWindow == nil {
      controller.teardown()
    }
  }
}
