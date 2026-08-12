// MyScript iink 수식 인식 래퍼 (오프스크린 배치 인식).
//
// Flutter 필기 캔버스(PencilInputPad)의 획 좌표를 그대로 받아
// iink Math Recognizer 에 pointer events 로 재생하고, 결과를 LaTeX 로
// 돌려준다. iink 의 EditorView(네이티브 UI)는 쓰지 않는다.
//
// 인증서(MyCertificate.c)가 플레이스홀더(length 0)면 엔진을 만들지 않고
// isAvailable=false 를 돌려준다. 호출부(Flutter)는 이때 기존 ML Kit
// 경로를 그대로 사용한다.

import Foundation
import UIKit

@objc public final class MyScriptMathEngine: NSObject {

  @objc public static let shared = MyScriptMathEngine()

  /// 진단용 상태 메시지 (벤치마크 화면에서 표시).
  @objc public private(set) var statusMessage: String = "not_initialized"

  private var engine: IINKEngine?
  private var initialized = false
  private let lock = NSLock()

  /// 인식 요청을 직렬화하는 전용 큐. waitForIdle 이 블로킹이므로
  /// 메인 스레드에서 부르면 안 된다.
  private let queue = DispatchQueue(label: "myscript-math-recognize")

  private override init() {
    super.init()
  }

  @objc public var isAvailable: Bool {
    prepare() != nil
  }

  /// iink 네이티브 에디터(캔버스)용 공유 엔진. 같은 모듈의
  /// MyScriptEditorHost 가 사용한다.
  var editorEngine: IINKEngine? {
    prepare()
  }

  /// 엔진 lazy 초기화. 실패 사유는 statusMessage 에 남는다.
  private func prepare() -> IINKEngine? {
    lock.lock()
    defer { lock.unlock() }
    if initialized { return engine }
    initialized = true

    guard myCertificate.length > 0, myCertificate.bytes != nil else {
      statusMessage = "certificate_missing"
      return nil
    }
    let certificate = Data(bytes: myCertificate.bytes, count: myCertificate.length)
    guard let created = IINKEngine(certificate: certificate) else {
      statusMessage = "invalid_certificate"
      return nil
    }

    guard let confDir = Self.recognitionConfDirectory() else {
      statusMessage = "recognition_assets_missing"
      return nil
    }
    do {
      // Recognizer 계열과 Editor 계열이 서로 다른 키를 읽으므로 둘 다 설정.
      try created.configuration.set(stringArray: [confDir],
                                    forKey: "recognizer.configuration-manager.search-path")
      try created.configuration.set(stringArray: [confDir],
                                    forKey: "configuration-manager.search-path")
      try created.configuration.set(string: NSTemporaryDirectory(),
                                    forKey: "content-package.temp-folder")
    } catch {
      statusMessage = "configuration_failed: \(error.localizedDescription)"
      return nil
    }

    engine = created
    statusMessage = "ready"
    return created
  }

  /// math2.conf 가 들어 있는 recognition-assets/conf 디렉터리를 찾는다.
  /// CocoaPods 리소스는 프레임워크 번들에 복사되지만, 통합 방식에 따라
  /// 메인 번들에 들어갈 수도 있어 둘 다 확인한다.
  private static func recognitionConfDirectory() -> String? {
    let candidates = [
      Bundle(for: MyScriptMathEngine.self).bundlePath.appending("/recognition-assets/conf"),
      Bundle.main.bundlePath.appending("/recognition-assets/conf"),
    ]
    for path in candidates
    where FileManager.default.fileExists(atPath: path.appending("/math2.conf")) {
      return path
    }
    return nil
  }

  /// math2.conf 가 참조하는 기본 수식 인식 리소스 경로.
  private static func mathRecognitionResourcePath() -> String? {
    guard let confDir = recognitionConfDirectory() else { return nil }
    let path = URL(fileURLWithPath: confDir)
      .deletingLastPathComponent()
      .appendingPathComponent("resources/math/math-sr.res")
      .path
    return FileManager.default.fileExists(atPath: path) ? path : nil
  }

  /// iink 4.5 실물 리소스가 지원하는 자산 타입·기호·규칙 목록을 반환한다.
  ///
  /// Math Subset Knowledge의 타입 문자열과 left-fence 규칙 이름은 SDK 버전에
  /// 종속적이므로 추측하지 않고 실기기에서 이 값을 먼저 확인한다.
  @objc public func dumpRecognitionAssets() -> String {
    guard let engine = prepare() else { return "status=\(statusMessage)" }
    guard let builder = engine.createRecognitionAssetsBuilder() else {
      return "error=builder_unavailable"
    }
    guard let resourcePath = Self.mathRecognitionResourcePath() else {
      return "error=math_resource_missing"
    }
    do {
      let symbols = try builder.getSupportedSymbols(resourcePath: resourcePath)
      let types = builder.supportedRecognitionAssetsTypes.joined(separator: "\n")
      return """
      resource=\(resourcePath)
      types:
      \(types)
      symbols-and-rules:
      \(symbols)
      """
    } catch {
      return "error=dump_failed: \(error.localizedDescription)"
    }
  }

  /// 획 배열을 iink Math Recognizer 로 인식해 LaTeX 문자열을 돌려준다.
  ///
  /// - strokes: [{"x": [Double], "y": [Double], "t": [Int(ms)]}]
  ///   좌표는 Flutter 논리 픽셀(포인트) 기준.
  /// - completion: LaTeX 결과 또는 nil(실패). 별도 큐에서 호출된다.
  @objc public func recognizeLatex(
    strokes: [[String: Any]],
    completion: @escaping (String?, String?) -> Void
  ) {
    queue.async {
      guard let engine = self.prepare() else {
        completion(nil, self.statusMessage)
        return
      }
      do {
        let latex = try self.runRecognition(engine: engine, strokes: strokes)
        completion(latex, nil)
      } catch {
        completion(nil, "recognize_failed: \(error.localizedDescription)")
      }
    }
  }

  private func runRecognition(
    engine: IINKEngine,
    strokes: [[String: Any]]
  ) throws -> String? {
    // 좌표(논리 포인트) → mm 변환 계수. iPad 는 132pt/inch.
    let pointsPerInch: Float =
      UIDevice.current.userInterfaceIdiom == .pad ? 132.0 : 163.0
    let scale = 25.4 / pointsPerInch

    let recognizer = try engine.createRecognizer(
      scaleX: scale, scaleY: scale, type: "Math")

    var events: [IINKPointerEvent] = []
    events.reserveCapacity(strokes.reduce(0) { $0 + (($1["x"] as? [Any])?.count ?? 0) })
    for stroke in strokes {
      let xs = Self.doubleList(stroke["x"])
      let ys = Self.doubleList(stroke["y"])
      let ts = Self.intList(stroke["t"])
      let count = min(xs.count, ys.count)
      guard count > 0 else { continue }
      for i in 0..<count {
        let type: IINKPointerEventType =
          i == 0 ? .down : (i == count - 1 ? .up : .move)
        // IINKPointerEventMake 는 tilt/orientation 을 "정보 없음"으로 채운다.
        events.append(IINKPointerEventMake(
          type,
          CGPoint(x: xs[i], y: ys[i]),
          Int64(i < ts.count ? ts[i] : 0),
          0,
          .pen,
          0))
      }
      // 단일 점 획: down 이벤트만 생기므로 같은 위치에 up 을 보강한다.
      if count == 1, var upEvent = events.last {
        upEvent.eventType = .up
        upEvent.t += 1
        events.append(upEvent)
      }
    }
    guard !events.isEmpty else { return nil }

    try events.withUnsafeMutableBufferPointer { buffer in
      try recognizer.pointerEvents(buffer.baseAddress!, count: buffer.count)
    }
    recognizer.waitForIdle()

    let latex = try recognizer.result(mimeType: .laTeX)
    let trimmed = latex.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func doubleList(_ value: Any?) -> [Double] {
    guard let list = value as? [Any] else { return [] }
    return list.compactMap { ($0 as? NSNumber)?.doubleValue }
  }

  private static func intList(_ value: Any?) -> [Int] {
    guard let list = value as? [Any] else { return [] }
    return list.compactMap { ($0 as? NSNumber)?.intValue }
  }
}
