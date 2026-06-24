import Foundation
import Combine
import WatchConnectivity

/// iPhone이 내려준 오늘 출결 타깃 1건.
struct WatchTarget: Identifiable {
    let setId: String
    let studentId: String
    let name: String
    let classDateTime: String
    let classEndTime: String
    let className: String
    let sessionTypeId: String?
    /// "waiting" | "attended" | "leaved"
    let status: String

    var id: String { setId }

    var statusLabel: String {
        switch status {
        case "attended": return "등원"
        case "leaved": return "하원"
        default: return "대기"
        }
    }

    init?(dict: [String: Any]) {
        guard
            let setId = dict["setId"] as? String,
            let studentId = dict["studentId"] as? String,
            let classDateTime = dict["classDateTime"] as? String
        else { return nil }
        self.setId = setId
        self.studentId = studentId
        self.name = (dict["name"] as? String) ?? "학생"
        self.classDateTime = classDateTime
        self.classEndTime = (dict["classEndTime"] as? String) ?? classDateTime
        self.className = (dict["className"] as? String) ?? "수업"
        self.sessionTypeId = dict["sessionTypeId"] as? String
        self.status = (dict["status"] as? String) ?? "waiting"
    }
}

final class WatchConnectivityModel: NSObject, ObservableObject {
    @Published private(set) var statusText = "iPhone 연결 대기 중"
    @Published private(set) var targets: [WatchTarget] = []
    /// 사용자에게 잠깐 보여줄 액션 결과 메시지.
    @Published var toast: String?

    override init() {
        super.init()

        guard WCSession.isSupported() else {
            statusText = "WatchConnectivity 미지원"
            return
        }

        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    var isReachable: Bool { WCSession.default.isReachable }

    /// iPhone에 최신 출결 스냅샷을 다시 요청한다(도달 가능할 때만).
    func requestSnapshot() {
        guard WCSession.default.activationState == .activated,
              WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(["type": "requestSnapshot"], replyHandler: nil)
    }

    /// 등원/하원 이벤트를 iPhone으로 전송한다.
    /// 도달 가능하면 즉시 sendMessage, 아니면 transferUserInfo로 큐잉(백그라운드 보장 전달).
    func sendAttendance(action: String, target: WatchTarget) {
        guard WCSession.default.activationState == .activated else {
            statusText = "세션 활성화 대기 중"
            return
        }

        let payload: [String: Any] = [
            "type": "attendance",
            "action": action,
            "setId": target.setId,
            "studentId": target.studentId,
            "classDateTime": target.classDateTime,
            "classEndTime": target.classEndTime,
            "className": target.className,
            "sessionTypeId": target.sessionTypeId as Any,
            "clientEventId": UUID().uuidString,
        ]

        if WCSession.default.isReachable {
            WCSession.default.sendMessage(payload, replyHandler: { [weak self] reply in
                DispatchQueue.main.async {
                    let ok = (reply["ok"] as? Bool) ?? false
                    self?.toast = (reply["message"] as? String) ?? (ok ? "전송됨" : "처리 실패")
                }
            }, errorHandler: { [weak self] _ in
                // 전송 직전 도달 불가로 바뀐 경우: 큐 전달로 폴백.
                WCSession.default.transferUserInfo(payload)
                DispatchQueue.main.async {
                    self?.toast = "iPhone에 큐로 전달됨"
                }
            })
        } else {
            WCSession.default.transferUserInfo(payload)
            toast = "iPhone에 큐로 전달됨"
        }
    }

    private func applyContext(_ context: [String: Any]) {
        guard (context["type"] as? String) == "todayTargets" else { return }
        let rawItems = (context["items"] as? [[String: Any]]) ?? []
        let parsed = rawItems.compactMap(WatchTarget.init(dict:))
        DispatchQueue.main.async {
            self.targets = parsed
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
                self.statusText = activationState == .activated ? "iPhone 연결됨" : "연결 대기 중"
            }
        }
        // 활성화 직후 마지막 스냅샷을 즉시 반영.
        applyContext(session.receivedApplicationContext)
        requestSnapshot()
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        applyContext(applicationContext)
    }
}
