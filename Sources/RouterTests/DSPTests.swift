import AudioRouterKit
import CRouterCore
import Foundation

// MARK: - Helpers

func resampleOffline(_ x: [Float], inRate: Double, outRate: Double, halfTaps: Int = 64) -> [Float] {
    let step = inRate / outRate
    let outCount = Int(Double(x.count) / step)
    var out = [Float](repeating: 0, count: outCount)
    x.withUnsafeBufferPointer { inb in
        out.withUnsafeMutableBufferPointer { ob in
            var ip: UnsafePointer<Float>? = inb.baseAddress
            var op: UnsafeMutablePointer<Float>? = ob.baseAddress
            withUnsafePointer(to: &ip) { ipp in
                withUnsafePointer(to: &op) { opp in
                    _ = ar_resample_offline(1, step, Int32(halfTaps), ipp, Int64(x.count), opp, Int64(outCount))
                }
            }
        }
    }
    return out
}

/// Measures a tone after SRC, skipping filter edges.
func measureSRC(freq: Double, inRate: Double, outRate: Double, amplitude: Double = 0.5, halfTaps: Int = 64) -> SignalAnalysis.SineFit {
    let n = Int(inRate * 1.5)
    let x = SignalAnalysis.sine(frequency: freq, sampleRate: inRate, count: n, amplitude: amplitude)
    let y = resampleOffline(x, inRate: inRate, outRate: outRate, halfTaps: halfTaps)
    let start = Int(outRate * 0.2)
    let count = Int(outRate * 1.0)
    return SignalAnalysis.fitSine(y, start: start, count: count, sampleRate: outRate, guessHz: freq, searchPPM: 20)
}

// MARK: - Sample-rate conversion quality

// Suite: Sample rate conversion
struct SRCTests {
    // Test: 44.1 kHz → 48 kHz, 997 Hz, -6 dBFS
    func up() {
        let f = measureSRC(freq: 997, inRate: 44100, outRate: 48000)
        print("[measure] 44.1k→48k 997 Hz: \(f)")
        expect(abs(f.frequency - 997) < 0.001)
        expect(abs(f.amplitudeDB - 20 * log10(0.5)) < 0.001)
        expect(f.thdnDB < -110)
    }

    // Test: 48 kHz → 44.1 kHz, 997 Hz, -6 dBFS
    func down() {
        let f = measureSRC(freq: 997, inRate: 48000, outRate: 44100)
        print("[measure] 48k→44.1k 997 Hz: \(f)")
        expect(abs(f.frequency - 997) < 0.001)
        expect(abs(f.amplitudeDB - 20 * log10(0.5)) < 0.001)
        expect(f.thdnDB < -110)
    }

    // Test (parameterized): Low-latency filter (32 half taps) quality
    func lowLatencyFilter(rates: (Double, Double)) {
        let f = measureSRC(freq: 997, inRate: rates.0, outRate: rates.1, halfTaps: 32)
        print("[measure] halfTaps=32 \(Int(rates.0))→\(Int(rates.1)) 997 Hz: \(f)")
        expect(f.thdnDB < -95)
    }

    // Test (parameterized): Frequency response 20 Hz – 20 kHz
    func frequencyResponse(rates: (Double, Double)) {
        let freqs: [Double] = [20, 100, 1000, 5000, 10000, 15000, 18000, 19000, 20000]
        var worstToTen = 0.0
        var line = "[measure] FR \(Int(rates.0))→\(Int(rates.1)):"
        for fr in freqs {
            let f = measureSRC(freq: fr, inRate: rates.0, outRate: rates.1)
            let err = f.amplitudeDB - 20 * log10(0.5)
            line += String(format: " %g:%+.4f dB/%.0f", fr, err, f.thdnDB)
            if fr <= 18000 { worstToTen = max(worstToTen, abs(err)) }
        }
        print(line)
        expect(worstToTen < 0.01, "passband error up to 18 kHz should be < 0.01 dB")
    }

    // Test: Anti-aliasing when downsampling 48 → 44.1 kHz
    func aliasing() {
        // 23 kHz is above the 22.05 kHz output Nyquist; it would alias to 21.1 kHz.
        let inRate = 48000.0, outRate = 44100.0
        let x = SignalAnalysis.sine(frequency: 23000, sampleRate: inRate, count: 72000, amplitude: 0.5)
        let y = resampleOffline(x, inRate: inRate, outRate: outRate)
        let seg = Array(y[8820..<52920])
        let rms = sqrt(seg.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(seg.count))
        let rel = 20 * log10(max(rms, 1e-15) / (0.5 / sqrt(2)))
        print(String(format: "[measure] 23 kHz into 48k→44.1k: residual %.1f dB re input", rel))
        expect(rel < -80)
    }
}

// MARK: - Bridge behaviour

func makeBridge(channels: Int, inRate: Double, outRate: Double, inBuf: Int, outBuf: Int,
                locked: Bool, margin: Double = 0.004, halfTaps: Int = 64) -> OpaquePointer {
    var cfg = ARBridgeConfig()
    cfg.busChannels = Int32(channels)
    cfg.inRate = inRate
    cfg.outRate = outRate
    cfg.inMaxFrames = 8192
    cfg.outMaxFrames = 8192
    cfg.inBufferFrames = Int32(inBuf)
    cfg.outBufferFrames = Int32(outBuf)
    cfg.halfTaps = Int32(halfTaps)
    cfg.lockedClocks = locked ? 1 : 0
    cfg.marginSeconds = margin
    cfg.maxCorrectionPPM = 2000
    let src = (0..<channels).map { Int32($0) }
    return src.withUnsafeBufferPointer { ar_bridge_create(&cfg, $0.baseAddress)! }
}

func bridgeWrite(_ b: OpaquePointer, _ chans: [[Float]], _ t: Double) {
    let frames = chans[0].count
    var bufs = chans
    var ptrs: [UnsafePointer<Float>?] = []
    var holders: [UnsafeMutableBufferPointer<Float>] = []
    for i in bufs.indices {
        let p = UnsafeMutableBufferPointer<Float>.allocate(capacity: frames)
        _ = p.initialize(from: bufs[i])
        holders.append(p)
        ptrs.append(UnsafePointer(p.baseAddress))
    }
    ptrs.withUnsafeBufferPointer { ar_bridge_write(b, $0.baseAddress, Int32(chans.count), Int32(frames), t) }
    holders.forEach { $0.deallocate() }
    bufs.removeAll()
}

func bridgeRead(_ b: OpaquePointer, channels: Int, frames: Int, _ t: Double) -> [[Float]] {
    let holders = (0..<channels).map { _ in UnsafeMutableBufferPointer<Float>.allocate(capacity: frames) }
    let ptrs: [UnsafeMutablePointer<Float>?] = holders.map { $0.baseAddress }
    ptrs.withUnsafeBufferPointer { ar_bridge_read(b, $0.baseAddress, Int32(frames), t) }
    let out = holders.map { Array($0) }
    holders.forEach { $0.deallocate() }
    return out
}

// Suite: Bridge
struct BridgeTests {
    // Test: Same clock, same rate: bit-exact pass-through
    func bitExact() {
        let b = makeBridge(channels: 2, inRate: 48000, outRate: 48000, inBuf: 256, outBuf: 256, locked: true)
        defer { ar_bridge_destroy(b) }
        var rng = SystemRandomNumberGenerator()
        var sent: [[Float]] = [[], []]
        var got: [[Float]] = [[], []]
        var t = 1000.0
        for _ in 0..<400 {
            let blk = (0..<2).map { _ in (0..<256).map { _ in Float.random(in: -1...1, using: &rng) } }
            sent[0] += blk[0]; sent[1] += blk[1]
            bridgeWrite(b, blk, t)
            let o = bridgeRead(b, channels: 2, frames: 256, t + 0.0001)
            got[0] += o[0]; got[1] += o[1]
            t += 256.0 / 48000
        }
        var s = ARBridgeStats()
        ar_bridge_get_stats(b, &s)
        expect(s.bypass == 1)
        // Find the first non-silent output frame; from there it must equal the input exactly.
        // Priming may drop a few leading frames; locate the alignment, then require exact equality.
        guard let first = got[0].firstIndex(where: { $0 != 0 }),
              let offset = sent[0].firstIndex(of: got[0][first]) else { expect(false, "no output"); return }
        let n = got[0].count - first
        let ok0 = Array(got[0][first...]) == Array(sent[0][offset..<(offset + n)])
        let ok1 = Array(got[1][first...]) == Array(sent[1][offset..<(offset + n)])
        print("[measure] bypass: output starts at frame \(first), input offset \(offset), compared \(n) frames, L exact=\(ok0) R exact=\(ok1)")
        expect(ok0 && ok1)
        expect(s.underruns == 0 && s.overruns == 0)
    }

    // Test: Overrun counting when the consumer stops
    func overrun() {
        let b = makeBridge(channels: 1, inRate: 48000, outRate: 48000, inBuf: 512, outBuf: 512, locked: true)
        defer { ar_bridge_destroy(b) }
        for i in 0..<1000 { bridgeWrite(b, [[Float](repeating: 0.1, count: 512)], 1000 + Double(i) * 0.01) }
        var s = ARBridgeStats()
        ar_bridge_get_stats(b, &s)
        print("[measure] overruns after 1000 unread blocks: \(s.overruns)")
        expect(s.overruns > 0)
    }

    // Test: Underrun counting and recovery when the producer stalls
    func underrunRecovery() {
        let b = makeBridge(channels: 1, inRate: 48000, outRate: 48000, inBuf: 256, outBuf: 256, locked: false)
        defer { ar_bridge_destroy(b) }
        var t = 1000.0
        var phase = 0.0
        func block() -> [Float] {
            (0..<256).map { _ in phase += 2 * .pi * 1000 / 48000; return Float(0.5 * sin(phase)) }
        }
        var out: [Float] = []
        for i in 0..<4000 {
            let stalled = (800..<850).contains(i)
            if !stalled { bridgeWrite(b, [block()], t) }
            out += bridgeRead(b, channels: 1, frames: 256, t + 0.002)[0]
            t += 256.0 / 48000
        }
        var s = ARBridgeStats()
        ar_bridge_get_stats(b, &s)
        print("[measure] stall of 50 blocks: underruns=\(s.underruns) state=\(s.state)")
        expect(s.underruns >= 1)
        expect(s.state == 1)
        // After recovery (stall ends at block 850 ≈ 4.5 s) the signal is clean again.
        let rep = SignalAnalysis.windowed(out, start: 1000 * 256, end: out.count, window: 4800, stride: 4800,
                                          sampleRate: 48000, guessHz: 1000, badThresholdDB: -90)
        print("[measure] after recovery: \(rep)")
        expect(rep.badWindows == 0)
    }
}

// MARK: - Independent clock drift simulation

struct DriftResult {
    var stats = ARBridgeStats()
    var report = SignalAnalysis.WindowReport()       // steady state (after 20 s)
    var acquisition = SignalAnalysis.WindowReport()  // lock-in phase (1–20 s)
    var fillErrorMax = 0.0
    var finalPPM = 0.0
}

/// Event-driven simulation of two independent device clocks feeding/consuming a bridge.
func simulateDrift(inRate: Double, outRate: Double, inPPM: Double, outPPM: Double,
                   inBuf: Int, outBuf: Int, seconds: Double, jitter: Double,
                   margin: Double = 0.004, toneHz: Double = 1000) -> DriftResult {
    let b = makeBridge(channels: 1, inRate: inRate, outRate: outRate, inBuf: inBuf, outBuf: outBuf, locked: false, margin: margin)
    defer { ar_bridge_destroy(b) }
    let inActual = inRate * (1 + inPPM * 1e-6)
    let outActual = outRate * (1 + outPPM * 1e-6)
    var seed: UInt64 = 0x9E3779B97F4A7C15
    func rand() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }

    let inBlk = UnsafeMutablePointer<Float>.allocate(capacity: inBuf)
    let outBlk = UnsafeMutablePointer<Float>.allocate(capacity: outBuf)
    defer { inBlk.deallocate(); outBlk.deallocate() }
    let totalOut = Int(seconds * outActual) + outBuf
    var out = [Float](repeating: 0, count: totalOut)
    var outCount = 0
    var inIndex = 0
    var k = 0, j = 0
    let t0 = 1000.0
    var result = DriftResult()
    let w = 2 * Double.pi * toneHz / inActual   // tone defined in true time
    while true {
        let tIn = t0 + Double(k + 1) * Double(inBuf) / inActual + (rand() - 0.5) * jitter
        let tOut = t0 + Double(j) * Double(outBuf) / outActual + 0.0003 + (rand() - 0.5) * jitter
        if tOut - t0 > seconds { break }
        if tIn <= tOut {
            for i in 0..<inBuf { inBlk[i] = Float(0.5 * sin(w * Double(inIndex + i))) }
            inIndex += inBuf
            var p: UnsafePointer<Float>? = UnsafePointer(inBlk)
            withUnsafePointer(to: &p) { ar_bridge_write(b, $0, 1, Int32(inBuf), tIn) }
            k += 1
        } else {
            var p: UnsafeMutablePointer<Float>? = outBlk
            withUnsafePointer(to: &p) { ar_bridge_read(b, $0, Int32(outBuf), tOut) }
            if outCount + outBuf <= out.count {
                for i in 0..<outBuf { out[outCount + i] = outBlk[i] }
                outCount += outBuf
            }
            j += 1
            var s = ARBridgeStats()
            ar_bridge_get_stats(b, &s)
            if tOut - t0 > 30 { result.fillErrorMax = max(result.fillErrorMax, abs(s.fillFrames - s.targetFillFrames)) }
        }
    }
    ar_bridge_get_stats(b, &result.stats)
    result.finalPPM = result.stats.correctionPPM
    // 0.1 s windows every 1 s. Acquisition (lock-in, first 20 s) and steady state analysed separately.
    let expectedHz = toneHz / outActual * outRate   // tone in output-sample units at nominal rate
    let lockEnd = min(Int(outActual * 20), outCount)
    result.acquisition = SignalAnalysis.windowed(out, start: Int(outActual * 1), end: lockEnd, window: Int(outRate * 0.1),
                                                 stride: Int(outRate * 0.5), sampleRate: outRate, guessHz: expectedHz,
                                                 badThresholdDB: -60)
    result.report = SignalAnalysis.windowed(out, start: lockEnd, end: outCount, window: Int(outRate * 0.1),
                                            stride: Int(outRate * 1.0), sampleRate: outRate, guessHz: expectedHz,
                                            badThresholdDB: -90)
    return result
}

// Suite: Clock drift
struct DriftTests {
    // Test: 48k ↔ 48k, +150 / −100 ppm, 10 simulated minutes, ±0.2 ms jitter
    func sameRateDrift() {
        let r = simulateDrift(inRate: 48000, outRate: 48000, inPPM: 150, outPPM: -100,
                              inBuf: 256, outBuf: 512, seconds: 600, jitter: 0.0004)
        print(String(format: "[measure] drift 48k/48k: ppm=%.2f (expected %.2f) underruns=%lld overruns=%lld resyncs=%lld maxFillErr=%.2f frames",
                     r.finalPPM, (1.00015 / 0.9999 - 1) * 1e6, r.stats.underruns, r.stats.overruns, r.stats.resyncs, r.fillErrorMax))
        print("[measure] drift 48k/48k acquisition: \(r.acquisition)")
        print("[measure] drift 48k/48k steady:      \(r.report)")
        expect(r.stats.underruns == 0)
        expect(r.stats.overruns == 0)
        expect(r.stats.resyncs == 0)
        expect(abs(r.finalPPM - (1.00015 / 0.9999 - 1) * 1e6) < 5)
        expect(r.report.badWindows == 0)
        expect(r.report.worstTHDN < -90)
        expect(r.acquisition.badWindows == 0, "acquisition windows worse than -60 dB")
    }

    // Test: 44.1k → 48k, −80 / +120 ppm, 5 simulated minutes
    func crossRateDrift() {
        let r = simulateDrift(inRate: 44100, outRate: 48000, inPPM: -80, outPPM: 120,
                              inBuf: 512, outBuf: 128, seconds: 300, jitter: 0.0004)
        print(String(format: "[measure] drift 44.1k/48k: ppm=%.2f underruns=%lld overruns=%lld resyncs=%lld maxFillErr=%.2f frames",
                     r.finalPPM, r.stats.underruns, r.stats.overruns, r.stats.resyncs, r.fillErrorMax))
        print("[measure] drift 44.1k/48k acquisition: \(r.acquisition)")
        print("[measure] drift 44.1k/48k steady:      \(r.report)")
        expect(r.stats.underruns == 0 && r.stats.overruns == 0 && r.stats.resyncs == 0)
        expect(r.report.badWindows == 0)
        expect(r.report.worstTHDN < -90)
        expect(r.acquisition.badWindows == 0, "acquisition windows worse than -60 dB")
    }

    // Test: Low latency margins, 48k → 44.1k, 64-frame buffers, +200 ppm
    func lowLatencyDrift() {
        let r = simulateDrift(inRate: 48000, outRate: 44100, inPPM: 200, outPPM: 0,
                              inBuf: 64, outBuf: 64, seconds: 120, jitter: 0.0002, margin: 0.0015)
        print(String(format: "[measure] low-latency drift: ppm=%.2f underruns=%lld overruns=%lld target=%.1f frames (%.2f ms)",
                     r.finalPPM, r.stats.underruns, r.stats.overruns, r.stats.targetFillFrames, r.stats.targetFillFrames / 48))
        print("[measure] low-latency acquisition: \(r.acquisition)")
        print("[measure] low-latency steady:      \(r.report)")
        expect(r.stats.underruns == 0)
        expect(r.report.badWindows == 0)
    }
}

// MARK: - Mixer / channel mapping

func runOutputNode(_ node: OpaquePointer, channels: Int, frames: Int, t: Double) -> [[Float]] {
    let holders = (0..<channels).map { _ in UnsafeMutableBufferPointer<Float>.allocate(capacity: frames) }
    let ptrs: [UnsafeMutablePointer<Float>?] = holders.map { $0.baseAddress }
    ptrs.withUnsafeBufferPointer { ar_output_process(node, $0.baseAddress, Int32(channels), Int32(frames), t) }
    let out = holders.map { Array($0) }
    holders.forEach { $0.deallocate() }
    return out
}

// Suite: Channel mapping and gain
struct MappingTests {
    /// Bypass bridge (locked, 48k) carrying `bus` channels with distinct tones; returns the output node result.
    func run(busTones: [Double], xpoints: [(bus: Int, out: Int, gain: Float)], outChannels: Int,
             after: ((OpaquePointer, [Int32]) -> Void)? = nil) -> [[Float]] {
        let b = makeBridge(channels: busTones.count, inRate: 48000, outRate: 48000, inBuf: 512, outBuf: 512, locked: true)
        let node = ar_output_create(Int32(outChannels), 8192, 48000)!
        defer { ar_output_destroy(node); ar_bridge_destroy(b) }
        let slot = ar_output_add_bridge(node, b, Int32(busTones.count))
        let ids = xpoints.map { ar_output_add_xpoint(node, slot, Int32($0.bus), Int32($0.out), $0.gain) }
        var outs = [[Float]](repeating: [], count: outChannels)
        var t = 1000.0
        var idx = 0
        for blk in 0..<60 {
            if blk == 30 { after?(node, ids) }
            let chans = busTones.map { f in (0..<512).map { Float(0.25 * sin(2 * .pi * f * Double(idx + $0) / 48000)) } }
            idx += 512
            bridgeWrite(b, chans, t)
            let o = runOutputNode(node, channels: outChannels, frames: 512, t: t + 0.001)
            for c in 0..<outChannels { outs[c] += o[c] }
            t += 512.0 / 48000
        }
        return outs
    }

    func level(_ x: [Float], from: Int, to: Int, hz: Double) -> SignalAnalysis.SineFit {
        SignalAnalysis.fitSine(x, start: from, count: to - from, sampleRate: 48000, guessHz: hz, searchPPM: 5)
    }

    // Test: Stereo 1/2 → 1/2 keeps channel order (no swap)
    func stereoOrder() {
        let o = run(busTones: [440, 880], xpoints: [(0, 0, 1), (1, 1, 1)], outChannels: 2)
        let l = level(o[0], from: 4096, to: 14000, hz: 440)
        let r = level(o[1], from: 4096, to: 14000, hz: 880)
        print("[measure] L: \(l)  R: \(r)")
        expect(abs(l.amplitude - 0.25) < 1e-6 && l.thdnDB < -120)
        expect(abs(r.amplitude - 0.25) < 1e-6 && r.thdnDB < -120)
    }

    // Test: Mono 1 → outputs 1+2 (one-to-many)
    func monoToBoth() {
        let o = run(busTones: [440], xpoints: [(0, 0, 1), (0, 1, 1)], outChannels: 2)
        expect(Array(o[0][4096..<14000]) == Array(o[1][4096..<14000]))
        expect(level(o[0], from: 4096, to: 14000, hz: 440).thdnDB < -120)
    }

    // Test: Mono output channel 3 of 4 only
    func monoToChannel3() {
        let o = run(busTones: [440], xpoints: [(0, 2, 1)], outChannels: 4)
        expect(o[0].allSatisfy { $0 == 0 } && o[1].allSatisfy { $0 == 0 } && o[3].allSatisfy { $0 == 0 })
        expect(level(o[2], from: 4096, to: 14000, hz: 440).thdnDB < -120)
    }

    // Test: Gain −6.02 dB and live mute with ramp
    func gainAndMute() {
        let g = Float(pow(10.0, -6.0206 / 20))
        let o = run(busTones: [440], xpoints: [(0, 0, g)], outChannels: 1) { node, ids in
            ar_output_set_xpoint_gain(node, ids[0], 0)
        }
        let before = level(o[0], from: 4096, to: 14000, hz: 440)
        print(String(format: "[measure] gain -6.02 dB → measured %.4f dB", 20 * log10(before.amplitude / 0.25)))
        expect(abs(20 * log10(before.amplitude / 0.25) + 6.0206) < 0.001)
        // Block 30 ramps to zero; blocks after it are silent.
        expect(o[0][(31 * 512)...].allSatisfy { $0 == 0 })
        // The ramp block must not jump: max step between adjacent samples stays small.
        let ramp = Array(o[0][(30 * 512 - 1)..<(31 * 512)])
        let maxStep = zip(ramp.dropFirst(), ramp).map { abs($0 - $1) }.max() ?? 0
        expect(maxStep < 0.02)
    }

    // Test: Stereo → mono sum at −6 dB each
    func stereoToMono() {
        let o = run(busTones: [440, 440], xpoints: [(0, 0, 0.5), (1, 0, 0.5)], outChannels: 1)
        let f = level(o[0], from: 4096, to: 14000, hz: 440)
        expect(abs(f.amplitude - 0.25) < 1e-6)
    }

    // Test: NaN input is sanitized, never reaches the device
    func nanGuard() {
        let b = makeBridge(channels: 1, inRate: 48000, outRate: 48000, inBuf: 256, outBuf: 256, locked: true)
        let node = ar_output_create(1, 8192, 48000)!
        defer { ar_output_destroy(node); ar_bridge_destroy(b) }
        let slot = ar_output_add_bridge(node, b, 1)
        _ = ar_output_add_xpoint(node, slot, 0, 0, 1)
        var all: [Float] = []
        for i in 0..<40 {
            bridgeWrite(b, [[Float](repeating: .nan, count: 256)], 1000 + Double(i) * 0.005)
            all += runOutputNode(node, channels: 1, frames: 256, t: 1000 + Double(i) * 0.005 + 0.001)[0]
        }
        expect(all.allSatisfy { $0.isFinite })
        expect(ar_output_nan_count(node) > 0)
    }

    // Test: Feedback protection trips on sustained full-scale output
    func protection() {
        let b = makeBridge(channels: 1, inRate: 48000, outRate: 48000, inBuf: 512, outBuf: 512, locked: true)
        let node = ar_output_create(1, 8192, 48000)!
        defer { ar_output_destroy(node); ar_bridge_destroy(b) }
        let slot = ar_output_add_bridge(node, b, 1)
        _ = ar_output_add_xpoint(node, slot, 0, 0, 4)  // +12 dB on a full-scale square → clipping
        for i in 0..<300 {
            bridgeWrite(b, [(0..<512).map { $0 % 64 < 32 ? 0.9 : -0.9 }], 1000 + Double(i) * 0.0107)
            _ = runOutputNode(node, channels: 1, frames: 512, t: 1000 + Double(i) * 0.0107 + 0.001)
        }
        expect(ar_output_protection_tripped(node) == 1)
    }
}

// MARK: - Model

// Suite: Models
struct ModelTests {
    // Test: Default mappings
    func defaults() {
        expect(Route.defaultCrosspoints(inputChannels: 2, outputChannels: 2) == [Crosspoint(input: 0, output: 0), Crosspoint(input: 1, output: 1)])
        expect(Route.defaultCrosspoints(inputChannels: 1, outputChannels: 2) == [Crosspoint(input: 0, output: 0), Crosspoint(input: 0, output: 1)])
        expect(Route.defaultCrosspoints(inputChannels: 2, outputChannels: 1).count == 2)
    }

    // Test: Gain clamp and mutes
    func gain() {
        var r = Route(name: "t")
        let xp = Crosspoint(input: 0, output: 1)
        r.gainDB = 40
        expect(abs(r.effectiveGain(xp) - Float(pow(10.0, 12.0 / 20))) < 1e-5)
        r.gainDB = 0
        r.mutedOutputChannels = [1]
        expect(r.effectiveGain(xp) == 0)
        r.mutedOutputChannels = []
        r.muted = true
        expect(r.effectiveGain(xp) == 0)
    }

    // Test: Saved state round-trips through JSON
    func codable() throws {
        var s = SavedState()
        var r = Route(name: "Route 1", input: DeviceRef(uid: "a", name: "Audio Device 1"), output: DeviceRef(uid: "b", name: "Audio Device 2"),
                      crosspoints: [Crosspoint(input: 0, output: 0)])
        r.mutedOutputChannels = [3]
        s.routes = [r]
        s.presets = [Preset(name: "P", routes: [r], settings: EngineSettings())]
        let d = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(SavedState.self, from: d)
        expect(back.routes == s.routes)
        expect(back.presets == s.presets)
    }
}

