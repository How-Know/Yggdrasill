//
//  YggdrasillWatchAppApp.swift
//  YggdrasillWatchApp Watch App
//
//  Created by 베르누이 on 6/24/26.
//

import SwiftUI

@main
struct YggdrasillWatchApp_Watch_AppApp: App {
    @StateObject private var connectivity = WatchConnectivityModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(connectivity)
        }
    }
}
