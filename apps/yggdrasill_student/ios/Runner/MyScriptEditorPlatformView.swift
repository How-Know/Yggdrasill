// MyScript iink 네이티브 캔버스 Flutter 플랫폼뷰.
//
// Dart 의 UiKitView(viewType: "myscript_editor_view") 로 표시되고,
// 뷰별 메서드채널 "yggdrasill.student/myscript_editor_<viewId>" 로
// clear / undo / redo / convert / exportLatex / status 를 제공한다.

import Flutter
import UIKit
import myscript_math

final class MyScriptEditorViewFactory: NSObject, FlutterPlatformViewFactory {

  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    MyScriptEditorPlatformView(
      frame: frame, viewId: viewId, messenger: messenger)
  }
}

final class MyScriptEditorPlatformView: NSObject, FlutterPlatformView {

  private let host = MyScriptEditorHost()
  private let channel: FlutterMethodChannel
  private let container: UIView

  init(frame: CGRect, viewId: Int64, messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "yggdrasill.student/myscript_editor_\(viewId)",
      binaryMessenger: messenger)
    container = UIView(frame: frame)
    super.init()

    let editorView = host.view
    editorView.frame = container.bounds
    editorView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    container.addSubview(editorView)

    let host = self.host
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "clear":
        host.clear()
        result(nil)
      case "undo":
        host.undo()
        result(nil)
      case "redo":
        host.redo()
        result(nil)
      case "convert":
        // convert 는 waitForIdle 성격이 있어 메인 스레드를 오래 잡지 않게 한다.
        DispatchQueue.global(qos: .userInitiated).async {
          let error = host.convert()
          DispatchQueue.main.async { result(error) }
        }
      case "exportLatex":
        DispatchQueue.global(qos: .userInitiated).async {
          let latex = host.exportLatex()
          DispatchQueue.main.async { result(latex) }
        }
      case "status":
        result(host.statusMessage)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  func view() -> UIView {
    container
  }

  deinit {
    channel.setMethodCallHandler(nil)
    host.dispose()
  }
}
