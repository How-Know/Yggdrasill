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
    let arrivalTime: String?
    let departureTime: String?
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

    /// 상태에 맞춰 보여줄 시간 문자열(HH:mm).
    /// 대기=등원예정시간, 등원=등원시간, 하원=하원시간.
    var timeLabel: String? {
        switch status {
        case "attended":
            return WatchTarget.formatTime(arrivalTime)
        case "leaved":
            return WatchTarget.formatTime(departureTime)
        default:
            if let scheduled = WatchTarget.formatTime(classDateTime) {
                return "예정 \(scheduled)"
            }
            return nil
        }
    }

    private static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoParserNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // Dart의 DateTime.toIso8601String()은 로컬 시각일 때 타임존 오프셋이 없는
    // "2026-06-29T17:00:00.000" 형태를 만든다. ISO8601DateFormatter는 타임존을
    // 요구하므로, 오프셋이 없는 형식은 아래 로컬 DateFormatter로 파싱한다.
    private static let localParsers: [DateFormatter] = {
        let patterns = [
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
            "yyyy-MM-dd'T'HH:mm:ss.SSS",
            "yyyy-MM-dd'T'HH:mm:ss",
        ]
        return patterns.map { pattern in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone.current
            f.dateFormat = pattern
            return f
        }
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "HH:mm"
        return f
    }()

    static func formatTime(_ iso: String?) -> String? {
        guard let iso = iso, !iso.isEmpty else { return nil }
        var date = isoParser.date(from: iso) ?? isoParserNoFraction.date(from: iso)
        if date == nil {
            for parser in localParsers {
                if let parsed = parser.date(from: iso) {
                    date = parsed
                    break
                }
            }
        }
        guard let date else { return nil }
        return timeFormatter.string(from: date)
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
        self.arrivalTime = dict["arrivalTime"] as? String
        self.departureTime = dict["departureTime"] as? String
        self.status = (dict["status"] as? String) ?? "waiting"
    }

    func asDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "setId": setId,
            "studentId": studentId,
            "name": name,
            "classDateTime": classDateTime,
            "classEndTime": classEndTime,
            "className": className,
            "status": status,
        ]
        if let sessionTypeId {
            dict["sessionTypeId"] = sessionTypeId
        }
        if let arrivalTime {
            dict["arrivalTime"] = arrivalTime
        }
        if let departureTime {
            dict["departureTime"] = departureTime
        }
        return dict
    }
}

final class WatchConnectivityModel: NSObject, ObservableObject {
    private static let cachedTargetsKey = "yggdrasill.watch.cachedTodayTargets"
    private static let cachedTargetsDateKey = "yggdrasill.watch.cachedTodayTargetsDate"

    @Published private(set) var statusText = "iPhone 연결 대기 중"
    @Published private(set) var targets: [WatchTarget] = []
    /// 사용자에게 잠깐 보여줄 액션 결과 메시지.
    @Published var toast: String?

    override init() {
        super.init()
        loadCachedTargets()

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
              WCSession.default.isReachable else {
            toast = targets.isEmpty ? "iPhone 앱을 먼저 열어주세요" : "최근 목록 표시 중"
            return
        }
        WCSession.default.sendMessage(["type": "requestSnapshot"], replyHandler: { [weak self] reply in
            DispatchQueue.main.async {
                if (reply["type"] as? String) == "todayTargets" {
                    self?.applyContext(reply)
                }
                self?.toast = (reply["message"] as? String) ?? "새로고침 요청됨"
            }
        }, errorHandler: { [weak self] error in
            DispatchQueue.main.async {
                self?.toast = "새로고침 실패: \(error.localizedDescription)"
            }
        })
    }

    /// 등원/하원 이벤트를 iPhone으로 전송한다.
    /// 도달 가능하면 즉시 sendMessage, 아니면 transferUserInfo로 큐잉(백그라운드 보장 전달).
    func sendAttendance(action: String, target: WatchTarget) {
        guard WCSession.default.activationState == .activated else {
            statusText = "세션 활성화 대기 중"
            return
        }

        // WCSession은 NSNull을 전송하지 못하므로 nil 값은 payload에 넣지 않는다.
        var payload: [String: Any] = [
            "type": "attendance",
            "action": action,
            "setId": target.setId,
            "studentId": target.studentId,
            "classDateTime": target.classDateTime,
            "classEndTime": target.classEndTime,
            "className": target.className,
            "clientEventId": UUID().uuidString,
        ]
        if let sessionTypeId = target.sessionTypeId {
            payload["sessionTypeId"] = sessionTypeId
        }

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
                    self?.applyQueuedAttendance(action: action, target: target)
                    self?.toast = "iPhone에 큐로 전달됨"
                }
            })
        } else {
            WCSession.default.transferUserInfo(payload)
            applyQueuedAttendance(action: action, target: target)
            toast = "iPhone에 큐로 전달됨"
        }
    }

    private func applyContext(_ context: [String: Any]) {
        guard (context["type"] as? String) == "todayTargets" else { return }
        let rawItems = (context["items"] as? [[String: Any]]) ?? []
        let parsed = rawItems.compactMap(WatchTarget.init(dict:))
        DispatchQueue.main.async {
            self.targets = parsed
            self.cacheTargets(rawItems, snapshotDate: context["date"] as? String)
        }
    }

    private func applyQueuedAttendance(action: String, target: WatchTarget) {
        let now = Self.isoString(Date())
        let updated = targets.map { item -> WatchTarget in
            guard item.setId == target.setId else { return item }
            var dict = item.asDictionary()
            switch action {
            case "arrival":
                dict["status"] = "attended"
                dict["arrivalTime"] = now
            case "departure":
                dict["status"] = "leaved"
                dict["departureTime"] = now
                if dict["arrivalTime"] == nil {
                    dict["arrivalTime"] = now
                }
            default:
                break
            }
            return WatchTarget(dict: dict) ?? item
        }
        targets = updated
        cacheTargets(updated.map { $0.asDictionary() }, snapshotDate: now)
    }

    private func loadCachedTargets() {
        guard let data = UserDefaults.standard.data(forKey: Self.cachedTargetsKey),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return }
        let parsed = raw.compactMap(WatchTarget.init(dict:))
        guard !parsed.isEmpty else { return }
        targets = parsed
        if let date = UserDefaults.standard.string(forKey: Self.cachedTargetsDateKey),
           let time = WatchTarget.formatTime(date) {
            statusText = "최근 동기화 \(time)"
        } else {
            statusText = "최근 목록 표시 중"
        }
    }

    private func cacheTargets(_ rawItems: [[String: Any]], snapshotDate: String?) {
        guard JSONSerialization.isValidJSONObject(rawItems),
              let data = try? JSONSerialization.data(withJSONObject: rawItems)
        else { return }
        UserDefaults.standard.set(data, forKey: Self.cachedTargetsKey)
        if let snapshotDate {
            UserDefaults.standard.set(snapshotDate, forKey: Self.cachedTargetsDateKey)
        }
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
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
