import AVFoundation

/// Keeps the app running in the background by playing silence (requires the `audio` background mode).
final class BackgroundKeeper {
  private let engine = AVAudioEngine()
  private var interruptionObserver: NSObjectProtocol?

  init() {
    let silence = AVAudioSourceNode { _, _, _, audioBufferList in
      for buffer in UnsafeMutableAudioBufferListPointer(audioBufferList) {
        memset(buffer.mData, 0, Int(buffer.mDataByteSize))
      }
      return noErr
    }
    engine.attach(silence)
    engine.connect(silence, to: engine.mainMixerNode, format: nil)
  }

  func start() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playback, options: .mixWithOthers)
    try session.setActive(true)
    try engine.start()

    interruptionObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification, object: session, queue: .main
    ) { [weak self] notification in
      let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
      guard rawType == AVAudioSession.InterruptionType.ended.rawValue else { return }
      try? session.setActive(true)
      try? self?.engine.start()
    }
  }

  func stop() {
    if let interruptionObserver {
      NotificationCenter.default.removeObserver(interruptionObserver)
    }
    interruptionObserver = nil
    engine.stop()
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }
}
