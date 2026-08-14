import ActivityKit
import SwiftUI
import WidgetKit

@main
struct HomeworkLiveActivityBundle: WidgetBundle {
  var body: some Widget {
    if #available(iOS 16.1, *) {
      HomeworkLiveActivityWidget()
    }
  }
}

/// live_activities 플러그인이 요구하는 고정 이름.
struct LiveActivitiesAppAttributes: ActivityAttributes, Identifiable {
  public typealias LiveDeliveryData = ContentState

  public struct ContentState: Codable, Hashable {}

  var id = UUID()
}

extension LiveActivitiesAppAttributes {
  func prefixedKey(_ key: String) -> String {
    "\(id)_\(key)"
  }
}

let sharedDefault = UserDefaults(suiteName: "group.com.beleunu.yggdrasillStudent")!

@available(iOSApplicationExtension 16.1, *)
struct HomeworkLiveActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: LiveActivitiesAppAttributes.self) { context in
      HomeworkLockScreenView(context: context)
    } dynamicIsland: { context in
      let title = sharedDefault.string(forKey: context.attributes.prefixedKey("title")) ?? "과제"
      let elapsed = sharedDefault.string(forKey: context.attributes.prefixedKey("elapsedLabel")) ?? "0:00"
      let isRunning = (sharedDefault.string(forKey: context.attributes.prefixedKey("isRunning")) ?? "0") == "1"
      // 제출은 등원 중에만. 하원하면 흐리게 보인다.
      let canSubmit = (sharedDefault.string(forKey: context.attributes.prefixedKey("canSubmit")) ?? "1") == "1"

      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          VStack(alignment: .leading, spacing: 4) {
            Text(title)
              .font(.headline)
              .lineLimit(2)
            Text(isRunning ? "수행 중" : "일시정지")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        DynamicIslandExpandedRegion(.trailing) {
          elapsedText(context: context)
            .font(.title2.monospacedDigit().weight(.semibold))
            .minimumScaleFactor(0.7)
        }
        DynamicIslandExpandedRegion(.bottom) {
          HStack(spacing: 16) {
            Link(destination: URL(string: "yggstudent://toggle")!) {
              Label(isRunning ? "일시정지" : "수행", systemImage: isRunning ? "pause.fill" : "play.fill")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
            }
            Link(destination: URL(string: "yggstudent://submit")!) {
              Label("제출", systemImage: "checkmark")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.green.opacity(canSubmit ? 0.85 : 0.25), in: Capsule())
                .foregroundStyle(canSubmit ? .white : Color.white.opacity(0.5))
            }
            .disabled(!canSubmit)
          }
        }
      } compactLeading: {
        Image(systemName: isRunning ? "book.fill" : "pause.fill")
      } compactTrailing: {
        Text(elapsed)
          .font(.caption2.monospacedDigit())
          .minimumScaleFactor(0.6)
      } minimal: {
        Image(systemName: "book.fill")
      }
    }
  }

  @ViewBuilder
  private func elapsedText(context: ActivityViewContext<LiveActivitiesAppAttributes>) -> some View {
    let isRunning = (sharedDefault.string(forKey: context.attributes.prefixedKey("isRunning")) ?? "0") == "1"
    let label = sharedDefault.string(forKey: context.attributes.prefixedKey("elapsedLabel")) ?? "0:00"
    if isRunning {
      let anchorMs = sharedDefault.double(forKey: context.attributes.prefixedKey("timerAnchorMs"))
      let start = Date(timeIntervalSince1970: anchorMs / 1000.0)
      Text(timerInterval: start...Date.distantFuture, countsDown: false)
        .monospacedDigit()
        .multilineTextAlignment(.trailing)
    } else {
      Text(label)
        .monospacedDigit()
    }
  }
}

@available(iOSApplicationExtension 16.1, *)
private struct HomeworkLockScreenView: View {
  let context: ActivityViewContext<LiveActivitiesAppAttributes>

  var body: some View {
    let title = sharedDefault.string(forKey: context.attributes.prefixedKey("title")) ?? "과제"
    let subtitle = sharedDefault.string(forKey: context.attributes.prefixedKey("subtitle")) ?? ""
    let status = sharedDefault.string(forKey: context.attributes.prefixedKey("statusLabel")) ?? ""
    let isRunning = (sharedDefault.string(forKey: context.attributes.prefixedKey("isRunning")) ?? "0") == "1"
    let elapsedLabel = sharedDefault.string(forKey: context.attributes.prefixedKey("elapsedLabel")) ?? "0:00"
    let anchorMs = sharedDefault.double(forKey: context.attributes.prefixedKey("timerAnchorMs"))
    let start = Date(timeIntervalSince1970: anchorMs / 1000.0)
    let canSubmit = (sharedDefault.string(forKey: context.attributes.prefixedKey("canSubmit")) ?? "1") == "1"

    HStack(spacing: 14) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.headline)
          .lineLimit(1)
        if !subtitle.isEmpty {
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Text(status)
          .font(.caption2.weight(.semibold))
          .foregroundStyle(isRunning ? Color.accentColor : .secondary)
      }

      Spacer(minLength: 8)

      VStack(alignment: .trailing, spacing: 8) {
        Group {
          if isRunning {
            Text(timerInterval: start...Date.distantFuture, countsDown: false)
              .font(.title2.monospacedDigit().weight(.bold))
              .multilineTextAlignment(.trailing)
              .frame(minWidth: 72, alignment: .trailing)
          } else {
            Text(elapsedLabel)
              .font(.title2.monospacedDigit().weight(.bold))
          }
        }

        HStack(spacing: 10) {
          Link(destination: URL(string: "yggstudent://toggle")!) {
            Image(systemName: isRunning ? "pause.fill" : "play.fill")
              .font(.system(size: 16, weight: .bold))
              .frame(width: 36, height: 36)
              .background(Color.primary.opacity(0.12), in: Circle())
          }
          Link(destination: URL(string: "yggstudent://submit")!) {
            Image(systemName: "checkmark")
              .font(.system(size: 16, weight: .bold))
              .foregroundStyle(canSubmit ? .white : Color.white.opacity(0.5))
              .frame(width: 36, height: 36)
              .background(canSubmit ? Color.green : Color.green.opacity(0.3), in: Circle())
          }
          .disabled(!canSubmit)
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
    .activityBackgroundTint(Color.black.opacity(0.25))
  }
}
