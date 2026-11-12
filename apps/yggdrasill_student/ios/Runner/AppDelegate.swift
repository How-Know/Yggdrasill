import Flutter
import UIKit
import myscript_math

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    registerMyScriptMathChannel(with: engineBridge.pluginRegistry)
    registerMyScriptEditorView(with: engineBridge.pluginRegistry)
    registerApplePencilUndo(with: engineBridge.pluginRegistry)
  }

  /// MyScript iink 네이티브 캔버스 플랫폼뷰 등록.
  private func registerMyScriptEditorView(with registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "MyScriptEditorView") else {
      return
    }
    registrar.register(
      MyScriptEditorViewFactory(messenger: registrar.messenger()),
      withId: "myscript_editor_view")
  }

  /// MyScript iink 수식 인식 브리지 채널.
  /// - isAvailable: { available: Bool, status: String }
  /// - recognize:   { strokes: [{x:[Double], y:[Double], t:[Int]}] } -> { latex: String? }
  private func registerMyScriptMathChannel(with registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "MyScriptMathChannel") else {
      return
    }
    let channel = FlutterMethodChannel(
      name: "yggdrasill.student/myscript_math",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "isAvailable":
        // isAvailable 이 엔진 lazy 초기화를 하므로 메인 스레드를 막지 않는다.
        DispatchQueue.global(qos: .userInitiated).async {
          let available = MyScriptMathEngine.shared.isAvailable
          let status = MyScriptMathEngine.shared.statusMessage
          DispatchQueue.main.async {
            result(["available": available, "status": status])
          }
        }
      case "recognize":
        guard
          let args = call.arguments as? [String: Any],
          let strokes = args["strokes"] as? [[String: Any]]
        else {
          result(FlutterError(code: "bad_args", message: "strokes required", details: nil))
          return
        }
        MyScriptMathEngine.shared.recognizeLatex(strokes: strokes) { latex, error in
          DispatchQueue.main.async {
            // 빈 문자열은 Dart 쪽에서 "인식 실패(null)"로 처리된다.
            var payload: [String: Any] = ["latex": latex ?? ""]
            if let error { payload["error"] = error }
            result(payload)
          }
        }
      case "dumpRecognitionAssets":
        DispatchQueue.global(qos: .utility).async {
          let dump = MyScriptMathEngine.shared.dumpRecognitionAssets()
          DispatchQueue.main.async {
            result(["dump": dump])
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// 애플 펜슬 프로를 쥐면 나오는 시스템 실행 취소 슬라이더에 필기 획을 올린다.
  /// 옆면을 두 번 두드리면 문제 풀기 하단의 한 단계 지우기와 같게 알린다.
  /// 쥐는 동작은 받지 않아 시스템 슬라이더가 그대로 나온다.
  private func registerApplePencilUndo(with registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "ApplePencilUndo") else {
      return
    }
    ApplePencilUndoBridge.shared.bind(
      messenger: registrar.messenger()
    )
  }
}

/// 필기 획 하나를 NSUndoManager 한 단계로 두고, 두 번 두드리면 지우기를 알린다.
/// 쥐는 동작(squeeze) 델리게이트는 구현하지 않는다. 구현하면 시스템 실행 취소 슬라이더가 사라진다.
final class ApplePencilUndoBridge: NSObject, UIPencilInteractionDelegate {
  static let shared = ApplePencilUndoBridge()

  private var channel: FlutterMethodChannel?
  private var pencilInteraction: UIPencilInteraction?
  private var attachAttempts = 0
  private var attachRetryScheduled = false
  private var suppressCallback = false
  private var didHandle = false
  private var lastEraseTapUptime: TimeInterval = 0

  private override init() {
    super.init()
  }

  func bind(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "yggdrasill.student/apple_pencil_undo",
      binaryMessenger: messenger
    )
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(false)
        return
      }
      switch call.method {
      case "push":
        result(self.push())
      case "noteLocalUndo":
        result(self.noteLocalUndo())
      case "reset":
        self.reset()
        result(nil)
      case "attach":
        self.attachPencilInteraction()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    DispatchQueue.main.async { [weak self] in
      self?.attachPencilInteraction()
    }
  }

  private func attachPencilInteraction() {
    guard pencilInteraction == nil else { return }
    guard let view = flutterView() else {
      guard !attachRetryScheduled, attachAttempts < 20 else { return }
      attachRetryScheduled = true
      attachAttempts += 1
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
        guard let self else { return }
        self.attachRetryScheduled = false
        self.attachPencilInteraction()
      }
      return
    }
    let interaction = UIPencilInteraction()
    interaction.delegate = self
    view.addInteraction(interaction)
    pencilInteraction = interaction
  }

  private func flutterView() -> UIView? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    for scene in scenes {
      for window in scene.windows {
        if let view = flutterView(in: window.rootViewController) {
          return view
        }
      }
    }
    return nil
  }

  private func flutterView(in viewController: UIViewController?) -> UIView? {
    guard let viewController else { return nil }
    if viewController is FlutterViewController {
      return viewController.viewIfLoaded
    }
    for child in viewController.children {
      if let view = flutterView(in: child) { return view }
    }
    return flutterView(in: viewController.presentedViewController)
  }

  func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
    deliverEraseTap()
  }

  /// iPadOS 17.5부터 두 번 두드림은 이 메서드로만 온다.
  @available(iOS 17.5, *)
  func pencilInteraction(
    _ interaction: UIPencilInteraction,
    didReceiveTap tap: UIPencilInteraction.Tap
  ) {
    deliverEraseTap()
  }

  /// 같은 두드림이 옛 콜백과 새 콜백으로 겹쳐 들어와도 지우기는 한 번만 보낸다.
  private func deliverEraseTap() {
    guard tapPrefersToolSwitch() else { return }
    let now = ProcessInfo.processInfo.systemUptime
    if now - lastEraseTapUptime < 0.25 { return }
    lastEraseTapUptime = now
    DispatchQueue.main.async { [weak self] in
      self?.channel?.invokeMethod("erase", arguments: nil)
    }
  }

  /// 설정이 ‘현재 도구와 지우개’ 또는 ‘마지막 도구’일 때만 하단 지우기와 같게 한다.
  private func tapPrefersToolSwitch() -> Bool {
    if #available(iOS 17.5, *) {
      return modernTapPrefersToolSwitch()
    }
    return legacyTapPrefersToolSwitch()
  }

  @available(iOS 17.5, *)
  private func modernTapPrefersToolSwitch() -> Bool {
    let action: UIPencilInteraction.PreferredAction =
      UIPencilInteraction.preferredTapAction
    switch action {
    case .switchEraser, .switchPrevious:
      return true
    default:
      return false
    }
  }

  @available(iOS, introduced: 12.1, deprecated: 17.5)
  private func legacyTapPrefersToolSwitch() -> Bool {
    let action: UIPencilPreferredAction = UIPencilInteraction.preferredTapAction
    switch action {
    case .switchEraser, .switchPrevious:
      return true
    default:
      return false
    }
  }

  private func currentUndoManager() -> UndoManager? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    for scene in scenes {
      let windows = scene.windows.sorted { lhs, rhs in
        lhs.isKeyWindow && !rhs.isKeyWindow
      }
      for window in windows {
        if let manager = undoManager(in: window.rootViewController) {
          return manager
        }
      }
    }
    return nil
  }

  private func undoManager(in viewController: UIViewController?) -> UndoManager? {
    guard let viewController else { return nil }
    if viewController is FlutterViewController {
      return viewController.undoManager
    }
    for child in viewController.children {
      if let manager = undoManager(in: child) { return manager }
    }
    return undoManager(in: viewController.presentedViewController)
  }

  private func push() -> Bool {
    attachPencilInteraction()
    guard let undoManager = currentUndoManager() else { return false }
    let grouped = undoManager.groupsByEvent
    undoManager.groupsByEvent = false
    undoManager.beginUndoGrouping()
    undoManager.registerUndo(withTarget: self) { target in
      target.handleUndo()
    }
    undoManager.setActionName("필기")
    undoManager.endUndoGrouping()
    undoManager.groupsByEvent = grouped
    return true
  }

  /// 화면이 이미 획을 뺐을 때 시스템 스택의 맨 위도 같은 단계면 내린다.
  private func noteLocalUndo() -> Bool {
    guard let undoManager = currentUndoManager(), undoManager.canUndo else {
      return false
    }
    didHandle = false
    suppressCallback = true
    undoManager.undo()
    suppressCallback = false
    return didHandle
  }

  private func reset() {
    currentUndoManager()?.removeAllActions(withTarget: self)
  }

  private func handleUndo() {
    didHandle = true
    currentUndoManager()?.registerUndo(withTarget: self) { target in
      target.handleRedo()
    }
    notify(method: "undo")
  }

  private func handleRedo() {
    didHandle = true
    currentUndoManager()?.registerUndo(withTarget: self) { target in
      target.handleUndo()
    }
    notify(method: "redo")
  }

  private func notify(method: String) {
    let shouldNotify = !suppressCallback
    guard shouldNotify, let channel else { return }
    DispatchQueue.main.async {
      channel.invokeMethod(method, arguments: nil)
    }
  }
}
