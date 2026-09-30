import Charts
import ProxyCore
import SwiftUI

struct ContentView: View {
  @State private var controller = ProxyController()

  var body: some View {
    NavigationStack {
      List {
        Section {
          StatusCard(controller: controller)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }

        if let error = controller.lastError {
          Section {
            Label(error, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
          }
        }

        Section("Throughput") {
          ThroughputView(samples: controller.samples, isRunning: controller.isRunning)
        }

        Section {
          LabeledContent("SOCKS5 port", value: "11080")
        } header: {
          Text("Connect from Mac")
        } footer: {
          Text("Connect your Mac with a USB cable or join this iPhone's Personal Hotspot, then turn on Nothering in the Mac menu bar app. Outbound connections use cellular only.")
        }

        Section("Traffic") {
          LabeledContent("Active connections", value: "\(controller.stats.activeConnections)")
          LabeledContent("Total connections", value: "\(controller.stats.totalConnections)")
          LabeledContent("Sent", value: formatBytes(controller.stats.bytesUp))
          LabeledContent("Received", value: formatBytes(controller.stats.bytesDown))
        }

        Section("About") {
          LabeledContent("Version", value: appVersion)
          Link(destination: URL(string: "https://github.com/devxoul/nothering")!) {
            LabeledContent {
              HStack(spacing: 4) {
                Text("devxoul/nothering")
                Image(systemName: "arrow.up.right")
                  .font(.footnote)
              }
            } label: {
              Text("GitHub")
                .foregroundStyle(Color.primary)
            }
          }
        }
      }
      .navigationTitle("Nothering")
      .task {
        if CommandLine.arguments.contains("--autostart"), !controller.isRunning {
          await controller.start()
        }
      }
    }
  }
}

private struct StatusCard: View {
  let controller: ProxyController
  @State private var pulse = false
  @Environment(\.colorScheme) private var colorScheme

  private static let accent = Color(red: 0.25, green: 0.85, blue: 0.85)
  private static let chainBlue = Color(red: 39 / 255, green: 173 / 255, blue: 249 / 255)

  private var tile: RoundedRectangle {
    RoundedRectangle(cornerRadius: 29, style: .continuous)
  }

  var body: some View {
    VStack(spacing: 16) {
      ZStack {
        tile
          .stroke(Self.accent, lineWidth: 3)
          .scaleEffect(pulse ? 1.3 : 1)
          .opacity(controller.isRunning ? (pulse ? 0 : 0.8) : 0)
        Image(.hero)
          .resizable()
          .scaledToFit()
          .saturation(controller.isRunning ? 1 : 0)
          .opacity(controller.isRunning ? 1 : 0.55)
      }
      .frame(width: 128, height: 128)
      .shadow(color: controller.isRunning ? Self.accent.opacity(0.45) : .black.opacity(0.15), radius: controller.isRunning ? 24 : 8, y: 6)
      .accessibilityHidden(true)

      VStack(spacing: 4) {
        Text(controller.isRunning ? "Running" : "Stopped")
          .font(.title2.bold())
        if let startedAt = controller.startedAt {
          TimelineView(.periodic(from: startedAt, by: 1)) { context in
            Text(formatUptime(context.date.timeIntervalSince(startedAt)))
              .font(.subheadline)
              .monospacedDigit()
              .foregroundStyle(.secondary)
          }
        } else {
          Text("Share this iPhone's cellular with your Mac")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }

      if controller.isRunning {
        MacLinkLabel(links: controller.macLinks)
      }

      Button {
        Task { await controller.toggle() }
      } label: {
        HStack(spacing: 8) {
          Image(systemName: controller.isRunning ? "stop.fill" : "power")
          Text(controller.isRunning ? "Stop Proxy" : "Start Proxy")
        }
        .font(.body.weight(.semibold))
        .foregroundStyle(.primary)
        .frame(maxWidth: 220)
        .padding(.vertical, 14)
        .background(
          (controller.isRunning ? Color.red : Self.chainBlue).opacity(colorScheme == .dark ? 0.25 : 0.18),
          in: .capsule
        )
      }
      .buttonStyle(PressableStyle())
    }
    .sensoryFeedback(.impact(weight: .medium), trigger: controller.isRunning)
    .frame(maxWidth: .infinity)
    .padding(.vertical, 24)
    .animation(.easeInOut, value: controller.isRunning)
    .onChange(of: controller.isRunning, initial: true) { _, running in
      pulse = false
      if running {
        withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
          pulse = true
        }
      }
    }
  }
}

private struct MacLinkLabel: View {
  let links: Set<ProxyServer.Link>

  var body: some View {
    let (title, symbol) = content
    HStack(spacing: 6) {
      Image(systemName: symbol)
        .accessibilityHidden(true)
      Text(title)
    }
    .font(.footnote.weight(.medium))
    .foregroundStyle(links.isEmpty ? .secondary : .primary)
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(.fill.tertiary, in: .capsule)
    .animation(.easeInOut, value: links)
  }

  private var content: (title: LocalizedStringKey, symbol: String) {
    switch (links.contains(.usb), links.contains(.hotspot)) {
    case (true, true): ("Mac connected via USB and Hotspot", "laptopcomputer.and.iphone")
    case (true, false): ("Mac connected via USB", "cable.connector")
    case (false, true): ("Mac connected via Personal Hotspot", "personalhotspot")
    case (false, false): ("Waiting for Mac…", "laptopcomputer")
    }
  }
}

private struct PressableStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
      .opacity(configuration.isPressed ? 0.85 : 1)
      .animation(.snappy(duration: 0.15), value: configuration.isPressed)
  }
}

private struct ThroughputView: View {
  let samples: [ProxyController.ThroughputSample]
  let isRunning: Bool

  private var current: ProxyController.ThroughputSample? {
    isRunning ? samples.last : nil
  }

  var body: some View {
    VStack(spacing: 12) {
      HStack(spacing: 16) {
        SpeedLabel(title: "Upload", symbol: "arrow.up", color: .orange, bytesPerSecond: current?.up ?? 0)
        Divider()
        SpeedLabel(title: "Download", symbol: "arrow.down", color: .blue, bytesPerSecond: current?.down ?? 0)
      }
      .fixedSize(horizontal: false, vertical: true)

      Chart(samples) { sample in
        AreaMark(x: .value("Time", sample.id), y: .value("Bytes/s", sample.down))
          .foregroundStyle(by: .value("Direction", "Download"))
          .interpolationMethod(.monotone)
        AreaMark(x: .value("Time", sample.id), y: .value("Bytes/s", sample.up))
          .foregroundStyle(by: .value("Direction", "Upload"))
          .interpolationMethod(.monotone)
      }
      .chartForegroundStyleScale([
        "Download": Color.blue.opacity(0.5),
        "Upload": Color.orange.opacity(0.5),
      ])
      .chartXScale(domain: xDomain)
      .chartXAxis(.hidden)
      .chartYAxis {
        AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
          AxisGridLine()
          AxisValueLabel {
            if let bytes = value.as(Double.self) {
              Text(formatBytes(UInt64(bytes)))
            }
          }
        }
      }
      .chartLegend(.hidden)
      .frame(height: 120)
      .overlay {
        if samples.isEmpty {
          Text("Start the proxy to see live traffic")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(.vertical, 8)
  }

  private var xDomain: ClosedRange<Int> {
    let last = samples.last?.id ?? 0
    let first = max(0, last - ProxyController.sampleWindow + 1)
    return first...max(first + ProxyController.sampleWindow - 1, last)
  }
}

private struct SpeedLabel: View {
  let title: String
  let symbol: String
  let color: Color
  let bytesPerSecond: Double

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 4) {
        Image(systemName: symbol)
        Text(title)
      }
      .font(.caption.weight(.medium))
      .foregroundStyle(color)
      Text("\(formatBytes(UInt64(bytesPerSecond)))/s")
        .font(.title3.bold())
        .monospacedDigit()
        .contentTransition(.numericText(value: bytesPerSecond))
        .animation(.snappy, value: bytesPerSecond)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private func formatBytes(_ bytes: UInt64) -> String {
  Int64(bytes).formatted(.byteCount(style: .binary, spellsOutZero: false))
}

private let appVersion: String = {
  let info = Bundle.main.infoDictionary
  let version = info?["CFBundleShortVersionString"] as? String ?? "?"
  let build = info?["CFBundleVersion"] as? String ?? "?"
  return "\(version) (\(build))"
}()

private func formatUptime(_ interval: TimeInterval) -> String {
  Duration.seconds(Int(interval)).formatted(.time(pattern: .hourMinuteSecond))
}
