//
//  ContentView.swift
//  YggdrasillWatchApp Watch App
//
//  Created by 베르누이 on 6/24/26.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var connectivity: WatchConnectivityModel
    @State private var homeworkTarget: WatchTarget?

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
        .sheet(item: $homeworkTarget) { target in
            NavigationStack {
                HomeworkListView(target: target)
                    .environmentObject(connectivity)
            }
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
        ScrollViewReader { proxy in
            List {
                ForEach(connectivity.targets) { target in
                    TargetRow(
                        target: target,
                        onHomework: {
                            connectivity.requestHomework(for: target)
                            homeworkTarget = target
                        },
                        onAttendance: { action in
                            connectivity.sendAttendance(action: action, target: target)
                        }
                    )
                    .id(target.id)
                }

                Button {
                    connectivity.requestSnapshot()
                } label: {
                    Label("새로고침", systemImage: "arrow.clockwise")
                }
                .foregroundStyle(.secondary)
            }
            .onAppear {
                scrollToCurrentTarget(proxy)
            }
            .onChange(of: connectivity.targets.map(\.id).joined(separator: "|")) { _ in
                scrollToCurrentTarget(proxy)
            }
        }
    }

    private func scrollToCurrentTarget(_ proxy: ScrollViewProxy) {
        guard let target = nearestTargetToNow() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withAnimation(.easeInOut) {
                proxy.scrollTo(target.id, anchor: .center)
            }
        }
    }

    private func nearestTargetToNow() -> WatchTarget? {
        let now = Date()
        return connectivity.targets.min { lhs, rhs in
            abs((parseDate(lhs.classDateTime) ?? now).timeIntervalSince(now)) <
                abs((parseDate(rhs.classDateTime) ?? now).timeIntervalSince(now))
        }
    }

    private func parseDate(_ value: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for pattern in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss"] {
            formatter.dateFormat = pattern
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}

private struct TargetRow: View {
    let target: WatchTarget
    let onHomework: () -> Void
    let onAttendance: (String) -> Void
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        ZStack {
            slideBackground
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
            .padding(.vertical, 8)
            .offset(x: dragOffset)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onHomework()
        }
        .gesture(
            DragGesture(minimumDistance: 16)
                .onChanged { value in
                    let translation = value.translation.width
                    if translation > 0, target.status == "waiting" {
                        dragOffset = min(translation, 72)
                    } else if translation < 0, target.status == "attended" {
                        dragOffset = max(translation, -72)
                    } else {
                        dragOffset = 0
                    }
                }
                .onEnded { value in
                    let threshold: CGFloat = 46
                    let translation = value.translation.width
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.78)) {
                        dragOffset = 0
                    }
                    if translation > threshold {
                        guard target.status == "waiting" else { return }
                        onAttendance("arrival")
                    } else if translation < -threshold {
                        guard target.status == "attended" else { return }
                        onAttendance("departure")
                    }
                }
        )
    }

    @ViewBuilder
    private var slideBackground: some View {
        if dragOffset > 6 {
            HStack {
                Text("등원")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                    .padding(.leading, 10)
                Spacer()
            }
            .frame(width: max(dragOffset, 64), alignment: .leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(alignment: .leading) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.green.opacity(0.85))
                    .frame(width: max(dragOffset, 64))
            }
        } else if dragOffset < -6 {
            HStack {
                Spacer()
                Text("하원")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                    .padding(.trailing, 10)
            }
            .frame(width: max(-dragOffset, 64), alignment: .trailing)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .background(alignment: .trailing) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.blue.opacity(0.85))
                    .frame(width: max(-dragOffset, 64))
            }
        } else {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.clear)
        }
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

private struct HomeworkListView: View {
    @EnvironmentObject private var connectivity: WatchConnectivityModel
    let target: WatchTarget

    var body: some View {
        List {
            if connectivity.homeworkItems.isEmpty {
                Text("진행 중 숙제 없음")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(connectivity.homeworkItems) { item in
                    NavigationLink {
                        HomeworkProgressView(item: item)
                            .environmentObject(connectivity)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(item.source) · \(item.course)")
                                .font(.caption2)
                                .lineLimit(1)
                                .foregroundStyle(.secondary)
                            Text(item.groupTitle)
                                .font(.footnote)
                                .fontWeight(.semibold)
                                .lineLimit(1)
                            HStack {
                                Text(item.assignedDate)
                                Spacer(minLength: 4)
                                if !item.pageLabel.isEmpty {
                                    Text(item.pageLabel)
                                        .fontWeight(.semibold)
                                        .lineLimit(1)
                                        .multilineTextAlignment(.trailing)
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
        }
        .navigationTitle(target.name)
        .onAppear {
            connectivity.requestHomework(for: target)
        }
    }
}

private struct HomeworkProgressView: View {
    @EnvironmentObject private var connectivity: WatchConnectivityModel
    @Environment(\.dismiss) private var dismiss
    let item: WatchHomeworkItem
    @State private var progress: Double = 0
    @State private var message: String?

    var body: some View {
        VStack(spacing: 10) {
            Text(item.title)
                .font(.headline)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                VerticalProgressIndicator(progress: progress)
                    .frame(width: 14, height: 96)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(Int(progress))%")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("크라운을 돌려 완료율 조정")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let message {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
            Button("기록") {
                connectivity.submitHomeworkCheck(item, progress: Int(progress)) { ok, text in
                    message = ok ? "기록되었습니다" : text
                    if ok {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                            dismiss()
                        }
                    }
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .focusable(true)
        .digitalCrownRotation(
            $progress,
            from: 0,
            through: 150,
            by: 5,
            sensitivity: .medium,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
        .onAppear {
            progress = Double(item.progress)
        }
    }
}

private struct VerticalProgressIndicator: View {
    let progress: Double

    var body: some View {
        GeometryReader { geometry in
            let clamped = min(max(progress, 0), 150) / 150
            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(.secondary.opacity(0.25))
                Capsule()
                    .fill(progress >= 100 ? Color.green : Color.orange)
                    .frame(height: geometry.size.height * clamped)
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(WatchConnectivityModel())
}
