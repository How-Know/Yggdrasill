import Foundation
import Combine
import WatchConnectivity

final class WatchConnectivityModel: NSObject, ObservableObject {
    @Published private(set) var statusText = "iPhone 연결 대기 중"

    override init() {
        super.init()

        guard WCSession.isSupported() else {
            statusText = "WatchConnectivity 미지원"
            return
        }

        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func sendPing() {
        guard WCSession.default.activationState == .activated else {
            statusText = "세션 활성화 대기 중"
            return
        }

        if WCSession.default.isReachable {
            WCSession.default.sendMessage(["type": "ping"], replyHandler: { [weak self] reply in
                DispatchQueue.main.async {
                    self?.statusText = reply["message"] as? String ?? "iPhone 응답 수신"
                }
            }, errorHandler: { [weak self] error in
                DispatchQueue.main.async {
                    self?.statusText = "전송 실패: \(error.localizedDescription)"
                }
            })
        } else {
            statusText = "iPhone 앱이 실행 중이지 않음"
        }
    }
}

extension WatchConnectivityModel: WCSessionDelegate {
    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        DispatchQueue.main.async {
            if let error {
                self.statusText = "활성화 실패: \(error.localizedDescription)"
            } else {
                self.statusText = activationState == .activated ? "iPhone 연결 준비 완료" : "연결 대기 중"
            }
        }
    }
}
