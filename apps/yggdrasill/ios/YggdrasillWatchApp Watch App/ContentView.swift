//
//  ContentView.swift
//  YggdrasillWatchApp Watch App
//
//  Created by 베르누이 on 6/24/26.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var connectivity: WatchConnectivityModel

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "tree")
                .font(.title2)
                .foregroundStyle(.green)

            Text("Yggdrasill")
                .font(.headline)

            Text(connectivity.statusText)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button("iPhone 확인") {
                connectivity.sendPing()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

#Preview {
    ContentView()
        .environmentObject(WatchConnectivityModel())
}
