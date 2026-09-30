import AVFoundation

/// Keeps the app running in the background by playing silence (requires the `audio` background mode).
///
/// iOS suspends the app a few seconds after the engine stops, so every event that can stop it
/// (interruptions, route or configuration changes, media services resets) restarts it.
final class BackgroundKeeper {
  private var engine = BackgroundKeeper.makeEngine()
  private var observers: [NSObjectProtocol] = []

  private static func makeEngine() -> AVAudioEngine {
    let engine = AVAudioEngine()
    let silence = AVAudioSourceNode { _, _, _, audioBufferList in
      for buffer in UnsafeMutableAudioBufferListPointer(audioBufferList) {
        memset(buffer.mData, 0, Int(buffer.mDataByteSize))
      }
      return noErr
    }
    engine.attach(silence)
    engine.connect(silence, to: engine.mainMixerNode, format: nil)
    return engine
  }

  func start() throws {
    try activate()
    guard observers.isEmpty else { return }
    let center = NotificationCenter.default
    let session = AVAudioSession.sharedInstance()
    observers = [
      center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] notification in
        let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        guard rawType == AVAudioSession.InterruptionType.ended.rawValue else { return }
        self?.resume()
      },
      // The engine stops itself on route and sample-rate changes (e.g. Bluetooth, CarPlay).
      center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
        self?.resume()
      },
      // After a reset every audio object is invalid, so the engine has to be rebuilt.
      center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
        guard let self else { return }
        engine.stop()
        engine = Self.makeEngine()
        resume()
      },
    ]
  }

  /// Restarts playback if something stopped it. An interruption isn't guaranteed to report its end,
  /// so this is also called periodically and whenever the app becomes active.
  func resume() {
    guard !observers.isEmpty, !engine.isRunning else { return }
    try? activate()
  }

  func stop() {
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
    }
    observers = []
    engine.stop()
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  private func activate() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playback, options: .mixWithOthers)
    try session.setActive(true)
    try engine.start()
  }
}
