import Foundation

/// Reference to a device that survives reconnects: UID first, name as fallback.
public struct DeviceRef: Codable, Hashable, Sendable {
    public var uid: String
    public var name: String

    public init(uid: String, name: String) {
        self.uid = uid
        self.name = name
    }

    public init(_ d: AudioDeviceInfo) {
        self.uid = d.uid
        self.name = d.name
    }

    /// Resolve against the current device list. Falls back to a unique name match
    /// (some devices change UID when re-plugged into a different port).
    public func resolve(in devices: [AudioDeviceInfo], needInput: Bool? = nil) -> AudioDeviceInfo? {
        func ok(_ d: AudioDeviceInfo) -> Bool {
            guard let needInput else { return true }
            return needInput ? d.hasInput : d.hasOutput
        }
        if let d = devices.first(where: { $0.uid == uid && ok($0) }) { return d }
        let byName = devices.filter { $0.name == name && ok($0) }
        return byName.count == 1 ? byName[0] : nil
    }
}

/// One connection inside a route's channel matrix (0-based channel indices).
public struct Crosspoint: Codable, Hashable, Sendable {
    public var input: Int
    public var output: Int
    public var gain: Float

    public init(input: Int, output: Int, gain: Float = 1.0) {
        self.input = input
        self.output = output
        self.gain = gain
    }
}

public struct Route: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var name: String
    public var enabled: Bool = true
    public var input: DeviceRef?
    public var output: DeviceRef?
    public var crosspoints: [Crosspoint] = []
    public var gainDB: Double = 0
    public var muted: Bool = false
    public var mutedOutputChannels: Set<Int> = []
    public var testTone: Bool = false

    public init(name: String, input: DeviceRef? = nil, output: DeviceRef? = nil, crosspoints: [Crosspoint] = []) {
        self.name = name
        self.input = input
        self.output = output
        self.crosspoints = crosspoints
    }

    public static let maxGainDB = 12.0
    public static let minGainDB = -60.0

    /// Linear gain applied to a crosspoint (route gain, mutes, crosspoint gain).
    public func effectiveGain(_ xp: Crosspoint) -> Float {
        if muted || mutedOutputChannels.contains(xp.output) { return 0 }
        let db = min(max(gainDB, Route.minGainDB), Route.maxGainDB)
        let g = db <= Route.minGainDB ? 0 : Float(pow(10.0, db / 20.0))
        return g * xp.gain
    }

    public var inputChannelsUsed: [Int] { Array(Set(crosspoints.map(\.input))).sorted() }
    public var outputChannelsUsed: [Int] { Array(Set(crosspoints.map(\.output))).sorted() }

    /// Sensible default mapping: pairwise identity for up to two channels; mono input -> both outputs.
    public static func defaultCrosspoints(inputChannels: Int, outputChannels: Int) -> [Crosspoint] {
        guard inputChannels > 0, outputChannels > 0 else { return [] }
        if inputChannels == 1 {
            return (0..<min(2, outputChannels)).map { Crosspoint(input: 0, output: $0) }
        }
        let n = min(2, inputChannels, outputChannels)
        if n == 1 { // stereo in -> mono out: sum at -6 dB each
            return [Crosspoint(input: 0, output: 0, gain: 0.5), Crosspoint(input: 1, output: 0, gain: 0.5)]
        }
        return (0..<n).map { Crosspoint(input: $0, output: $0) }
    }

    /// Structural identity: anything that requires rebuilding the audio graph when changed.
    public var structuralKey: String {
        let xps = crosspoints.map { "\($0.input)>\($0.output)" }.sorted().joined(separator: ",")
        return "\(id)|\(enabled)|\(input?.uid ?? "-")|\(output?.uid ?? "-")|\(xps)"
    }
}

public enum LatencyMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case low = "Low Latency"
    case balanced = "Balanced"
    case stable = "Stable"

    public var id: String { rawValue }

    /// Requested device IO buffer size.
    public var bufferFrames: Int {
        switch self { case .low: return 64; case .balanced: return 256; case .stable: return 512 }
    }

    /// Additional jitter margin in the bridge buffer.
    public var marginSeconds: Double {
        switch self { case .low: return 0.0015; case .balanced: return 0.004; case .stable: return 0.012 }
    }

    /// Resampler half filter length (only used when resampling is needed).
    public var halfTaps: Int {
        switch self { case .low: return 32; case .balanced: return 64; case .stable: return 64 }
    }

    public var summary: String {
        switch self {
        case .low: return "64-frame device buffers, 1.5 ms margin, shorter SRC filter"
        case .balanced: return "256-frame device buffers, 4 ms margin"
        case .stable: return "512-frame device buffers, 12 ms margin — most robust"
        }
    }
}

public struct EngineSettings: Codable, Hashable, Sendable {
    public var latencyMode: LatencyMode = .balanced
    /// Change device IO buffer sizes to match the latency mode.
    public var setDeviceBufferSize: Bool = true
    /// Try to switch the output device's sample rate to the input's (avoids SRC). Off by default:
    /// changing a device's rate affects every app using it.
    public var matchSampleRates: Bool = false
    /// Mute an output after >1.5 s of continuous full-scale signal (feedback guard).
    public var feedbackProtection: Bool = true

    public init() {}
}

public struct Preset: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var name: String
    public var routes: [Route]
    public var settings: EngineSettings

    public init(name: String, routes: [Route], settings: EngineSettings) {
        self.name = name
        self.routes = routes
        self.settings = settings
    }
}

/// Persisted application state.
public struct SavedState: Codable, Sendable {
    public var routes: [Route] = []
    public var settings: EngineSettings = EngineSettings()
    public var presets: [Preset] = []
    public var autoStart: Bool = false

    public init() {}
}

public enum Persistence {
    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("AudioRouterLite", isDirectory: true)
    }

    public static var stateURL: URL { directory.appendingPathComponent("state.json") }

    public static func load() -> SavedState {
        guard let data = try? Data(contentsOf: stateURL),
              let s = try? JSONDecoder().decode(SavedState.self, from: data) else { return SavedState() }
        return s
    }

    public static func save(_ state: SavedState) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(state).write(to: stateURL, options: .atomic)
        } catch {
            NSLog("AudioRouterLite: failed to save state: \(error)")
        }
    }
}
