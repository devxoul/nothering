import ActivityKit
import SwiftUI
import WidgetKit

@main
struct NotheringWidgets: WidgetBundle {
  var body: some Widget {
    ProxyLiveActivity()
  }
}

/// Tapping it opens the app, which restarts the proxy if iOS terminated it.
struct ProxyLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: ProxyActivityAttributes.self) { context in
      let status = Status(context)
      HStack(spacing: 12) {
        StatusIcon(status: status)
          .font(.title2)
        VStack(alignment: .leading, spacing: 2) {
          Text(status.title)
            .font(.headline)
          Text(status.subtitle)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
        if !status.isClosed {
          Uptime(startedAt: context.attributes.startedAt)
            .font(.headline)
        }
      }
      .padding()
    } dynamicIsland: { context in
      let status = Status(context)
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          StatusIcon(status: status)
            .font(.title2)
        }
        DynamicIslandExpandedRegion(.trailing) {
          if !status.isClosed {
            Uptime(startedAt: context.attributes.startedAt)
          }
        }
        DynamicIslandExpandedRegion(.center) {
          Text(status.title)
            .font(.headline)
        }
        DynamicIslandExpandedRegion(.bottom) {
          Text(status.subtitle)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      } compactLeading: {
        StatusIcon(status: status)
      } compactTrailing: {
        if status.isClosed {
          Text("Closed")
            .foregroundStyle(.orange)
        } else {
          Uptime(startedAt: context.attributes.startedAt)
            .frame(maxWidth: 56)
        }
      } minimal: {
        StatusIcon(status: status)
      }
    }
  }
}

private struct Status {
  let isClosed: Bool
  let title: LocalizedStringKey
  let subtitle: LocalizedStringKey

  init(_ context: ActivityViewContext<ProxyActivityAttributes>) {
    isClosed = context.isStale
    if isClosed {
      title = "Nothering was closed"
      subtitle = "Tap to reopen and keep the proxy running"
      return
    }
    title = "Proxy running"
    switch (context.state.usb, context.state.hotspot) {
    case (true, true): subtitle = "Mac connected via USB and Hotspot"
    case (true, false): subtitle = "Mac connected via USB"
    case (false, true): subtitle = "Mac connected via Personal Hotspot"
    case (false, false): subtitle = "Waiting for Mac…"
    }
  }
}

private struct StatusIcon: View {
  let status: Status

  var body: some View {
    Image(systemName: status.isClosed ? "exclamationmark.triangle.fill" : "antenna.radiowaves.left.and.right")
      .foregroundStyle(status.isClosed ? Color.orange : Color(red: 0.25, green: 0.85, blue: 0.85))
  }
}

private struct Uptime: View {
  let startedAt: Date

  var body: some View {
    Text(startedAt, style: .timer)
      .monospacedDigit()
      .multilineTextAlignment(.trailing)
  }
}
