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
        NavigationStack {
            Group {
                if connectivity.targets.isEmpty {
                    emptyState
                } else {
                    targetList
                }
            }
            .navigationTitle("출결")
        }
        .overlay(alignment: .bottom) {
            if let toast = connectivity.toast {
                Text(toast)
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.opacity)
                    .task {
                        try? await Task.sleep(nanoseconds: 1_800_000_000)
                        connectivity.toast = nil
                    }
            }
        }
        .animation(.default, value: connectivity.toast)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tree")
                .font(.title2)
                .foregroundStyle(.green)
            Text("오늘 수업 없음")
                .font(.headline)
            Text(connectivity.statusText)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("새로고침") {
                connectivity.requestSnapshot()
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }

    private var targetList: some View {
        List {
            ForEach(connectivity.targets) { target in
                TargetRow(target: target) { action in
                    connectivity.sendAttendance(action: action, target: target)
                }
            }

            Section {
                Button {
                    connectivity.toast = "숙제 검사: 준비 중"
                } label: {
                    Label("숙제 검사", systemImage: "checklist")
                }
                Button {
                    connectivity.toast = "태도 태그: 준비 중"
                } label: {
                    Label("태도 태그", systemImage: "tag")
                }
            } header: {
                Text("다음 단계")
            }
            .foregroundStyle(.secondary)
        }
    }
}

private struct TargetRow: View {
    let target: WatchTarget
    let onAction: (String) -> Void

    var body: some View {
        Button {
            switch target.status {
            case "waiting": onAction("arrival")
            case "attended": onAction("departure")
            default: break // leaved: 완료 상태
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.name)
                        .font(.headline)
                    Text(target.className)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    statusBadge
                    if let timeLabel = target.timeLabel {
                        Text(timeLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .disabled(target.status == "leaved")
    }

    private var statusBadge: some View {
        Text(target.statusLabel)
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(badgeColor.opacity(0.25), in: Capsule())
            .foregroundStyle(badgeColor)
    }

    private var badgeColor: Color {
        switch target.status {
        case "attended": return .green
        case "leaved": return .gray
        default: return .orange
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(WatchConnectivityModel())
}
