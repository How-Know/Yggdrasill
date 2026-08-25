import Foundation
import UserNotifications
import WatchKit

extension Notification.Name {
    static let watchAttendancePushReceived =
        Notification.Name("yggdrasill.watch.attendancePushReceived")
    static let watchPushStatusChanged =
        Notification.Name("yggdrasill.watch.pushStatusChanged")
}

@MainActor
final class WatchPushService {
    static let shared = WatchPushService()

    private static let tokenKey = "yggdrasill.watch.apnsToken.v1"
    private let api = WatchAPIClient.shared

    private init() {}

    func configure() {
        syncStoredToken()
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: "ATTENDANCE",
                actions: [],
                intentIdentifiers: [],
                options: []
            ),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            guard granted, error == nil else {
                Task { @MainActor in
                    self.postStatus(ready: false, text: "알림 권한 필요")
                }
                return
            }
            DispatchQueue.main.async {
                self.postStatus(ready: false, text: "APNs 등록 중")
                WKApplication.shared().registerForRemoteNotifications()
            }
        }
    }

    func didRegister(deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        guard !token.isEmpty else { return }
        UserDefaults.standard.set(token, forKey: Self.tokenKey)
        postStatus(ready: false, text: "서버 등록 중")
        syncStoredToken()
    }

    func didFailToRegister(error: Error) {
        print("[WatchPush] APNs token registration failed: \(error.localizedDescription)")
        postStatus(ready: false, text: "APNs 등록 실패")
    }

    func syncStoredToken() {
        guard let token = UserDefaults.standard.string(forKey: Self.tokenKey),
              !token.isEmpty else { return }
        api.registerPushToken(token) { result in
            Task { @MainActor in
                switch result {
                case .success:
                    print("[WatchPush] APNs token registered")
                    self.postStatus(ready: true, text: "푸시 준비됨")
                case .failure(let error):
                    print("[WatchPush] token sync failed: \(error)")
                    self.postStatus(ready: false, text: "푸시 서버 등록 대기")
                }
            }
        }
    }

    func received(userInfo: [AnyHashable: Any]) {
        NotificationCenter.default.post(
            name: .watchAttendancePushReceived,
            object: nil,
            userInfo: userInfo
        )
    }

    private func postStatus(ready: Bool, text: String) {
        NotificationCenter.default.post(
            name: .watchPushStatusChanged,
            object: nil,
            userInfo: ["ready": ready, "text": text]
        )
    }
}

@MainActor
final class WatchAppDelegate: NSObject, WKApplicationDelegate,
    UNUserNotificationCenterDelegate
{
    func applicationDidFinishLaunching() {
        UNUserNotificationCenter.current().delegate = self
        WatchPushService.shared.configure()
    }

    func didRegisterForRemoteNotifications(withDeviceToken deviceToken: Data) {
        WatchPushService.shared.didRegister(deviceToken: deviceToken)
    }

    func didFailToRegisterForRemoteNotificationsWithError(_ error: Error) {
        WatchPushService.shared.didFailToRegister(error: error)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        WatchPushService.shared.received(
            userInfo: notification.request.content.userInfo
        )
        return [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        WatchPushService.shared.received(
            userInfo: response.notification.request.content.userInfo
        )
    }
}
