import Flutter
import UIKit
import WatchConnectivity

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, WCSessionDelegate {
  private var watchChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)

    if WCSession.isSupported() {
      WCSession.default.delegate = self
      WCSession.default.activate()
    }

    setupWatchChannel()

    return result
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }

  // MARK: - MethodChannel 브리지

  private func setupWatchChannel() {
    if watchChannel != nil {
      return
    }
    guard let controller = findFlutterViewController() else {
      // FlutterViewController가 아직 준비되지 않았으면 다음 런루프에서 재시도한다.
      DispatchQueue.main.async { [weak self] in
        self?.setupWatchChannel()
      }
      return
    }
    let channel = FlutterMethodChannel(
      name: "yggdrasill/watch",
      binaryMessenger: controller.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "sendSnapshot":
        self?.handleSendSnapshot(call.arguments, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    watchChannel = channel
  }

  private func findFlutterViewController() -> FlutterViewController? {
    if let controller = window?.rootViewController as? FlutterViewController {
      return controller
    }
    for scene in UIApplication.shared.connectedScenes {
      guard let windowScene = scene as? UIWindowScene else {
        continue
      }
      for window in windowScene.windows {
        if let controller = window.rootViewController as? FlutterViewController {
          return controller
        }
        if let controller = window.rootViewController?.children
          .compactMap({ $0 as? FlutterViewController })
          .first {
          return controller
        }
      }
    }
    return nil
  }

  /// Dart -> 네이티브: 오늘 출결 타깃 스냅샷을 최신 1건으로 워치에 반영한다.
  private func handleSendSnapshot(_ arguments: Any?, result: FlutterResult) {
    guard WCSession.isSupported() else {
      result(FlutterError(code: "unsupported", message: "WatchConnectivity 미지원", details: nil))
      return
    }
    guard let payload = arguments as? [String: Any] else {
      result(FlutterError(code: "bad_args", message: "스냅샷 형식 오류", details: nil))
      return
    }
    do {
      try WCSession.default.updateApplicationContext(payload)
      result(nil)
    } catch {
      result(FlutterError(code: "context_failed", message: error.localizedDescription, details: nil))
    }
  }

  /// Watch -> 네이티브 -> Dart: 워치 이벤트를 Flutter로 포워딩하고, 가능하면 응답을 회신한다.
  private func forwardToFlutter(_ message: [String: Any], reply: (([String: Any]) -> Void)?) {
    DispatchQueue.main.async { [weak self] in
      self?.setupWatchChannel()
      guard let channel = self?.watchChannel else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
          self?.setupWatchChannel()
          guard let channel = self?.watchChannel else {
            reply?(["ok": false, "message": "브리지 미준비"])
            return
          }
          channel.invokeMethod("onWatchEvent", arguments: message) { res in
            if let map = res as? [String: Any] {
              reply?(map)
            } else {
              reply?(["ok": true])
            }
          }
        }
        return
      }
      channel.invokeMethod("onWatchEvent", arguments: message) { res in
        if let map = res as? [String: Any] {
          reply?(map)
        } else {
          reply?(["ok": true])
        }
      }
    }
  }

  // MARK: - WCSessionDelegate

  func session(
    _ session: WCSession,
    activationDidCompleteWith activationState: WCSessionActivationState,
    error: Error?
  ) {}

  func sessionDidBecomeInactive(_ session: WCSession) {}

  func sessionDidDeactivate(_ session: WCSession) {
    session.activate()
  }

  func session(
    _ session: WCSession,
    didReceiveMessage message: [String: Any],
    replyHandler: @escaping ([String: Any]) -> Void
  ) {
    forwardToFlutter(message, reply: replyHandler)
  }

  func session(
    _ session: WCSession,
    didReceiveUserInfo userInfo: [String: Any] = [:]
  ) {
    forwardToFlutter(userInfo, reply: nil)
  }
}
