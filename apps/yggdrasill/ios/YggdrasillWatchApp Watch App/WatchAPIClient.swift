import Foundation

/// iPhone이 릴레이한 Supabase 인증 정보. Watch 단독 서버 통신에 사용한다.
struct WatchAuth: Codable {
    var accessToken: String
    var refreshToken: String
    var supabaseUrl: String
    var anonKey: String
    var academyId: String
    var expiresAt: Int

    var isUsable: Bool {
        !accessToken.isEmpty && !supabaseUrl.isEmpty && !anonKey.isEmpty && !academyId.isEmpty
    }
}

enum WatchAPIError: Error {
    case noAuth
    case badURL
    case http(Int, String)
    case decoding
    case transport(String)
}

/// watch_api Edge Function을 직접 호출하는 경량 클라이언트.
/// access token 만료(401) 시 refresh token으로 1회 자동 갱신 후 재시도한다.
final class WatchAPIClient {
    static let shared = WatchAPIClient()

    private static let authKey = "yggdrasill.watch.auth.v1"
    private let session = URLSession(configuration: .default)
    private let queue = DispatchQueue(label: "yggdrasill.watch.api")

    private(set) var auth: WatchAuth?

    init() {
        loadAuth()
    }

    var hasAuth: Bool { auth?.isUsable == true }

    func updateAuth(_ newAuth: WatchAuth) {
        queue.sync { self.auth = newAuth }
        persistAuth(newAuth)
    }

    private func loadAuth() {
        guard let data = UserDefaults.standard.data(forKey: Self.authKey),
              let decoded = try? JSONDecoder().decode(WatchAuth.self, from: data)
        else { return }
        auth = decoded
    }

    private func persistAuth(_ value: WatchAuth) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: Self.authKey)
        }
    }

    private func kstToday() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Seoul")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    // MARK: - Public API

    func todayTargets(completion: @escaping (Result<[[String: Any]], WatchAPIError>) -> Void) {
        guard let auth, auth.isUsable else { completion(.failure(.noAuth)); return }
        var components = URLComponents(string: "\(auth.supabaseUrl)/functions/v1/watch_api")
        components?.queryItems = [
            URLQueryItem(name: "action", value: "today_targets"),
            URLQueryItem(name: "academyId", value: auth.academyId),
            URLQueryItem(name: "date", value: kstToday()),
        ]
        guard let url = components?.url else { completion(.failure(.badURL)); return }
        sendJSON(url: url, method: "GET", body: nil) { result in
            completion(result.map { Self.extractItems($0) })
        }
    }

    func homeworkList(studentId: String, completion: @escaping (Result<[[String: Any]], WatchAPIError>) -> Void) {
        guard let auth, auth.isUsable else { completion(.failure(.noAuth)); return }
        var components = URLComponents(string: "\(auth.supabaseUrl)/functions/v1/watch_api")
        components?.queryItems = [
            URLQueryItem(name: "action", value: "homework_list"),
            URLQueryItem(name: "academyId", value: auth.academyId),
            URLQueryItem(name: "studentId", value: studentId),
            URLQueryItem(name: "date", value: kstToday()),
        ]
        guard let url = components?.url else { completion(.failure(.badURL)); return }
        sendJSON(url: url, method: "GET", body: nil) { result in
            completion(result.map { Self.extractItems($0) })
        }
    }

    func recordAttendance(
        action: String,
        target: WatchTarget,
        completion: @escaping (Result<String, WatchAPIError>) -> Void
    ) {
        guard let auth, auth.isUsable else { completion(.failure(.noAuth)); return }
        guard let url = URL(string: "\(auth.supabaseUrl)/functions/v1/watch_api") else {
            completion(.failure(.badURL)); return
        }
        var body: [String: Any] = [
            "action": "attendance",
            "attAction": action,
            "academyId": auth.academyId,
            "studentId": target.studentId,
            "classDateTime": target.classDateTime,
            "classEndTime": target.classEndTime,
            "className": target.className,
            "setId": target.setId,
        ]
        if let sessionTypeId = target.sessionTypeId { body["sessionTypeId"] = sessionTypeId }
        sendJSON(url: url, method: "POST", body: body) { result in
            completion(result.map { ($0["message"] as? String) ?? "기록됨" })
        }
    }

    func homeworkCheck(
        item: WatchHomeworkItem,
        progress: Int,
        completion: @escaping (Result<String, WatchAPIError>) -> Void
    ) {
        guard let auth, auth.isUsable else { completion(.failure(.noAuth)); return }
        guard let url = URL(string: "\(auth.supabaseUrl)/functions/v1/watch_api") else {
            completion(.failure(.badURL)); return
        }
        let body: [String: Any] = [
            "action": "homework_check",
            "academyId": auth.academyId,
            "studentId": item.studentId,
            "assignmentId": item.assignmentId,
            "homeworkItemId": item.homeworkItemId,
            "progress": progress,
        ]
        sendJSON(url: url, method: "POST", body: body) { result in
            completion(result.map { ($0["message"] as? String) ?? "기록되었습니다" })
        }
    }

    // MARK: - Networking core

    private static func extractItems(_ json: [String: Any]) -> [[String: Any]] {
        (json["items"] as? [[String: Any]]) ?? []
    }

    private func sendJSON(
        url: URL,
        method: String,
        body: [String: Any]?,
        allowRefresh: Bool = true,
        completion: @escaping (Result<[String: Any], WatchAPIError>) -> Void
    ) {
        guard let auth else { completion(.failure(.noAuth)); return }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(auth.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        if let body, JSONSerialization.isValidJSONObject(body) {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                completion(.failure(.transport(error.localizedDescription)))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 && allowRefresh {
                // access token 만료 추정 → refresh 후 1회 재시도.
                self.refreshSession { refreshed in
                    if refreshed {
                        self.sendJSON(url: url, method: method, body: body, allowRefresh: false, completion: completion)
                    } else {
                        completion(.failure(.http(401, "unauthorized")))
                    }
                }
                return
            }
            guard let data,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                completion(.failure(.decoding))
                return
            }
            if (json["ok"] as? Bool) == false {
                let message = (json["message"] as? String) ?? "요청 실패"
                completion(.failure(.http(status, message)))
                return
            }
            completion(.success(json))
        }
        task.resume()
    }

    /// refresh_token으로 새 access_token을 발급받아 저장한다.
    private func refreshSession(completion: @escaping (Bool) -> Void) {
        guard let auth, !auth.refreshToken.isEmpty,
              let url = URL(string: "\(auth.supabaseUrl)/auth/v1/token?grant_type=refresh_token")
        else { completion(false); return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(auth.anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["refresh_token": auth.refreshToken]
        )

        let task = session.dataTask(with: request) { [weak self] data, response, _ in
            guard let self else { completion(false); return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, let data,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let access = json["access_token"] as? String, !access.isEmpty
            else {
                completion(false)
                return
            }
            var updated = auth
            updated.accessToken = access
            if let refresh = json["refresh_token"] as? String, !refresh.isEmpty {
                updated.refreshToken = refresh
            }
            if let exp = json["expires_at"] as? Int {
                updated.expiresAt = exp
            } else if let exp = json["expires_at"] as? Double {
                updated.expiresAt = Int(exp)
            }
            self.updateAuth(updated)
            completion(true)
        }
        task.resume()
    }
}
