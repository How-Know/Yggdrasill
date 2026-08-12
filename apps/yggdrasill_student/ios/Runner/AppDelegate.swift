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
}
