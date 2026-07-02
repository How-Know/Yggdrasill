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

struct WatchHomeworkItem: Identifiable {
    let assignmentId: String
    let homeworkItemId: String
    let studentId: String
    let assignmentCode: String
    let source: String
    let course: String
    let groupTitle: String
    let assignedDate: String
    let page: String
    let line1: String
    let line2: String
    let line3: String
    let title: String
    var progress: Int

    var id: String { assignmentId }
    var pageLabel: String {
        let trimmed = page.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed.lowercased().hasPrefix("p.") ? trimmed : "p. \(trimmed)"
    }

    init?(dict: [String: Any]) {
        guard
            let assignmentId = dict["assignmentId"] as? String,
            let homeworkItemId = dict["homeworkItemId"] as? String,
            let studentId = dict["studentId"] as? String
        else { return nil }
        self.assignmentId = assignmentId
        self.homeworkItemId = homeworkItemId
        self.studentId = studentId
        self.assignmentCode = (dict["assignmentCode"] as? String) ?? ""
        self.source = (dict["source"] as? String) ?? "교재"
        self.course = (dict["course"] as? String) ?? "과정"
        self.groupTitle = (dict["groupTitle"] as? String) ?? "그룹과제"
        self.assignedDate = (dict["assignedDate"] as? String) ?? ""
        self.page = (dict["page"] as? String) ?? ""
        self.line1 = (dict["line1"] as? String) ?? "교재 · 과정"
        self.line2 = (dict["line2"] as? String) ?? "그룹과제"
        self.line3 = (dict["line3"] as? String) ?? "날짜 · 페이지"
        self.title = (dict["title"] as? String) ?? "숙제"
        if let progress = dict["progress"] as? Int {
            self.progress = progress
        } else if let progress = dict["progress"] as? NSNumber {
            self.progress = progress.intValue
        } else {
            self.progress = 0
        }
    }
}

final class WatchConnectivityModel: NSObject, ObservableObject {
    private static let cachedTargetsKey = "yggdrasill.watch.cachedTodayTargets"
    private static let cachedTargetsDateKey = "yggdrasill.watch.cachedTodayTargetsDate"

    @Published private(set) var statusText = "iPhone 연결 대기 중"
    @Published private(set) var targets: [WatchTarget] = []
    @Published private(set) var homeworkItems: [WatchHomeworkItem] = []
    /// 사용자에게 잠깐 보여줄 액션 결과 메시지.
    @Published var toast: String?
    private var liveRefreshTimer: Timer?
    private let api = WatchAPIClient.shared

    /// iPhone 없이 서버와 직접 통신할 수 있는 상태인지.
    var isStandaloneReady: Bool { api.hasAuth }

    /// iPhone 앱이 실행 중이라 브리지(검증된 경로)를 쓸 수 있는지.
    /// 이때는 iPhone의 DataManager 로직을 그대로 태워야 데이터가 정확하다.
    private var iphoneReachable: Bool {
        WCSession.default.activationState == .activated && WCSession.default.isReachable
    }

    override init() {
        super.init()
        loadCachedTargets()

        guard WCSession.isSupported() else {
            statusText = "WatchConnectivity 미지원"
            return
        }

        WCSession.default.delegate = self
        WCSession.default.activate()
        startLiveRefresh()
    }

    var isReachable: Bool { WCSession.default.isReachable }

    /// 최신 출결 스냅샷을 요청한다.
    /// 단독 동작 토큰이 있으면 서버에서 직접 조회하고, 없으면 iPhone 브리지로 폴백한다.
    func requestSnapshot() {
        // iPhone이 켜져 있으면 검증된 브리지 경로를 우선 사용한다.
        if iphoneReachable {
            bridgeRequestSnapshot()
            return
        }
        if api.hasAuth {
            api.todayTargets { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case .success(let items):
                        self.applyContext([
                            "type": "todayTargets",
                            "items": items,
                            "date": Self.isoString(Date()),
                        ])
                        self.statusText = "서버 동기화됨"
                    case .failure:
                        self.bridgeRequestSnapshot()
                    }
                }
            }
            return
        }
        bridgeRequestSnapshot()
    }

    /// iPhone에 최신 출결 스냅샷을 다시 요청한다(도달 가능할 때만).
    private func bridgeRequestSnapshot() {
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

    func startLiveRefresh() {
        liveRefreshTimer?.invalidate()
        liveRefreshTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
            self?.requestSnapshot()
        }
    }

    func requestHomework(for target: WatchTarget) {
        if iphoneReachable {
            bridgeRequestHomework(for: target)
            return
        }
        if api.hasAuth {
            api.homeworkList(studentId: target.studentId) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case .success(let items):
                        self.homeworkItems = items.compactMap(WatchHomeworkItem.init(dict:))
                        self.toast = self.homeworkItems.isEmpty ? "진행 중 숙제 없음" : "숙제 \(self.homeworkItems.count)개"
                    case .failure:
                        self.bridgeRequestHomework(for: target)
                    }
                }
            }
            return
        }
        bridgeRequestHomework(for: target)
    }

    private func bridgeRequestHomework(for target: WatchTarget) {
        guard WCSession.default.activationState == .activated,
              WCSession.default.isReachable else {
            toast = "iPhone 앱을 열면 숙제 동기화"
            return
        }
        let payload: [String: Any] = [
            "type": "homeworkList",
            "studentId": target.studentId,
        ]
        WCSession.default.sendMessage(payload, replyHandler: { [weak self] reply in
            DispatchQueue.main.async {
                guard (reply["ok"] as? Bool) ?? false else {
                    self?.toast = (reply["message"] as? String) ?? "숙제 목록 실패"
                    return
                }
                let rawItems = (reply["items"] as? [[String: Any]]) ?? []
                self?.homeworkItems = rawItems.compactMap(WatchHomeworkItem.init(dict:))
                self?.toast = (reply["message"] as? String) ?? "숙제 목록"
            }
        }, errorHandler: { [weak self] error in
            DispatchQueue.main.async {
                self?.toast = "숙제 요청 실패: \(error.localizedDescription)"
            }
        })
    }

    func submitHomeworkCheck(
        _ item: WatchHomeworkItem,
        progress: Int,
        completion: ((Bool, String) -> Void)? = nil
    ) {
        if iphoneReachable {
            bridgeSubmitHomeworkCheck(item, progress: progress, completion: completion)
            return
        }
        if api.hasAuth {
            api.homeworkCheck(item: item, progress: progress) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case .success(let message):
                        self.updateHomeworkProgress(item, progress: progress)
                        if progress >= 100 {
                            self.homeworkItems.removeAll { $0.id == item.id }
                        }
                        self.toast = message
                        completion?(true, message)
                    case .failure(let err):
                        if case .noAuth = err {
                            self.bridgeSubmitHomeworkCheck(item, progress: progress, completion: completion)
                        } else {
                            let message = "저장 실패, 다시 시도해주세요"
                            self.toast = message
                            completion?(false, message)
                        }
                    }
                }
            }
            return
        }
        bridgeSubmitHomeworkCheck(item, progress: progress, completion: completion)
    }

    private func bridgeSubmitHomeworkCheck(
        _ item: WatchHomeworkItem,
        progress: Int,
        completion: ((Bool, String) -> Void)? = nil
    ) {
        guard WCSession.default.activationState == .activated,
              WCSession.default.isReachable else {
            toast = "iPhone 앱을 열면 저장 가능"
            completion?(false, "iPhone 앱을 열면 저장 가능")
            return
        }
        let payload: [String: Any] = [
            "type": "homeworkCheck",
            "studentId": item.studentId,
            "assignmentId": item.assignmentId,
            "homeworkItemId": item.homeworkItemId,
            "progress": progress,
        ]
        WCSession.default.sendMessage(payload, replyHandler: { [weak self] reply in
            DispatchQueue.main.async {
                let ok = (reply["ok"] as? Bool) ?? false
                if ok {
                    self?.updateHomeworkProgress(item, progress: progress)
                    if progress >= 100 {
                        self?.homeworkItems.removeAll { $0.id == item.id }
                    }
                }
                let message = (reply["message"] as? String) ?? (ok ? "기록되었습니다" : "저장 실패")
                self?.toast = message
                completion?(ok, message)
            }
        }, errorHandler: { [weak self] error in
            DispatchQueue.main.async {
                let message = "숙제 저장 실패: \(error.localizedDescription)"
                self?.toast = message
                completion?(false, message)
            }
        })
    }

    private func updateHomeworkProgress(_ item: WatchHomeworkItem, progress: Int) {
        homeworkItems = homeworkItems.map { current in
            guard current.id == item.id else { return current }
            var updated = current
            updated.progress = progress
            return updated
        }
    }

    /// 등원/하원 이벤트를 iPhone으로 전송한다.
    /// 도달 가능하면 즉시 sendMessage, 아니면 transferUserInfo로 큐잉(백그라운드 보장 전달).
    func sendAttendance(action: String, target: WatchTarget) {
        // iPhone이 켜져 있으면 검증된 브리지(DataManager) 경로로 기록한다.
        if iphoneReachable {
            bridgeSendAttendance(action: action, target: target)
            return
        }
        if api.hasAuth {
            // 단독 동작: 서버에 직접 기록. 낙관적 UI는 즉시 반영한다.
            applyQueuedAttendance(action: action, target: target)
            api.recordAttendance(action: action, target: target) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case .success(let message):
                        self.toast = message
                        self.requestSnapshot()
                    case .failure(let err):
                        if case .noAuth = err {
                            self.bridgeSendAttendance(action: action, target: target)
                        } else {
                            self.toast = "기록 실패, 다시 시도해주세요"
                        }
                    }
                }
            }
            return
        }
        bridgeSendAttendance(action: action, target: target)
    }

    private func bridgeSendAttendance(action: String, target: WatchTarget) {
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
                    if ok {
                        if (reply["type"] as? String) == "todayTargets" {
                            self?.applyContext(reply)
                        } else if let snapshot = reply["snapshot"] as? [String: Any],
                                  (snapshot["type"] as? String) == "todayTargets" {
                            self?.applyContext(snapshot)
                        } else if let updated = reply["updatedTarget"] as? [String: Any],
                                  let target = WatchTarget(dict: updated) {
                            self?.replaceTarget(target)
                        }
                        self?.applyQueuedAttendance(action: action, target: target)
                    }
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

    private func replaceTarget(_ target: WatchTarget) {
        var found = false
        let updated = targets.map { item -> WatchTarget in
            guard item.setId == target.setId else { return item }
            found = true
            return target
        }
        targets = found ? updated : (targets + [target])
        cacheTargets(targets.map { $0.asDictionary() }, snapshotDate: Self.isoString(Date()))
    }

    private func applyContext(_ context: [String: Any]) {
        guard (context["type"] as? String) == "todayTargets" else { return }
        let rawItems = (context["items"] as? [[String: Any]]) ?? []
        let parsed = rawItems.compactMap(WatchTarget.init(dict:))
        let apply = {
            self.targets = parsed
            self.cacheTargets(rawItems, snapshotDate: context["date"] as? String)
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
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

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if (userInfo["type"] as? String) == "watchAuth" {
            handleAuthPayload(userInfo)
        }
    }

    /// iPhone이 릴레이한 Supabase 토큰을 저장하고, 즉시 서버에서 최신 데이터를 가져온다.
    private func handleAuthPayload(_ dict: [String: Any]) {
        let auth = WatchAuth(
            accessToken: (dict["accessToken"] as? String) ?? "",
            refreshToken: (dict["refreshToken"] as? String) ?? "",
            supabaseUrl: (dict["supabaseUrl"] as? String) ?? "",
            anonKey: (dict["anonKey"] as? String) ?? "",
            academyId: (dict["academyId"] as? String) ?? "",
            expiresAt: (dict["expiresAt"] as? Int) ?? Int((dict["expiresAt"] as? Double) ?? 0)
        )
        guard auth.isUsable else { return }
        api.updateAuth(auth)
        DispatchQueue.main.async {
            self.statusText = "단독 동작 준비됨"
            self.requestSnapshot()
        }
    }
}
