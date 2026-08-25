//
//  YggdrasillWatchAppApp.swift
//  YggdrasillWatchApp Watch App
//
//  Created by 베르누이 on 6/24/26.
//

import SwiftUI

@main
struct YggdrasillWatchApp_Watch_AppApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self)
    private var appDelegate
    @StateObject private var connectivity = WatchConnectivityModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(connectivity)
                .onChange(of: scenePhase) { phase in
                    switch phase {
                    case .active:
                        connectivity.startLiveRefresh()
                        connectivity.requestSnapshot(silent: true)
                    case .background:
                        connectivity.stopLiveRefresh()
                    default:
                        break
                    }
                }
        }
    }
}
