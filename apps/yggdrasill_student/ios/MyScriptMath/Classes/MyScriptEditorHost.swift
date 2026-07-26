// MyScript iink 네이티브 캔버스 호스트.
//
// iink 의 EditorViewController(레퍼런스 구현)를 Flutter 플랫폼뷰에서
// 쓸 수 있게 감싼다. Flutter 의존이 없어 pod 안에 두고, Runner 쪽
// 플랫폼뷰가 이 호스트의 view 와 액션 메서드만 사용한다.
//
// 파트 타입은 "Math" 고정 — 실시간 잉크 렌더링과 점진적 수식 인식,
// convert(잉크 → 조판 수식) 를 제공한다.

import Foundation
import UIKit

@objc public final class MyScriptEditorHost: NSObject {

  private var editorViewController: EditorViewController?
  private var editor: IINKEditor?
  private var package: IINKContentPackage?
  private var packagePath: String?

  /// 초기화 실패 사유 (성공 시 "ok").
  @objc public private(set) var statusMessage = "ok"

  @objc public private(set) lazy var view: UIView = makeView()

  private func makeView() -> UIView {
    guard let engine = MyScriptMathEngine.shared.editorEngine else {
      statusMessage = MyScriptMathEngine.shared.statusMessage
      let label = UILabel()
      label.text = "MyScript 사용 불가: \(statusMessage)"
      label.textAlignment = .center
      label.numberOfLines = 0
      return label
    }
    // forcePen: 손가락·펜슬 모두 잉크 입력으로 처리한다.
    // (auto 는 손가락을 스크롤 제스처로 돌려서 펜슬 없는 기기는 못 쓴다.)
    let viewModel = EditorViewModel(
      engine: engine, inputMode: .forcePen, editorDelegate: self)
    let vc = EditorViewController(viewModel: viewModel)
    editorViewController = vc
    let view: UIView = vc.view  // loadView 트리거 → didCreateEditor 호출됨
    openMathPart(engine: engine)
    return view
  }

  private func openMathPart(engine: IINKEngine) {
    let path = NSTemporaryDirectory()
      .appending("myscript_editor_\(UUID().uuidString).iink")
    do {
      let pkg = try engine.createPackage(
        path.decomposedStringWithCanonicalMapping)
      _ = try pkg.createPart(with: "Math")
      package = pkg
      packagePath = path
      try editor?.set(part: pkg.part(at: 0))
    } catch {
      statusMessage = "part_failed: \(error.localizedDescription)"
    }
  }

  // MARK: - Actions (Flutter 메서드채널에서 호출)

  @objc public func clear() {
    try? editor?.clear()
  }

  @objc public func undo() {
    editor?.undo()
  }

  @objc public func redo() {
    editor?.redo()
  }

  /// 잉크를 조판된 수식으로 변환. 실패 시 에러 메시지 반환.
  @objc public func convert() -> String? {
    guard let editor else { return statusMessage }
    do {
      let states = editor.supportedTargetConversionState(forSelection: nil)
      if let first = states.first {
        try editor.convert(selection: nil, targetState: first.value)
      }
      return nil
    } catch {
      return error.localizedDescription
    }
  }

  /// 현재 인식 결과를 LaTeX 문자열로 내보낸다.
  @objc public func exportLatex() -> String? {
    guard let editor else { return nil }
    editor.waitForIdle()
    let latex = try? editor.export(selection: nil, mimeType: .laTeX)
    let trimmed = latex?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (trimmed?.isEmpty ?? true) ? nil : trimmed
  }

  @objc public func dispose() {
    try? editor?.set(part: nil)
    editor = nil
    editorViewController = nil
    package = nil
    if let packagePath {
      try? FileManager.default.removeItem(atPath: packagePath)
    }
  }
}

extension MyScriptEditorHost: EditorDelegate {

  func didCreateEditor(editor: IINKEditor) {
    self.editor = editor
  }

  func partChanged(editor: IINKEditor) {}

  func contentChanged(editor: IINKEditor, blockIds: [String]) {}

  func onError(editor: IINKEditor, blockId: String, message: String) {
    statusMessage = message
  }
}
