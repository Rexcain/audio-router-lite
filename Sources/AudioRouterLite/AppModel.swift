import AppKit
import AudioRouterKit
import AVFoundation
import CoreAudio
import CRouterCore
import Foundation
import Observation

enum EngineState: Equatable {
    case stopped
    case starting
    case running
    case recovering(String)
    case error(String)

    var title: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .running: return "Running"
        case .recovering: return "Recovering"
        case .error: return "Error"
        }
    }

    var detail: String? {
        switch self {
        case .recovering(let s), .error(let s): return s
        default: return nil
        }
    }
}

struct RouteStatus {
    enum Kind: Equatable { case idle, running, waiting(String), error(String) }
    var kind: Kind = .idle
    var warnings: [String] = []
    var stats: ARBridgeStats?
    var health: RoutingEngine.IOHealth?
}

/// Per-route numbers that only exist while running.
struct RouteRuntimeSummary {
    var inRate: Double
    var outRate: Double
    var inBuffer: Int
    var outBuffer: Int
    var locked: Bool
    var resampling: Bool
    var inputDeviceLatency: Double
    var outputDeviceLatency: Double
    var inputDeviceID: AudioObjectID
    var outputDeviceID: AudioObjectID
}

struct LogEntry: Identifiable {
    enum Level { case info, warning, error }
    let id = UUID()
    let date = Date()
    let level: Level
    let message: String
}

/// Display meters (linear peak with decay); separate object so only meter views redraw at 30 Hz.
@Observable
final class MeterStore {
    var input: [AudioObjectID: [Float]] = [:]
    var output: [AudioObjectID: [Float]] = [:]
    var inputClip: [AudioObjectID: [Bool]] = [:]
    var outputClip: [AudioObjectID: [Bool]] = [:]

    func level(input: Bool, device: AudioObjectID?, channel: Int) -> Float {
        guard let device, let arr = (input ? self.input : output)[device], channel < arr.count else { return 0 }
        return arr[channel]
    }

    func clipped(input: Bool, device: AudioObjectID?, channel: Int) -> Bool {
        guard let device, let arr = (input ? inputClip : outputClip)[device], channel < arr.count else { return false }
        return arr[channel]
    }
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var devices: [AudioDeviceInfo] = []
    var routes: [Route] = [] { didSet { routesDidChange(from: oldValue) } }
    var settings = EngineSettings() { didSet { settingsDidChange(from: oldValue) } }
    var presets: [Preset] = [] { didSet { scheduleSave() } }
    var autoStart = false { didSet { scheduleSave() } }
    private(set) var state: EngineState = .stopped {
        didSet {
            if state != oldValue && SnapshotRunner.outputDir != nil {
                print("[state] \(state.title)\(state.detail.map { ": " + $0 } ?? "")"); fflush(stdout)
            }
        }
    }
    private(set) var routeStatus: [UUID: RouteStatus] = [:]
    private(set) var runtime: [UUID: RouteRuntimeSummary] = [:]
    private(set) var log: [LogEntry] = []
    private(set) var protectionTripped = false
    let meters = MeterStore()

    @ObservationIgnored private let engine = RoutingEngine()
    @ObservationIgnored private var watcher: DeviceWatcher?
    @ObservationIgnored private var meterTimer: Timer?
    @ObservationIgnored private var statusTimer: Timer?
    @ObservationIgnored private var retryTimer: Timer?
    @ObservationIgnored private(set) var wantRunning = false
    @ObservationIgnored private var runningSignature = ""
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var lastRestart = Date.distantPast
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var lastUnderruns: [UUID: (count: Int64, at: Date)] = [:]
    @ObservationIgnored private var loading = true
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        let saved = Persistence.load()
        routes = saved.routes
        settings = saved.settings
        presets = saved.presets
        autoStart = saved.autoStart
        devices = DeviceEnumerator.allDevices()
        loading = false
        watcher = DeviceWatcher { [weak self] in
            MainActor.assumeIsolated { self?.devicesChanged() }
        }
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.meterTick() }
        }
        RunLoop.main.add(t, forMode: .common)
        meterTimer = t
        let s = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.statusTick() }
        }
        RunLoop.main.add(s, forMode: .common)
        statusTimer = s

        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.willSleep() }
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        })
        if routes.isEmpty { addRoute() }
        addLog(.info, "Found \(devices.count) audio devices.")
        if autoStart { start() }
    }

    // MARK: - Devices

    var inputDevices: [AudioDeviceInfo] { devices.filter(\.hasInput) }
    var outputDevices: [AudioDeviceInfo] { devices.filter(\.hasOutput) }

    func device(for ref: DeviceRef?, input: Bool) -> AudioDeviceInfo? {
        ref?.resolve(in: devices, needInput: input)
    }

    func refreshDevices() {
        devices = DeviceEnumerator.allDevices()
    }

    private func devicesChanged() {
        let old = devices
        refreshDevices()
        let before = Set(old.map(\.uid)), after = Set(devices.map(\.uid))
        for d in devices where !before.contains(d.uid) { addLog(.info, "Device connected: \(d.name)") }
        for d in old where !after.contains(d.uid) { addLog(.warning, "Device disconnected: \(d.name)") }
        for d in devices {
            if let o = old.first(where: { $0.uid == d.uid }), o.nominalSampleRate != d.nominalSampleRate {
                addLog(.info, "\(d.name) sample rate changed: \(Int(o.nominalSampleRate)) → \(Int(d.nominalSampleRate)) Hz")
            }
        }
        reconcile(reason: "device change")
    }

    // MARK: - Routes

    func addRoute() {
        let input = inputDevices.first { !$0.isVirtual } ?? inputDevices.first
        let output = outputDevices.first { $0.id == DeviceEnumerator.defaultDevice(input: false) } ?? outputDevices.first
        var r = Route(name: "Route \(routes.count + 1)")
        if let input { r.input = DeviceRef(input) }
        if let output { r.output = DeviceRef(output) }
        r.crosspoints = Route.defaultCrosspoints(inputChannels: input?.inputChannels ?? 0, outputChannels: output?.outputChannels ?? 0)
        routes.append(r)
    }

    func duplicateRoute(_ id: UUID) {
        guard let r = routes.first(where: { $0.id == id }) else { return }
        var copy = r
        copy.id = UUID()
        copy.name = r.name + " copy"
        routes.append(copy)
    }

    func removeRoute(_ id: UUID) {
        routes.removeAll { $0.id == id }
    }

    private func routesDidChange(from old: [Route]) {
        guard !loading else { return }
        scheduleSave()
        let structural = old.map(\.structuralKey) != routes.map(\.structuralKey)
        if structural {
            reconcile(reason: "routing changed")
        } else {
            for r in routes { engine.applyLiveParameters(r) }
        }
    }

    private func settingsDidChange(from old: EngineSettings) {
        guard !loading else { return }
        scheduleSave()
        engine.setFeedbackProtection(settings.feedbackProtection)
        if old.latencyMode != settings.latencyMode || old.setDeviceBufferSize != settings.setDeviceBufferSize
            || old.matchSampleRates != settings.matchSampleRates {
            reconcile(reason: "settings changed")
        }
    }

    // MARK: - Presets

    func savePreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if let i = presets.firstIndex(where: { $0.name == trimmed }) {
            presets[i].routes = routes
            presets[i].settings = settings
        } else {
            presets.append(Preset(name: trimmed, routes: routes, settings: settings))
        }
        addLog(.info, "Saved preset “\(trimmed)”.")
    }

    func loadPreset(_ p: Preset) {
        loading = true
        settings = p.settings
        routes = p.routes
        loading = false
        scheduleSave()
        addLog(.info, "Loaded preset “\(p.name)”.")
        reconcile(reason: "preset loaded")
    }

    func deletePreset(_ p: Preset) {
        presets.removeAll { $0.id == p.id }
        addLog(.info, "Deleted preset “\(p.name)”.")
    }

    /// The preset whose routing and settings equal the current ones (nil if modified or none).
    var matchingPreset: Preset? {
        presets.first { $0.routes == routes && $0.settings == settings }
    }

    // MARK: - Engine control

    func toggle() { wantRunning ? stop() : start() }

    func start() {
        wantRunning = true
        let auth = AVCaptureDevice.authorizationStatus(for: .audio)
        addLog(.info, "Start requested (microphone permission: \(auth == .authorized ? "granted" : auth == .notDetermined ? "not yet asked" : "denied")).")
        switch auth {
        case .authorized:
            startEngine(reason: "start")
        case .notDetermined:
            state = .starting
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard self.wantRunning else { return }
                        if granted { self.startEngine(reason: "start") }
                        else { self.failPermission() }
                    }
                }
            }
        default:
            failPermission()
        }
    }

    private func failPermission() {
        wantRunning = false
        state = .error("Microphone access is denied. macOS requires it to read any audio input. Enable Audio Router Lite in System Settings → Privacy & Security → Microphone, then press Start again.")
        addLog(.error, "Microphone permission denied.")
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    func stop() {
        wantRunning = false
        retryTimer?.invalidate()
        retryTimer = nil
        engine.stop()
        runningSignature = ""
        state = .stopped
        routeStatus = [:]
        runtime = [:]
        protectionTripped = false
        meters.input = [:]
        meters.output = [:]
        addLog(.info, "Stopped.")
    }

    func resetCounters() {
        engine.resetCounters()
        lastUnderruns = [:]
    }

    func resetProtection() {
        engine.resetProtection()
        protectionTripped = false
        addLog(.info, "Output protection reset.")
    }

    /// Bring the running engine in line with the desired configuration.
    private func reconcile(reason: String) {
        guard wantRunning else { return }
        let sig = signature()
        if engine.isRunning && sig == runningSignature { return }
        // Rate-limit restarts to avoid thrashing during bursts of device notifications.
        let since = Date().timeIntervalSince(lastRestart)
        if since < 0.5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                MainActor.assumeIsolated { self?.reconcile(reason: reason) }
            }
            return
        }
        startEngine(reason: reason)
    }

    private func signature() -> String {
        var parts = ["\(settings.latencyMode.rawValue)|\(settings.setDeviceBufferSize)|\(settings.matchSampleRates)"]
        for r in routes where r.enabled {
            var p = r.structuralKey
            for (ref, isIn) in [(r.input, true), (r.output, false)] {
                if let d = ref?.resolve(in: devices, needInput: isIn) {
                    p += "|\(d.id):\(d.nominalSampleRate):\(d.inputChannels):\(d.outputChannels):\(d.bufferFrameSize):\(d.isAlive):\(d.isHoggedByOther)"
                } else {
                    p += "|missing"
                }
            }
            parts.append(p)
        }
        return parts.joined(separator: "\n")
    }

    private func startEngine(reason: String) {
        lastRestart = Date()
        let wasRunning = engine.isRunning
        if state == .stopped || { if case .error = state { return true } else { return false } }() { state = .starting }
        let result = engine.start(routes: routes, settings: settings)
        refreshDevices()
        runningSignature = signature()
        startedAt = Date()
        lastUnderruns = [:]
        protectionTripped = false

        var statuses: [UUID: RouteStatus] = [:]
        var waiting = false
        for r in routes where r.enabled {
            var st = RouteStatus()
            if result.runtimes[r.id] != nil {
                st.kind = .running
            } else if let e = result.routeErrors[r.id] {
                if e.contains("not connected") { st.kind = .waiting(e); waiting = true }
                else { st.kind = .error(e) }
            }
            st.warnings = staticWarnings(for: r)
            statuses[r.id] = st
        }
        routeStatus = statuses
        runtime = result.runtimes.mapValues {
            RouteRuntimeSummary(inRate: $0.inRate, outRate: $0.outRate, inBuffer: $0.inBufferFrames, outBuffer: $0.outBufferFrames,
                                locked: $0.lockedClocks, resampling: $0.needsResampling,
                                inputDeviceLatency: $0.inputDeviceLatency, outputDeviceLatency: $0.outputDeviceLatency,
                                inputDeviceID: $0.inputDevice.id, outputDeviceID: $0.outputDevice.id)
        }
        for note in result.notes { addLog(.info, note) }
        for (id, e) in result.routeErrors {
            let name = routes.first { $0.id == id }?.name ?? "route"
            addLog(.warning, "\(name): \(e)")
        }

        if result.runtimes.isEmpty {
            if waiting {
                state = .recovering("Waiting for a device to be connected…")
                scheduleRetry()
            } else if routes.allSatisfy({ !$0.enabled }) {
                state = .error("No enabled routes.")
            } else {
                state = .error(result.routeErrors.values.first ?? "Could not start any route.")
            }
            return
        }
        if waiting {
            state = .recovering("Some routes are waiting for their devices.")
            scheduleRetry()
        } else {
            state = .running
            retryTimer?.invalidate()
            retryTimer = nil
        }
        let n = result.runtimes.count
        addLog(.info, wasRunning ? "Restarted (\(reason)): \(n) route(s) running." : "Started: \(n) route(s) running.")
    }

    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.wantRunning else { return }
                self.refreshDevices()
                self.reconcile(reason: "retry")
            }
        }
        RunLoop.main.add(t, forMode: .common)
        retryTimer = t
    }

    // MARK: - Sleep / wake

    private func willSleep() {
        guard wantRunning else { return }
        engine.stop()
        runningSignature = ""
        state = .recovering("System is going to sleep.")
        addLog(.info, "Sleep: audio engine paused.")
    }

    private func didWake() {
        guard wantRunning else { return }
        state = .recovering("Waking up — waiting for devices…")
        addLog(.info, "Wake: restarting in 2 s.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.wantRunning else { return }
                self.refreshDevices()
                self.runningSignature = ""
                self.reconcile(reason: "wake")
            }
        }
    }

    // MARK: - Monitoring

    private func meterTick() {
        guard engine.isRunning else { return }
        let decay: Float = 0.92
        for id in engine.runningInputDevices {
            let peaks = engine.takeInputPeaks(device: id)
            var cur = meters.input[id] ?? []
            if cur.count != peaks.count { cur = [Float](repeating: 0, count: peaks.count) }
            var clip = meters.inputClip[id] ?? [Bool](repeating: false, count: peaks.count)
            if clip.count != peaks.count { clip = [Bool](repeating: false, count: peaks.count) }
            for i in peaks.indices {
                cur[i] = max(peaks[i], cur[i] * decay)
                if peaks[i] >= 0.999 { clip[i] = true }
            }
            meters.input[id] = cur
            meters.inputClip[id] = clip
        }
        for id in engine.runningOutputDevices {
            let peaks = engine.takeOutputPeaks(device: id)
            var cur = meters.output[id] ?? []
            if cur.count != peaks.count { cur = [Float](repeating: 0, count: peaks.count) }
            var clip = meters.outputClip[id] ?? [Bool](repeating: false, count: peaks.count)
            if clip.count != peaks.count { clip = [Bool](repeating: false, count: peaks.count) }
            for i in peaks.indices {
                cur[i] = max(peaks[i], cur[i] * decay)
                if peaks[i] >= 0.999 { clip[i] = true }
            }
            meters.output[id] = cur
            meters.outputClip[id] = clip
        }
    }

    func clearClipIndicators() {
        meters.inputClip = [:]
        meters.outputClip = [:]
    }

    private func statusTick() {
        guard engine.isRunning else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        var statuses = routeStatus
        var anyTripped = false
        for r in routes where r.enabled {
            guard var st = statuses[r.id], st.kind == .running else { continue }
            st.stats = engine.stats(for: r.id)
            st.health = engine.health(for: r.id)
            var w = staticWarnings(for: r)
            if let h = st.health {
                if elapsed > 2 && h.inputCallbacks == 0 {
                    w.append("No audio is arriving from the input device. It may be in use by another app, or input access was blocked.")
                }
                if elapsed > 2 && h.outputCallbacks == 0 {
                    w.append("The output device is not requesting audio. It may be in use exclusively by another app.")
                }
                if h.inputErrors > 0 { w.append("Input read errors: \(h.inputErrors) (last \(osStatusString(h.lastInputError))).") }
                if h.protectionTripped {
                    anyTripped = true
                    w.append("Output muted by feedback protection (sustained full-scale signal).")
                }
            }
            if let s = st.stats {
                let prev = lastUnderruns[r.id]
                if prev == nil || s.underruns < prev!.count { lastUnderruns[r.id] = (s.underruns, Date()) }
                else if s.underruns > prev!.count {
                    if Date().timeIntervalSince(prev!.at) < 10 && s.underruns - prev!.count >= 3 {
                        w.append("Frequent dropouts. Try the Stable latency mode.")
                    }
                    if Date().timeIntervalSince(prev!.at) > 10 { lastUnderruns[r.id] = (s.underruns, Date()) }
                }
            }
            st.warnings = w
            statuses[r.id] = st
        }
        routeStatus = statuses
        if anyTripped && !protectionTripped {
            addLog(.error, "Feedback protection muted an output after sustained clipping.")
        }
        protectionTripped = anyTripped
    }

    /// Configuration warnings that do not depend on runtime state.
    func staticWarnings(for r: Route) -> [String] {
        var w: [String] = []
        let inDev = device(for: r.input, input: true)
        let outDev = device(for: r.output, input: false)
        if let i = inDev, let o = outDev, i.id == o.id, i.isVirtual {
            w.append("Input and output are the same virtual device — this creates a feedback loop.")
        }
        if hasLoopbackCycle(through: r) {
            w.append("These routes form a loop through a virtual loopback device. This can cause feedback.")
        }
        if let o = outDev, o.isVirtualSink, routes.contains(where: { $0.id != r.id && $0.enabled && device(for: $0.output, input: false)?.isVirtualSink == false && $0.input?.uid == r.input?.uid }) {
            w.append("The same input also goes directly to another output. If the virtual device's software plays on that output too, you will hear it twice.")
        }
        return w
    }

    /// Detects a cycle in the device graph. Edges go route input → route output; a virtual device
    /// that has inputs (a loopback device) loops its output back to its input, so the signal continues from there.
    private func hasLoopbackCycle(through route: Route) -> Bool {
        var edges: [String: Set<String>] = [:]
        for r in routes where r.enabled {
            guard let i = device(for: r.input, input: true), let o = device(for: r.output, input: false) else { continue }
            edges[i.uid, default: []].insert(o.uid)
        }
        func isLoopback(_ uid: String) -> Bool {
            devices.first { $0.uid == uid }.map { $0.isVirtual && $0.hasInput && $0.hasOutput } ?? false
        }
        guard let start = device(for: route.input, input: true)?.uid else { return false }
        var visited: Set<String> = [start]
        var stack = [start]
        while let n = stack.popLast() {
            for next in edges[n] ?? [] where isLoopback(next) {
                if next == start { return true }
                if visited.insert(next).inserted { stack.append(next) }
            }
        }
        return false
    }

    // MARK: - Log & persistence

    func addLog(_ level: LogEntry.Level, _ message: String) {
        if SnapshotRunner.outputDir != nil { print("[log] \(message)"); fflush(stdout) }
        log.append(LogEntry(level: level, message: message))
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    private func scheduleSave() {
        guard !loading else { return }
        saveWork?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                var s = SavedState()
                s.routes = self.routes
                s.settings = self.settings
                s.presets = self.presets
                s.autoStart = self.autoStart
                Persistence.save(s)
            }
        }
        saveWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    func saveNow() {
        saveWork?.perform()
    }

    func shutdown() {
        saveNow()
        engine.stop()
    }

    func diagnosticsText() -> String {
        var out = "Audio Router Lite diagnostics — \(Date())\nState: \(state.title) \(state.detail ?? "")\n\nDevices:\n"
        for d in devices {
            out += "- \(d.name) [\(d.transport.rawValue)] uid=\(d.uid) in=\(d.inputChannels) out=\(d.outputChannels) rate=\(Int(d.nominalSampleRate)) buf=\(d.bufferFrameSize) clock=\(d.clockDomain) lat in/out=\(d.inputLatencyFrames)/\(d.outputLatencyFrames)\n"
        }
        out += "\nRoutes:\n"
        for r in routes {
            out += "- \(r.name) enabled=\(r.enabled) \(r.input?.name ?? "-") → \(r.output?.name ?? "-") xps=\(r.crosspoints.map { "\($0.input + 1)>\($0.output + 1)" }) gain=\(r.gainDB) dB muted=\(r.muted)\n"
            if let s = routeStatus[r.id]?.stats {
                out += String(format: "  fill=%.1f/%.1f corr=%+.2f ppm under=%lld over=%lld resync=%lld bypass=%d halfTaps=%d\n",
                              s.fillFrames, s.targetFillFrames, s.correctionPPM, s.underruns, s.overruns, s.resyncs, s.bypass, s.halfTaps)
            }
        }
        out += "\nLog:\n"
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        for e in log { out += "\(df.string(from: e.date)) \(e.message)\n" }
        return out
    }
}
