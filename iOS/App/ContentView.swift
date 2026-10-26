import Charts
import ProxyCore
import SwiftUI

struct ContentView: View {
  @State private var controller = ProxyController()
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.openURL) private var openURL
  @AppStorage(TerminationAlert.enabledKey) private var notifiesOnTermination = false
  @AppStorage(FocusSound.storageKey) private var focusSound = FocusSound.off
  @State private var showingFocusGuide = false

  private var notifiesOnTerminationBinding: Binding<Bool> {
    Binding(
      get: { notifiesOnTermination },
      set: { enabled in
        Task {
          notifiesOnTermination = await controller.setNotifiesOnTermination(enabled)
          if enabled, !notifiesOnTermination {
            openURL(URL(string: UIApplication.openNotificationSettingsURLString)!)
          }
        }
      }
    )
  }

  var body: some View {
    NavigationStack {
      List {
        Section {
          StatusCard(controller: controller, notifiesOnTermination: notifiesOnTerminationBinding)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }

        if let error = controller.lastError {
          Section {
            Label(error, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
          }
        }

        Section {
          Picker("Focus sound", selection: $focusSound) {
            ForEach(FocusSound.allCases) { sound in
              Text(sound.title).tag(sound)
            }
          }
        } footer: {
          Text("Working from a cafe, a client's office or a job site? Ambient noise masks the chatter around you so you can focus. It plays while the proxy is on, including when Nothering is in the background or the iPhone is locked.")
        }

        Section("Throughput") {
          ThroughputView(samples: controller.samples, isRunning: controller.isRunning)
        }

        Section {
          UsageView(usage: controller.usage, sessionBytes: controller.sessionUsage, isRunning: controller.isRunning)
          LabeledContent("Today", value: formatBytes(controller.usage.today()))
          LabeledContent("This month", value: formatBytes(controller.usage.thisMonth()))
          LabeledContent("All time", value: formatBytes(controller.usage.allTime))
        } header: {
          Text("Usage")
        } footer: {
          Text("Carriers count this traffic as the iPhone's own data, not Personal Hotspot data. Usage stays on this iPhone.")
        }

        Section {
          LabeledContent("SOCKS5 port", value: "11080")
        } header: {
          Text("Connect from Mac")
        } footer: {
          Text("Connect your Mac with a USB cable or join this iPhone's Personal Hotspot, then turn on Nothering in the Mac menu bar app.")
        }

        Section("Traffic") {
          LabeledContent("Active connections", value: "\(controller.stats.activeConnections)")
          LabeledContent("Total connections", value: "\(controller.stats.totalConnections)")
          LabeledContent("Sent", value: formatBytes(controller.stats.bytesUp))
          LabeledContent("Received", value: formatBytes(controller.stats.bytesDown))
        }

        Section {
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
        } header: {
          Text("About")
        } footer: {
          Text("Made with \(Text(Image(systemName: "heart.fill")).foregroundStyle(.red)) in Seoul")
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
        }
      }
      .navigationTitle("Nothering")
      .environment(\.openURL, OpenURLAction { url in
        guard url.scheme == "nothering" else { return .systemAction }
        showingFocusGuide = true
        return .handled
      })
      .alert("Get alerts during Focus", isPresented: $showingFocusGuide) {
        Button("Open Settings") {
          openURL(URL(string: "App-prefs:FOCUS")!) { accepted in
            if !accepted {
              openURL(URL(string: UIApplication.openSettingsURLString)!)
            }
          }
        }
        Button("OK", role: .cancel) {}
      } message: {
        Text("Do Not Disturb and other Focus modes silence this notification. To get it anyway, open Focus in Settings, choose a Focus, and tap Apps. Add Nothering under Allow Notifications From, or remove it if the Focus uses Silence Notifications From.")
      }
      .task {
        if CommandLine.arguments.contains("--autostart") || controller.shouldRestore, !controller.isRunning {
          await controller.start()
        }
      }
      .onChange(of: focusSound) { _, sound in
        controller.setFocusSound(sound)
      }
      .onChange(of: scenePhase) { _, phase in
        if phase == .active {
          controller.resumeKeeper()
        }
      }
    }
  }
}

private struct StatusCard: View {
  let controller: ProxyController
  @Binding var notifiesOnTermination: Bool
  @State private var confirmingStop = false
  @Environment(\.colorScheme) private var colorScheme

  private static let accent = Color(red: 0.25, green: 0.85, blue: 0.85)
  private static let chainBlue = Color(red: 39 / 255, green: 173 / 255, blue: 249 / 255)

  private var tile: RoundedRectangle {
    RoundedRectangle(cornerRadius: 29, style: .continuous)
  }

  var body: some View {
    VStack(spacing: 16) {
      ZStack {
        PulseRing(shape: tile, color: Self.accent, startedAt: controller.startedAt)
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
        // Both stay in the layout so the button below doesn't move when the proxy starts.
        ZStack {
          Text("Run a network proxy for your Mac")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .opacity(controller.isRunning ? 0 : 1)
            .accessibilityHidden(controller.isRunning)
          MacLinkLabel(links: controller.macLinks)
            .opacity(controller.isRunning ? 1 : 0)
            .accessibilityHidden(!controller.isRunning)
        }
      }

      Button {
        if controller.isRunning, !confirmingStop {
          confirmingStop = true
        } else {
          confirmingStop = false
          Task { await controller.toggle() }
        }
      } label: {
        HStack(spacing: 8) {
          Image(systemName: controller.isRunning ? "stop.fill" : "power")
          Text(controller.isRunning ? (confirmingStop ? "Tap Again to Stop" : "Stop Proxy") : "Start Proxy")
            .contentTransition(.interpolate)
        }
        .font(.body.weight(.semibold))
        .foregroundStyle(confirmingStop ? Color.white : Color.primary)
        .frame(maxWidth: 220)
        .padding(.vertical, 14)
        .background(
          confirmingStop
            ? Color.red
            : (controller.isRunning ? Color.red : Self.chainBlue).opacity(colorScheme == .dark ? 0.25 : 0.18),
          in: .capsule
        )
      }
      .buttonStyle(PressableStyle())
      .animation(.snappy, value: confirmingStop)
      .task(id: confirmingStop) {
        guard confirmingStop, (try? await Task.sleep(for: .seconds(3))) != nil else { return }
        confirmingStop = false
      }

      VStack(spacing: -10) {
        Button {
          notifiesOnTermination.toggle()
        } label: {
          HStack(spacing: 6) {
            Image(systemName: notifiesOnTermination ? "bell.fill" : "bell.slash")
              .contentTransition(.symbolEffect(.replace))
            Text("Notify if closed")
          }
          .font(.footnote.weight(.medium))
          .foregroundStyle(notifiesOnTermination ? Color.primary : Color.secondary)
          .frame(minHeight: 44)
          .contentShape(.rect)
        }
        .buttonStyle(PressableStyle())
        .accessibilityValue(notifiesOnTermination ? "On" : "Off")

        if notifiesOnTermination {
          Text("Silenced during Focus. [Allow during Focus…](nothering://focus-guide)")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
    }
    .sensoryFeedback(.impact(weight: .medium), trigger: controller.isRunning)
    .frame(maxWidth: .infinity)
    .padding(.vertical, 24)
    .animation(.easeInOut, value: controller.isRunning)
  }
}

/// Driven by the clock instead of a repeating animation, so layout animations can't leak into it.
private struct PulseRing: View {
  let shape: RoundedRectangle
  let color: Color
  let startedAt: Date?

  private static let period = 1.6

  var body: some View {
    TimelineView(.animation(paused: startedAt == nil)) { context in
      let progress = progress(at: context.date)
      shape
        .stroke(color, lineWidth: 3)
        .scaleEffect(1 + 0.3 * progress)
        .opacity(startedAt == nil ? 0 : 0.8 * (1 - progress))
    }
  }

  /// Ease-out phase within the current cycle, 0...1.
  private func progress(at date: Date) -> Double {
    guard let startedAt else { return 0 }
    let t = date.timeIntervalSince(startedAt).truncatingRemainder(dividingBy: Self.period) / Self.period
    return 1 - pow(1 - t, 2)
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

private struct UsageView: View {
  let usage: UsageLog
  let sessionBytes: UInt64
  let isRunning: Bool

  private static let dayCount = 30

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(isRunning ? "Hotspot data saved this session" : "Hotspot data saved last session")
          .font(.caption.weight(.medium))
          .foregroundStyle(.green)
        Text(formatBytes(sessionBytes))
          .font(.title2.bold())
          .monospacedDigit()
      }

      Chart(usage.recentDays(Self.dayCount)) { day in
        BarMark(x: .value("Day", day.id), y: .value("Bytes", Double(day.bytes)))
          .foregroundStyle(Color.green.gradient)
      }
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
      .frame(height: 80)
      .accessibilityLabel("Usage over the last \(Self.dayCount) days")
    }
    .padding(.vertical, 8)
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
