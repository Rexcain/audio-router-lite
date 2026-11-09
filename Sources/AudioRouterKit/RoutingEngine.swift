import AudioToolbox
import CoreAudio
import CRouterCore
import Foundation

/// Runtime information about a running route.
public struct RouteRuntime {
    public let routeID: UUID
    public let inputDevice: AudioDeviceInfo
    public let outputDevice: AudioDeviceInfo
    public let inRate: Double
    public let outRate: Double
    public let inBufferFrames: Int
    public let outBufferFrames: Int
    public let lockedClocks: Bool
    public let busChannels: [Int]
    public let xpoints: [(id: Int32, crosspoint: Crosspoint)]
    let bridge: OpaquePointer

    public var needsResampling: Bool { !(lockedClocks && inRate == outRate) }

    /// Capture side device latency: hardware + safety offset + one IO buffer (seconds).
    public var inputDeviceLatency: Double {
        Double(inputDevice.inputLatencyFrames + inputDevice.inputSafetyOffset + inBufferFrames) / inRate
    }

    /// Playback side device latency: hardware + safety offset + one IO buffer (seconds).
    public var outputDeviceLatency: Double {
        Double(outputDevice.outputLatencyFrames + outputDevice.outputSafetyOffset + outBufferFrames) / outRate
    }
}

public struct EngineStartResult {
    public var runtimes: [UUID: RouteRuntime] = [:]
    public var routeErrors: [UUID: String] = [:]
    public var notes: [String] = []
}

/// Builds and runs the audio graph: one AUHAL per input device, one per output device,
/// one bridge (ring + SRC + drift control) per route.
public final class RoutingEngine {
    public static let maxFrames = 8192

    final class InputSide {
        let device: AudioDeviceInfo
        let node: OpaquePointer
        var unit: AudioUnit?
        init(device: AudioDeviceInfo, node: OpaquePointer) { self.device = device; self.node = node }
    }

    final class OutputSide {
        let device: AudioDeviceInfo
        let node: OpaquePointer
        var unit: AudioUnit?
        init(device: AudioDeviceInfo, node: OpaquePointer) { self.device = device; self.node = node }
    }

    private var inputs: [AudioObjectID: InputSide] = [:]
    private var outputs: [AudioObjectID: OutputSide] = [:]
    private var bridges: [OpaquePointer] = []
    public private(set) var runtimes: [UUID: RouteRuntime] = [:]
    public private(set) var isRunning = false

    public init() {}

    deinit { stop() }

    // MARK: Start / Stop

    public func start(routes: [Route], settings: EngineSettings) -> EngineStartResult {
        stop()
        var result = EngineStartResult()
        var excluded = Set<UUID>()

        // Retry loop: if a device refuses to start, drop the routes using it and rebuild the rest.
        for _ in 0..<4 {
            let attempt = build(routes: routes.filter { !excluded.contains($0.id) }, settings: settings, result: &result)
            if let failedDevice = attempt {
                for r in routes where r.input?.uid == failedDevice.uid || r.output?.uid == failedDevice.uid {
                    excluded.insert(r.id)
                }
                stop()
                continue
            }
            break
        }
        return result
    }

    /// Returns the device that failed (if any) so the caller can retry without it.
    private func build(routes: [Route], settings: EngineSettings, result: inout EngineStartResult) -> AudioDeviceInfo? {
        var devices = DeviceEnumerator.allDevices()

        struct Plan { let route: Route; var input: AudioDeviceInfo; var output: AudioDeviceInfo; let xps: [Crosspoint] }
        var plans: [Plan] = []
        for route in routes where route.enabled {
            guard let inRef = route.input, let outRef = route.output else {
                result.routeErrors[route.id] = "Select an input and an output device."
                continue
            }
            guard let inDev = inRef.resolve(in: devices, needInput: true) else {
                result.routeErrors[route.id] = "Input device “\(inRef.name)” is not connected."
                continue
            }
            guard let outDev = outRef.resolve(in: devices, needInput: false) else {
                result.routeErrors[route.id] = "Output device “\(outRef.name)” is not connected."
                continue
            }
            if inDev.isHoggedByOther {
                result.routeErrors[route.id] = "“\(inDev.name)” is in exclusive use by another app (pid \(inDev.hogModePID))."
                continue
            }
            if outDev.isHoggedByOther {
                result.routeErrors[route.id] = "“\(outDev.name)” is in exclusive use by another app (pid \(outDev.hogModePID))."
                continue
            }
            let xps = route.crosspoints.filter {
                $0.input >= 0 && $0.input < inDev.inputChannels && $0.output >= 0 && $0.output < outDev.outputChannels
            }
            if xps.isEmpty {
                result.routeErrors[route.id] = "No valid channel mapping for these devices."
                continue
            }
            if Set(xps.map(\.input)).count > Int(AR_MAX_BUS_CHANNELS) {
                result.routeErrors[route.id] = "Too many input channels in one route (max \(AR_MAX_BUS_CHANNELS))."
                continue
            }
            plans.append(Plan(route: route, input: inDev, output: outDev, xps: xps))
        }
        guard !plans.isEmpty else { return nil }

        // Device configuration (buffer size, optional rate matching).
        let usedIDs = Set(plans.flatMap { [$0.input.id, $0.output.id] })
        if settings.setDeviceBufferSize {
            for id in usedIDs { DeviceEnumerator.setBufferFrameSize(id, settings.latencyMode.bufferFrames) }
        }
        if settings.matchSampleRates {
            for p in plans where p.input.nominalSampleRate != p.output.nominalSampleRate {
                if p.output.availableSampleRates.contains(p.input.nominalSampleRate),
                   DeviceEnumerator.setSampleRate(p.output.id, p.input.nominalSampleRate) {
                    result.notes.append("Set “\(p.output.name)” to \(Int(p.input.nominalSampleRate)) Hz to match “\(p.input.name)”.")
                } else {
                    result.notes.append("“\(p.output.name)” cannot run at \(Int(p.input.nominalSampleRate)) Hz; resampling.")
                }
            }
        }
        // Fresh snapshot after configuration.
        devices = DeviceEnumerator.allDevices()
        for i in plans.indices {
            if let d = devices.first(where: { $0.id == plans[i].input.id }) { plans[i].input = d }
            if let d = devices.first(where: { $0.id == plans[i].output.id }) { plans[i].output = d }
        }

        // Nodes.
        for p in plans {
            if inputs[p.input.id] == nil {
                guard let node = ar_input_create(Int32(p.input.inputChannels), Int32(Self.maxFrames)) else {
                    result.routeErrors[p.route.id] = "Could not allocate input node."
                    continue
                }
                inputs[p.input.id] = InputSide(device: p.input, node: node)
            }
            if outputs[p.output.id] == nil {
                guard let node = ar_output_create(Int32(p.output.outputChannels), Int32(Self.maxFrames), p.output.nominalSampleRate) else {
                    result.routeErrors[p.route.id] = "Could not allocate output node."
                    continue
                }
                ar_output_set_protection(node, settings.feedbackProtection ? 1 : 0)
                outputs[p.output.id] = OutputSide(device: p.output, node: node)
            }
        }

        // Bridges.
        for p in plans {
            guard let inSide = inputs[p.input.id], let outSide = outputs[p.output.id] else { continue }
            let bus = Array(Set(p.xps.map(\.input))).sorted()
            let locked = p.input.id == p.output.id || (p.input.clockDomain != 0 && p.input.clockDomain == p.output.clockDomain)
            var cfg = ARBridgeConfig()
            cfg.busChannels = Int32(bus.count)
            cfg.inRate = p.input.nominalSampleRate
            cfg.outRate = p.output.nominalSampleRate
            cfg.inMaxFrames = Int32(Self.maxFrames)
            cfg.outMaxFrames = Int32(Self.maxFrames)
            cfg.inBufferFrames = Int32(max(p.input.bufferFrameSize, 1))
            cfg.outBufferFrames = Int32(max(p.output.bufferFrameSize, 1))
            cfg.halfTaps = Int32(settings.latencyMode.halfTaps)
            cfg.lockedClocks = locked ? 1 : 0
            cfg.marginSeconds = settings.latencyMode.marginSeconds
            cfg.maxCorrectionPPM = 2000
            let src = bus.map { Int32($0) }
            guard let bridge = src.withUnsafeBufferPointer({ ar_bridge_create(&cfg, $0.baseAddress) }) else {
                result.routeErrors[p.route.id] = "Could not create bridge (sample rate \(cfg.inRate) → \(cfg.outRate))."
                continue
            }
            bridges.append(bridge)
            ar_bridge_set_test_tone(bridge, p.route.testTone ? 1 : 0)
            ar_input_add_bridge(inSide.node, bridge)
            let slot = ar_output_add_bridge(outSide.node, bridge, Int32(bus.count))
            var xpIDs: [(Int32, Crosspoint)] = []
            for xp in p.xps {
                guard let b = bus.firstIndex(of: xp.input) else { continue }
                let id = ar_output_add_xpoint(outSide.node, slot, Int32(b), Int32(xp.output), p.route.effectiveGain(xp))
                if id >= 0 { xpIDs.append((id, xp)) }
            }
            runtimes[p.route.id] = RouteRuntime(
                routeID: p.route.id, inputDevice: p.input, outputDevice: p.output,
                inRate: cfg.inRate, outRate: cfg.outRate,
                inBufferFrames: Int(cfg.inBufferFrames), outBufferFrames: Int(cfg.outBufferFrames),
                lockedClocks: locked, busChannels: bus, xpoints: xpIDs, bridge: bridge)
        }

        // Audio units.
        do {
            for side in outputs.values {
                side.unit = try makeUnit(device: side.device, input: false, channels: side.device.outputChannels,
                                         rate: side.device.nominalSampleRate,
                                         callback: ar_output_callback_ptr(), refCon: UnsafeMutableRawPointer(side.node))
            }
            for side in inputs.values {
                let unit = try makeUnit(device: side.device, input: true, channels: side.device.inputChannels,
                                        rate: side.device.nominalSampleRate,
                                        callback: ar_input_callback_ptr(), refCon: UnsafeMutableRawPointer(side.node))
                side.unit = unit
                ar_input_set_unit(side.node, unit)
            }
        } catch let e as UnitError {
            for (id, rt) in runtimes where rt.inputDevice.id == e.device.id || rt.outputDevice.id == e.device.id {
                result.routeErrors[id] = "“\(e.device.name)”: \(e.message)"
            }
            return e.device
        } catch {
            return nil
        }

        for side in inputs.values {
            guard let u = side.unit else { continue }
            let st = AudioOutputUnitStart(u)
            if st != noErr {
                for (id, rt) in runtimes where rt.inputDevice.id == side.device.id {
                    result.routeErrors[id] = "Could not start input “\(side.device.name)” (\(osStatusString(st)))."
                }
                return side.device
            }
        }
        for side in outputs.values {
            guard let u = side.unit else { continue }
            let st = AudioOutputUnitStart(u)
            if st != noErr {
                for (id, rt) in runtimes where rt.outputDevice.id == side.device.id {
                    result.routeErrors[id] = "Could not start output “\(side.device.name)” (\(osStatusString(st)))."
                }
                return side.device
            }
        }
        isRunning = true
        result.runtimes = runtimes
        return nil
    }

    public func stop() {
        for side in inputs.values { if let u = side.unit { AudioOutputUnitStop(u) } }
        for side in outputs.values { if let u = side.unit { AudioOutputUnitStop(u) } }
        for side in inputs.values {
            if let u = side.unit { AudioUnitUninitialize(u); AudioComponentInstanceDispose(u) }
            side.unit = nil
            ar_input_destroy(side.node)
        }
        for side in outputs.values {
            if let u = side.unit { AudioUnitUninitialize(u); AudioComponentInstanceDispose(u) }
            side.unit = nil
            ar_output_destroy(side.node)
        }
        for b in bridges { ar_bridge_destroy(b) }
        inputs.removeAll()
        outputs.removeAll()
        bridges.removeAll()
        runtimes.removeAll()
        isRunning = false
    }

    // MARK: Live control

    /// Push gain/mute/test-tone changes (no graph rebuild).
    public func applyLiveParameters(_ route: Route) {
        guard let rt = runtimes[route.id], let out = outputs[rt.outputDevice.id] else { return }
        for (id, xp) in rt.xpoints {
            let g = route.crosspoints.first(where: { $0.input == xp.input && $0.output == xp.output }).map(route.effectiveGain) ?? 0
            ar_output_set_xpoint_gain(out.node, id, g)
        }
        ar_bridge_set_test_tone(rt.bridge, route.testTone ? 1 : 0)
    }

    public func setFeedbackProtection(_ enabled: Bool) {
        for o in outputs.values { ar_output_set_protection(o.node, enabled ? 1 : 0) }
    }

    // MARK: Monitoring

    public func stats(for route: UUID) -> ARBridgeStats? {
        guard let rt = runtimes[route] else { return nil }
        var s = ARBridgeStats()
        ar_bridge_get_stats(rt.bridge, &s)
        return s
    }

    public func resetCounters() {
        for b in bridges { ar_bridge_reset_counters(b) }
    }

    /// Read-and-reset peaks for all channels of an input device.
    public func takeInputPeaks(device: AudioObjectID) -> [Float] {
        guard let s = inputs[device] else { return [] }
        return (0..<s.device.inputChannels).map { ar_input_take_peak(s.node, Int32($0)) }
    }

    public func takeOutputPeaks(device: AudioObjectID) -> [Float] {
        guard let s = outputs[device] else { return [] }
        return (0..<s.device.outputChannels).map { ar_output_take_peak(s.node, Int32($0)) }
    }

    public var runningInputDevices: [AudioObjectID] { Array(inputs.keys) }
    public var runningOutputDevices: [AudioObjectID] { Array(outputs.keys) }

    public struct IOHealth: Sendable {
        public var inputCallbacks: Int64
        public var outputCallbacks: Int64
        public var inputErrors: Int64
        public var outputErrors: Int64
        public var lastInputError: OSStatus
        public var protectionTripped: Bool
        public var nanEvents: Int64
    }

    public func health(for route: UUID) -> IOHealth? {
        guard let rt = runtimes[route], let i = inputs[rt.inputDevice.id], let o = outputs[rt.outputDevice.id] else { return nil }
        return IOHealth(inputCallbacks: ar_input_callback_count(i.node), outputCallbacks: ar_output_callback_count(o.node),
                        inputErrors: ar_input_error_count(i.node), outputErrors: ar_output_error_count(o.node),
                        lastInputError: ar_input_last_error(i.node),
                        protectionTripped: ar_output_protection_tripped(o.node) != 0,
                        nanEvents: ar_output_nan_count(o.node))
    }

    public func resetProtection() {
        for o in outputs.values { ar_output_reset_protection(o.node) }
    }

    // MARK: AUHAL

    struct UnitError: Error {
        let device: AudioDeviceInfo
        let message: String
    }

    private func makeUnit(device: AudioDeviceInfo, input: Bool, channels: Int, rate: Double,
                          callback: AURenderCallback, refCon: UnsafeMutableRawPointer) throws -> AudioUnit {
        func fail(_ st: OSStatus, _ what: String) -> UnitError {
            UnitError(device: device, message: "\(what) failed (\(osStatusString(st)))")
        }
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw UnitError(device: device, message: "AUHAL component not found")
        }
        var unitOpt: AudioUnit?
        var st = AudioComponentInstanceNew(comp, &unitOpt)
        guard st == noErr, let unit = unitOpt else { throw fail(st, "Creating audio unit") }
        var ok = false
        defer { if !ok { AudioComponentInstanceDispose(unit) } }

        let u32 = UInt32(MemoryLayout<UInt32>.size)
        if input {
            var one: UInt32 = 1, zero: UInt32 = 0
            st = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, u32)
            if st != noErr { throw fail(st, "Enabling input") }
            st = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, u32)
            if st != noErr { throw fail(st, "Disabling output") }
        }
        var dev = device.id
        st = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                  &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        if st != noErr { throw fail(st, "Selecting device") }

        var asbd = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagsNativeEndian,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        let asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        if input {
            st = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &asbd, asbdSize)
        } else {
            st = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &asbd, asbdSize)
        }
        if st != noErr { throw fail(st, "Setting Float32 \(Int(rate)) Hz × \(channels) format") }

        var maxFrames = UInt32(Self.maxFrames)
        AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, u32)

        var cb = AURenderCallbackStruct(inputProc: callback, inputProcRefCon: refCon)
        let cbSize = UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        if input {
            st = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb, cbSize)
        } else {
            st = AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, cbSize)
        }
        if st != noErr { throw fail(st, "Installing callback") }

        st = AudioUnitInitialize(unit)
        if st != noErr { throw fail(st, "Initializing audio unit") }
        ok = true
        return unit
    }
}

/// Minimal standalone AUHAL helpers for diagnostics (tone generator / capture).
public enum HALUnit {
    public static func make(device: AudioDeviceInfo, input: Bool, channels: Int,
                            callback: AURenderCallback, refCon: UnsafeMutableRawPointer) throws -> AudioUnit {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw CoreAudioError(-1, "AUHAL not found") }
        var unitOpt: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &unitOpt), "AudioComponentInstanceNew")
        let unit = unitOpt!
        let u32 = UInt32(MemoryLayout<UInt32>.size)
        if input {
            var one: UInt32 = 1, zero: UInt32 = 0
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, u32), "EnableIO in")
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, u32), "EnableIO out")
        }
        var dev = device.id
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, u32), "CurrentDevice")
        var asbd = AudioStreamBasicDescription(
            mSampleRate: device.nominalSampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagsNativeEndian,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        let sz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, input ? kAudioUnitScope_Output : kAudioUnitScope_Input,
                                       input ? 1 : 0, &asbd, sz), "StreamFormat")
        var maxFrames = UInt32(RoutingEngine.maxFrames)
        AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, u32)
        var cb = AURenderCallbackStruct(inputProc: callback, inputProcRefCon: refCon)
        try check(AudioUnitSetProperty(unit, input ? kAudioOutputUnitProperty_SetInputCallback : kAudioUnitProperty_SetRenderCallback,
                                       input ? kAudioUnitScope_Global : kAudioUnitScope_Input, 0, &cb,
                                       UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "Callback")
        try check(AudioUnitInitialize(unit), "AudioUnitInitialize")
        return unit
    }

    public static func dispose(_ unit: AudioUnit) {
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }
}
