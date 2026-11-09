import CoreAudio
import Foundation

public enum TransportKind: String, Codable, Sendable {
    case builtIn = "Built-in", usb = "USB", virtual = "Virtual", aggregate = "Aggregate", bluetooth = "Bluetooth"
    case hdmi = "HDMI", displayPort = "DisplayPort", thunderbolt = "Thunderbolt", pci = "PCI", firewire = "FireWire"
    case airplay = "AirPlay", avb = "AVB", continuity = "Continuity", unknown = "Other"

    init(_ t: UInt32) {
        switch t {
        case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
        case kAudioDeviceTransportTypeUSB: self = .usb
        case kAudioDeviceTransportTypeVirtual: self = .virtual
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: self = .aggregate
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: self = .bluetooth
        case kAudioDeviceTransportTypeHDMI: self = .hdmi
        case kAudioDeviceTransportTypeDisplayPort: self = .displayPort
        case kAudioDeviceTransportTypeThunderbolt: self = .thunderbolt
        case kAudioDeviceTransportTypePCI: self = .pci
        case kAudioDeviceTransportTypeFireWire: self = .firewire
        case kAudioDeviceTransportTypeAirPlay: self = .airplay
        case kAudioDeviceTransportTypeAVB: self = .avb
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless: self = .continuity
        default: self = .unknown
        }
    }
}

/// Snapshot of a Core Audio device's properties.
public struct AudioDeviceInfo: Identifiable, Hashable, Sendable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let manufacturer: String
    public let transport: TransportKind
    public let inputChannels: Int
    public let outputChannels: Int
    public let inputChannelNames: [String]
    public let outputChannelNames: [String]
    public let nominalSampleRate: Double
    public let availableSampleRates: [Double]
    public let bufferFrameSize: Int
    public let bufferFrameSizeRange: ClosedRange<Int>?
    public let isAlive: Bool
    public let isRunningSomewhere: Bool
    public let hogModePID: pid_t
    public let clockDomain: UInt32
    public let inputLatencyFrames: Int    // device + stream latency
    public let outputLatencyFrames: Int
    public let inputSafetyOffset: Int
    public let outputSafetyOffset: Int

    public var hasInput: Bool { inputChannels > 0 }
    public var hasOutput: Bool { outputChannels > 0 }
    public var isVirtual: Bool { transport == .virtual }

    /// A virtual output-only device: audio sent to it is handed to the software that created it,
    /// which decides where it finally plays.
    /// Loopback-style virtual devices have inputs as well and are not included.
    public var isVirtualSink: Bool { isVirtual && hasOutput && !hasInput }

    /// Hogged (exclusive) by another process.
    public var isHoggedByOther: Bool { hogModePID != -1 && hogModePID != getpid() }

    public func channelName(_ index: Int, input: Bool) -> String {
        let names = input ? inputChannelNames : outputChannelNames
        let prefix = input ? "In" : "Out"
        if index < names.count, !names[index].isEmpty { return "\(index + 1): \(names[index])" }
        return "\(prefix) \(index + 1)"
    }
}

public enum DeviceEnumerator {
    public static func allDeviceIDs() -> [AudioObjectID] {
        getArray(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDevices), AudioObjectID(0))
    }

    public static func allDevices() -> [AudioDeviceInfo] {
        allDeviceIDs().compactMap { info(for: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func info(for id: AudioObjectID) -> AudioDeviceInfo? {
        guard let uid = getString(id, address(kAudioDevicePropertyDeviceUID)) else { return nil }
        let name = getString(id, address(kAudioObjectPropertyName)) ?? "Unknown Device"
        let manufacturer = getString(id, address(kAudioObjectPropertyManufacturer)) ?? ""
        let transport = TransportKind(getScalar(id, address(kAudioDevicePropertyTransportType), UInt32(0)) ?? 0)
        let inCh = channelCount(id, kAudioObjectPropertyScopeInput)
        let outCh = channelCount(id, kAudioObjectPropertyScopeOutput)
        if inCh == 0 && outCh == 0 { return nil }
        let rate = getScalar(id, address(kAudioDevicePropertyNominalSampleRate), Float64(0)) ?? 0
        let ranges = getArray(id, address(kAudioDevicePropertyAvailableNominalSampleRates),
                              AudioValueRange(mMinimum: 0, mMaximum: 0))
        let buf = Int(getScalar(id, address(kAudioDevicePropertyBufferFrameSize), UInt32(0)) ?? 0)
        let bufRange = getScalar(id, address(kAudioDevicePropertyBufferFrameSizeRange), AudioValueRange(mMinimum: 0, mMaximum: 0))
        let alive = (getScalar(id, address(kAudioDevicePropertyDeviceIsAlive), UInt32(1)) ?? 1) != 0
        let running = (getScalar(id, address(kAudioDevicePropertyDeviceIsRunningSomewhere), UInt32(0)) ?? 0) != 0
        let hog = getScalar(id, address(kAudioDevicePropertyHogMode), pid_t(-1)) ?? -1
        let clock = getScalar(id, address(kAudioDevicePropertyClockDomain), UInt32(0)) ?? 0

        return AudioDeviceInfo(
            id: id, uid: uid, name: name, manufacturer: manufacturer, transport: transport,
            inputChannels: inCh, outputChannels: outCh,
            inputChannelNames: channelNames(id, kAudioObjectPropertyScopeInput, inCh),
            outputChannelNames: channelNames(id, kAudioObjectPropertyScopeOutput, outCh),
            nominalSampleRate: rate,
            availableSampleRates: expandRates(ranges),
            bufferFrameSize: buf,
            bufferFrameSizeRange: bufRange.map { Int($0.mMinimum)...max(Int($0.mMinimum), Int($0.mMaximum)) },
            isAlive: alive, isRunningSomewhere: running, hogModePID: hog, clockDomain: clock,
            inputLatencyFrames: inCh > 0 ? latency(id, kAudioObjectPropertyScopeInput) : 0,
            outputLatencyFrames: outCh > 0 ? latency(id, kAudioObjectPropertyScopeOutput) : 0,
            inputSafetyOffset: inCh > 0 ? Int(getScalar(id, address(kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeInput), UInt32(0)) ?? 0) : 0,
            outputSafetyOffset: outCh > 0 ? Int(getScalar(id, address(kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput), UInt32(0)) ?? 0) : 0
        )
    }

    static let standardRates: [Double] = [8000, 11025, 16000, 22050, 32000, 44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000]

    static func expandRates(_ ranges: [AudioValueRange]) -> [Double] {
        var out = Set<Double>()
        for r in ranges {
            if r.mMinimum == r.mMaximum { out.insert(r.mMinimum) }
            else { for s in standardRates where s >= r.mMinimum && s <= r.mMaximum { out.insert(s) } }
        }
        return out.sorted()
    }

    static func channelNames(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope, _ count: Int) -> [String] {
        guard count > 0, count <= 64 else { return [] }
        return (0..<count).map { ch in
            getString(id, address(kAudioObjectPropertyElementName, scope, AudioObjectPropertyElement(ch + 1))) ?? ""
        }
    }

    static func latency(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        let dev = Int(getScalar(id, address(kAudioDevicePropertyLatency, scope), UInt32(0)) ?? 0)
        let streams = getArray(id, address(kAudioDevicePropertyStreams, scope), AudioStreamID(0))
        let streamLat = streams.first.flatMap { getScalar($0, address(kAudioStreamPropertyLatency), UInt32(0)) }.map(Int.init) ?? 0
        return dev + streamLat
    }

    public static func defaultDevice(input: Bool) -> AudioObjectID? {
        getScalar(AudioObjectID(kAudioObjectSystemObject),
                  address(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice),
                  AudioObjectID(0))
    }

    /// Request a nominal sample rate and wait (briefly) for the device to apply it.
    @discardableResult
    public static func setSampleRate(_ id: AudioObjectID, _ rate: Double, timeout: TimeInterval = 1.5) -> Bool {
        let addr = address(kAudioDevicePropertyNominalSampleRate)
        if let cur = getScalar(id, addr, Float64(0)), cur == rate { return true }
        guard setScalar(id, addr, Float64(rate)) == noErr else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let cur = getScalar(id, addr, Float64(0)), cur == rate { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }

    /// Request an IO buffer size (clamped to the device range). Returns the size in effect.
    @discardableResult
    public static func setBufferFrameSize(_ id: AudioObjectID, _ frames: Int) -> Int {
        var f = frames
        if let r = getScalar(id, address(kAudioDevicePropertyBufferFrameSizeRange), AudioValueRange(mMinimum: 0, mMaximum: 0)),
           r.mMaximum > 0 {
            f = min(max(f, Int(r.mMinimum)), Int(r.mMaximum))
        }
        _ = setScalar(id, address(kAudioDevicePropertyBufferFrameSize), UInt32(f))
        return Int(getScalar(id, address(kAudioDevicePropertyBufferFrameSize), UInt32(0)) ?? UInt32(f))
    }
}

/// Watches the system device list and per-device properties; calls `onChange` (main queue, debounced).
public final class DeviceWatcher {
    private var onChange: () -> Void
    private var systemListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var deviceListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var pending: DispatchWorkItem?

    public init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        let sys = AudioObjectID(kAudioObjectSystemObject)
        for sel in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice] {
            var addr = address(sel)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.schedule() }
            if AudioObjectAddPropertyListenerBlock(sys, &addr, DispatchQueue.main, block) == noErr {
                systemListeners.append((addr, block))
            }
        }
        rewatchDevices()
    }

    deinit {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        for (a, b) in systemListeners { var addr = a; AudioObjectRemovePropertyListenerBlock(sys, &addr, DispatchQueue.main, b) }
        removeDeviceListeners()
    }

    private func removeDeviceListeners() {
        for (id, a, b) in deviceListeners { var addr = a; AudioObjectRemovePropertyListenerBlock(id, &addr, DispatchQueue.main, b) }
        deviceListeners.removeAll()
    }

    /// Re-register per-device listeners for the current device list.
    public func rewatchDevices() {
        removeDeviceListeners()
        let selectors: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
            (kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput),
            (kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput),
            (kAudioDevicePropertyHogMode, kAudioObjectPropertyScopeGlobal),
        ]
        for id in DeviceEnumerator.allDeviceIDs() {
            for (sel, scope) in selectors {
                var addr = address(sel, scope)
                guard AudioObjectHasProperty(id, &addr) else { continue }
                let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.schedule() }
                if AudioObjectAddPropertyListenerBlock(id, &addr, DispatchQueue.main, block) == noErr {
                    deviceListeners.append((id, addr, block))
                }
            }
        }
    }

    private func schedule() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.rewatchDevices()
            self.onChange()
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }
}
