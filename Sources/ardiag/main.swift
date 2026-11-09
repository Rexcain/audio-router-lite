// ardiag — internal diagnostics for Audio Router Lite (not the product UI).
//
//   ardiag list
//   ardiag e2e --src "<loopback device 1>" --dst "<loopback device 2>" [--seconds 30] [--mode low|balanced|stable]
//
// e2e: plays a two-tone test signal (L 997 Hz, R 1499 Hz) into the *output* of --src, routes the
// *input* of --src to the output of --dst through the RoutingEngine, and records the input of --dst.
// This needs virtual loopback devices or a physical loopback cable.
import AudioRouterKit
import CRouterCore
import CoreAudio
import AudioToolbox
import Foundation

func arg(_ name: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
    return a[i + 1]
}

func findDevice(_ name: String, _ devices: [AudioDeviceInfo]) -> AudioDeviceInfo? {
    devices.first { $0.name == name || $0.uid == name } ?? devices.first { $0.name.localizedCaseInsensitiveContains(name) }
}

func list() {
    for d in DeviceEnumerator.allDevices() {
        print("\(d.name)  [\(d.transport.rawValue)]  uid=\(d.uid)")
        print("    in=\(d.inputChannels) out=\(d.outputChannels) rate=\(Int(d.nominalSampleRate)) rates=\(d.availableSampleRates.map { Int($0) }) buffer=\(d.bufferFrameSize) range=\(d.bufferFrameSizeRange.map { "\($0.lowerBound)-\($0.upperBound)" } ?? "?")")
        print("    clockDomain=\(d.clockDomain) latency in/out=\(d.inputLatencyFrames)/\(d.outputLatencyFrames) safety=\(d.inputSafetyOffset)/\(d.outputSafetyOffset) alive=\(d.isAlive) running=\(d.isRunningSomewhere) hog=\(d.hogModePID) virtualSink=\(d.isVirtualSink)")
    }
}

func e2e(externalRouter: Bool = false) -> Int32 {
    let devices = DeviceEnumerator.allDevices()
    guard let srcName = arg("--src"), let dstName = arg("--dst"),
          let src = findDevice(srcName, devices), let dst = findDevice(dstName, devices) else {
        print("usage: ardiag e2e --src <loopback device> --dst <loopback device> [--seconds N] [--mode low|balanced|stable]")
        return 2
    }
    let seconds = Double(arg("--seconds") ?? "20") ?? 20
    let mode: LatencyMode = { switch arg("--mode") { case "low": return .low; case "stable": return .stable; default: return .balanced } }()
    guard src.hasInput, src.hasOutput, dst.hasInput, dst.hasOutput, src.outputChannels >= 2, dst.inputChannels >= 2 else {
        print("Both devices must be loopback-capable (have inputs and outputs, ≥ 2 channels)."); return 2
    }
    print("Source: \(src.name) @ \(Int(src.nominalSampleRate)) Hz   Destination: \(dst.name) @ \(Int(dst.nominalSampleRate)) Hz   mode=\(mode.rawValue)")

    // 1. Tone generator into the source device's output.
    var freqs = [Double](repeating: 0, count: src.outputChannels)
    freqs[0] = 997; freqs[1] = 1499
    let tone = ar_tonegen_create(Int32(src.outputChannels), src.nominalSampleRate, freqs, 0.5)!
    let toneUnit: AudioUnit
    do {
        toneUnit = try HALUnit.make(device: src, input: false, channels: src.outputChannels,
                                    callback: ar_tonegen_callback_ptr(), refCon: UnsafeMutableRawPointer(tone))
    } catch { print("tone unit: \(error)"); return 1 }

    // 2. Router: src input 1/2 -> dst output 1/2.
    var settings = EngineSettings()
    settings.latencyMode = mode
    let route = Route(name: "e2e", input: DeviceRef(src), output: DeviceRef(dst),
                      crosspoints: [Crosspoint(input: 0, output: 0), Crosspoint(input: 1, output: 1)])
    let engine = RoutingEngine()

    // 3. Capture from the destination device's input.
    let capFrames = Int64((seconds + 2) * dst.nominalSampleRate)
    let cap = ar_capture_create(Int32(dst.inputChannels), 2, Int32(RoutingEngine.maxFrames), capFrames)!
    let capUnit: AudioUnit
    do {
        capUnit = try HALUnit.make(device: dst, input: true, channels: dst.inputChannels,
                                   callback: ar_capture_callback_ptr(), refCon: UnsafeMutableRawPointer(cap))
        ar_capture_set_unit(cap, capUnit)
    } catch { print("capture unit: \(error)"); return 1 }

    AudioOutputUnitStart(toneUnit)
    var inRate = src.nominalSampleRate
    if externalRouter {
        print("Probe mode: routing must be done by Audio Router Lite (\(src.name) In 1/2 → \(dst.name) Out 1/2).")
    } else {
        let res = engine.start(routes: [route], settings: settings)
        for (_, e) in res.routeErrors { print("route error: \(e)") }
        guard let rt = res.runtimes[route.id] else { print("engine did not start"); return 1 }
        inRate = rt.inRate
        print(String(format: "Route: %.0f → %.0f Hz, buffers in/out %d/%d, locked=%@, resampling=%@",
                     rt.inRate, rt.outRate, rt.inBufferFrames, rt.outBufferFrames, rt.lockedClocks ? "yes" : "no", rt.needsResampling ? "yes" : "no"))
    }
    AudioOutputUnitStart(capUnit)

    Thread.sleep(forTimeInterval: 1.5)
    ar_capture_arm(cap, 1)
    let t0 = Date()
    var lastPrint = 0.0
    while Date().timeIntervalSince(t0) < seconds {
        Thread.sleep(forTimeInterval: 0.25)
        let el = Date().timeIntervalSince(t0)
        if !externalRouter, el - lastPrint >= (arg("--trace") != nil ? 1 : 5), let s = engine.stats(for: route.id) {
            lastPrint = el
            print(String(format: "  t=%4.0fs fill=%.1f/%.1f frames corr=%+.2f ppm under=%lld over=%lld resync=%lld",
                         el, s.fillFrames, s.targetFillFrames, s.correctionPPM, s.underruns, s.overruns, s.resyncs))
        }
    }
    ar_capture_arm(cap, 0)
    let stats = engine.stats(for: route.id) ?? ARBridgeStats()
    let health = engine.health(for: route.id)
    engine.stop()
    HALUnit.dispose(capUnit)
    HALUnit.dispose(toneUnit)

    let n = Int(ar_capture_frames(cap))
    let rate = dst.nominalSampleRate
    let L = Array(UnsafeBufferPointer(start: ar_capture_channel(cap, 0), count: n))
    let R = Array(UnsafeBufferPointer(start: ar_capture_channel(cap, 1), count: n))
    ar_capture_destroy(cap)
    ar_tonegen_destroy(tone)

    print("\nCaptured \(n) frames (\(String(format: "%.1f", Double(n) / rate)) s) at \(Int(rate)) Hz")
    if let health {
        print("IO callbacks: input=\(health.inputCallbacks) output=\(health.outputCallbacks) errors in/out=\(health.inputErrors)/\(health.outputErrors) lastInputError=\(osStatusString(health.lastInputError))")
        print(String(format: "Bridge: underruns=%lld overruns=%lld resyncs=%lld final corr=%+.3f ppm target=%.0f frames (%.2f ms) halfTaps=%d bypass=%d",
                     stats.underruns, stats.overruns, stats.resyncs, stats.correctionPPM, stats.targetFillFrames,
                     stats.targetFillFrames / inRate * 1000, stats.halfTaps, stats.bypass))
    }
    let peak = max(L.map(abs).max() ?? 0, R.map(abs).max() ?? 0)
    if n < Int(rate) || peak < 1e-4 {
        print("FAIL: no signal captured (peak \(peak)). Is microphone access granted to this terminal app? Is another app using the devices?")
        return 1
    }
    let win = Int(rate * 0.1)
    let lRep = SignalAnalysis.windowed(L, start: 0, end: n, window: win, stride: win, sampleRate: rate, guessHz: 997, badThresholdDB: -80)
    let rRep = SignalAnalysis.windowed(R, start: 0, end: n, window: win, stride: win, sampleRate: rate, guessHz: 1499, badThresholdDB: -80)
    // Swap / crosstalk check: 1499 Hz on L, 997 Hz on R must be absent.
    // Remove the wanted tone first, otherwise its spectral leakage dominates the measurement.
    func residualAfter(_ x: [Float], hz: Double) -> [Float] {
        let cnt = min(x.count, Int(rate))
        let f = SignalAnalysis.fitSine(x, start: 0, count: cnt, sampleRate: rate, guessHz: hz, searchPPM: 50)
        return SignalAnalysis.subtractFit(x, start: 0, count: cnt, fit: f, sampleRate: rate)
    }
    let lRes = residualAfter(L, hz: 997), rRes = residualAfter(R, hz: 1499)
    let crossL = SignalAnalysis.fitSine(lRes, start: 0, count: lRes.count, sampleRate: rate, guessHz: 1499, searchPPM: 50)
    let crossR = SignalAnalysis.fitSine(rRes, start: 0, count: rRes.count, sampleRate: rate, guessHz: 997, searchPPM: 50)
    print("L (997 Hz):  \(lRep)")
    print("R (1499 Hz): \(rRep)")
    if !lRep.badPositions.isEmpty { print("  L bad windows at s:", lRep.badPositions.map { String(format: "%.1f", Double($0) / rate) }) }
    for pos in lRep.badPositions.prefix(6) {
        let f = SignalAnalysis.fitSine(L, start: pos, count: win, sampleRate: rate, guessHz: 997)
        let res = SignalAnalysis.subtractFit(L, start: pos, count: win, fit: f, sampleRate: rate)
        let mags = res.map { abs($0) }
        let iMax = mags.indices.max { mags[$0] < mags[$1] }!
        let sorted = mags.sorted()
        print(String(format: "  window %.2fs: THD+N %.1f dB, residual peak %.2e at +%d (%.4fs), median |res| %.2e, peak/RMS %.1f",
                     Double(pos) / rate, f.thdnDB, mags[iMax], iMax, Double(pos + iMax) / rate, sorted[sorted.count / 2], Double(mags[iMax]) / f.residualRMS))
    }
    if let path = arg("--dump") {
        let d = L.withUnsafeBufferPointer { Data(buffer: $0) }
        try? d.write(to: URL(fileURLWithPath: path))
        print("  dumped L channel (Float32 raw) to \(path)")
    }
    print(String(format: "Crosstalk / swap: 1499 Hz on L %.1f dBFS, 997 Hz on R %.1f dBFS", crossL.amplitudeDB, crossR.amplitudeDB))
    let pass = stats.underruns == 0 && stats.overruns == 0 && lRep.badWindows == 0 && rRep.badWindows == 0
        && abs(lRep.maxAmplitudeDB - (-6.0206)) < 0.05 && abs(rRep.maxAmplitudeDB - (-6.0206)) < 0.05
        && crossL.amplitudeDB < -90 && crossR.amplitudeDB < -90
    print(pass ? "\nRESULT: PASS" : "\nRESULT: FAIL")
    return pass ? 0 : 1
}

/// Simulates hot-plug: publishes an aggregate device (UID "ARLHotplugTest") wrapping --dev, removes it, re-creates it.
func hotplug() -> Int32 {
    let devices = DeviceEnumerator.allDevices()
    guard let name = arg("--dev"), let sub = findDevice(name, devices) else { print("usage: ardiag hotplug --dev <device> [--up 8] [--down 6] [--cycles 1]"); return 2 }
    let up = Double(arg("--up") ?? "8") ?? 8, down = Double(arg("--down") ?? "6") ?? 6
    let cycles = Int(arg("--cycles") ?? "1") ?? 1
    func create() -> AudioObjectID? {
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "ARL Hotplug Test",
            kAudioAggregateDeviceUIDKey: "ARLHotplugTest",
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: sub.uid]],
            kAudioAggregateDeviceMainSubDeviceKey: sub.uid,
        ]
        var id = AudioObjectID(0)
        let st = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &id)
        if st != noErr { print("create failed \(osStatusString(st))"); return nil }
        return id
    }
    guard var id = create() else { return 1 }
    print("[\(Date())] created ARL Hotplug Test (id \(id)) wrapping \(sub.name)")
    Thread.sleep(forTimeInterval: up)
    for c in 0..<cycles {
        AudioHardwareDestroyAggregateDevice(id)
        print("[\(Date())] REMOVED (cycle \(c + 1))")
        Thread.sleep(forTimeInterval: down)
        guard let n = create() else { return 1 }
        id = n
        print("[\(Date())] RE-ADDED (id \(id))")
        Thread.sleep(forTimeInterval: up)
    }
    AudioHardwareDestroyAggregateDevice(id)
    print("[\(Date())] removed, done")
    return 0
}

/// Records an input device for N seconds and prints peak / RMS per channel (dBFS). Shows what a source really delivers.
func level() -> Int32 {
    let devices = DeviceEnumerator.allDevices()
    guard let name = arg("--dev"), let d = devices.first(where: { ($0.name == name || $0.uid == name) && $0.hasInput })
            ?? devices.first(where: { $0.hasInput && $0.name.localizedCaseInsensitiveContains(name) }) else {
        print("usage: ardiag level --dev <input device> [--seconds 10]"); return 2
    }
    let seconds = Double(arg("--seconds") ?? "10") ?? 10
    let chans = d.inputChannels
    let cap = ar_capture_create(Int32(chans), Int32(chans), Int32(RoutingEngine.maxFrames), Int64((seconds + 1) * d.nominalSampleRate))!
    let unit: AudioUnit
    do {
        unit = try HALUnit.make(device: d, input: true, channels: chans, callback: ar_capture_callback_ptr(), refCon: UnsafeMutableRawPointer(cap))
        ar_capture_set_unit(cap, unit)
    } catch { print("capture unit: \(error)"); return 1 }
    print("Recording \(d.name) (\(chans) ch @ \(Int(d.nominalSampleRate)) Hz) for \(Int(seconds)) s — play something now…")
    AudioOutputUnitStart(unit)
    Thread.sleep(forTimeInterval: 0.3)
    ar_capture_arm(cap, 1)
    Thread.sleep(forTimeInterval: seconds)
    ar_capture_arm(cap, 0)
    HALUnit.dispose(unit)
    let n = Int(ar_capture_frames(cap))
    func db(_ x: Double) -> String { x > 0 ? String(format: "%6.1f dBFS", 20 * log10(x)) : "  -inf dBFS" }
    for c in 0..<chans {
        let x = UnsafeBufferPointer(start: ar_capture_channel(cap, Int32(c)), count: n)
        var peak = 0.0, sum = 0.0, loudest = 0.0
        let win = max(1, Int(d.nominalSampleRate * 0.4))
        var wsum = 0.0, wcount = 0
        for v in x {
            let a = Double(v); peak = max(peak, abs(a)); sum += a * a; wsum += a * a; wcount += 1
            if wcount == win { loudest = max(loudest, (wsum / Double(win)).squareRoot()); wsum = 0; wcount = 0 }
        }
        print("  In \(c + 1): peak \(db(peak))   RMS \(db(n > 0 ? (sum / Double(n)).squareRoot() : 0))   loudest 0.4 s RMS \(db(loudest))")
    }
    ar_capture_destroy(cap)
    return n > 0 ? 0 : 1
}

switch CommandLine.arguments.dropFirst().first {
case "list": list()
case "e2e": exit(e2e())
case "probe": exit(e2e(externalRouter: true))
case "hotplug": exit(hotplug())
case "level": exit(level())
case "setrate":
    guard let n = arg("--dev"), let d = findDevice(n, DeviceEnumerator.allDevices()), let r = Double(arg("--rate") ?? "") else {
        print("usage: ardiag setrate --dev <device> --rate <Hz>"); exit(2)
    }
    print(DeviceEnumerator.setSampleRate(d.id, r) ? "\(d.name): now \(Int(r)) Hz" : "\(d.name): could not set \(Int(r)) Hz")
default:
    print("usage: ardiag list | ardiag level --dev <input> | ardiag e2e|probe --src <device> --dst <device> [--seconds N] [--mode low|balanced|stable]")
}
