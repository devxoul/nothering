import AVFoundation
import Synchronization

/// Ambient noise played while the proxy runs.
enum FocusSound: String, CaseIterable, Identifiable {
  case off
  case white
  case pink
  case brown

  static let storageKey = "focusSound"

  static var saved: FocusSound {
    UserDefaults.standard.string(forKey: storageKey).flatMap(FocusSound.init(rawValue:)) ?? .off
  }

  var id: Self { self }

  var title: String {
    switch self {
    case .off: "Off"
    case .white: "White noise"
    case .pink: "Pink noise"
    case .brown: "Brown noise"
    }
  }
}

/// Keeps the app running in the background by playing the focus sound, or silence when it's off
/// (requires the `audio` background mode).
///
/// iOS suspends the app a few seconds after the engine stops, so every event that can stop it
/// (interruptions, route or configuration changes, media services resets) restarts it.
final class BackgroundKeeper {
  private let noise = NoiseGenerator(sound: FocusSound.saved)
  private lazy var engine = makeEngine()
  private var observers: [NSObjectProtocol] = []

  /// Takes effect immediately, even while playing.
  var sound: FocusSound {
    get { noise.sound }
    set { noise.sound = newValue }
  }

  private func makeEngine() -> AVAudioEngine {
    let engine = AVAudioEngine()
    let noise = noise
    // Mono, so every sample can be written to every channel buffer the same way.
    let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    let source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
      for buffer in UnsafeMutableAudioBufferListPointer(audioBufferList) {
        guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
        noise.render(into: UnsafeMutableBufferPointer(start: data, count: Int(frameCount)))
      }
      return noErr
    }
    engine.attach(source)
    engine.connect(source, to: engine.mainMixerNode, format: format)
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
        engine = makeEngine()
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

/// Generates noise on the audio render thread. The sound is atomic so the UI can change it while playing.
private final class NoiseGenerator: @unchecked Sendable {
  private let rawSound: Atomic<UInt8>
  /// Filter state, only touched on the render thread.
  private var pink: (Float, Float, Float, Float, Float, Float, Float) = (0, 0, 0, 0, 0, 0, 0)
  private var brown: Float = 0

  /// Kept low so the noise sits in the background instead of masking everything else.
  private static let gain: Float = 0.15
  private static let sounds = FocusSound.allCases

  init(sound: FocusSound) {
    rawSound = Atomic(UInt8(Self.sounds.firstIndex(of: sound)!))
  }

  var sound: FocusSound {
    get { Self.sounds[Int(rawSound.load(ordering: .relaxed))] }
    set { rawSound.store(UInt8(Self.sounds.firstIndex(of: newValue)!), ordering: .relaxed) }
  }

  func render(into samples: UnsafeMutableBufferPointer<Float>) {
    let sound = sound
    guard sound != .off else {
      samples.update(repeating: 0)
      return
    }
    for i in samples.indices {
      samples[i] = Self.gain * next(sound)
    }
  }

  private func next(_ sound: FocusSound) -> Float {
    let white = Float.random(in: -1...1)
    switch sound {
    case .off:
      return 0
    case .white:
      // Each sound is scaled to roughly the same loudness, so switching doesn't jump in volume.
      return white * 0.6
    case .pink:
      // Paul Kellet's refined pink noise filter.
      pink.0 = 0.99886 * pink.0 + white * 0.0555179
      pink.1 = 0.99332 * pink.1 + white * 0.0750759
      pink.2 = 0.96900 * pink.2 + white * 0.1538520
      pink.3 = 0.86650 * pink.3 + white * 0.3104856
      pink.4 = 0.55000 * pink.4 + white * 0.5329522
      pink.5 = -0.7616 * pink.5 - white * 0.0168980
      let value = pink.0 + pink.1 + pink.2 + pink.3 + pink.4 + pink.5 + pink.6 + white * 0.5362
      pink.6 = white * 0.115926
      return value * 0.19
    case .brown:
      // Leaky integration of white noise keeps the random walk from drifting out of range.
      brown = (brown + 0.02 * white) / 1.02
      return brown * 6
    }
  }
}
