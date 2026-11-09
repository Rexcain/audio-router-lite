import Foundation

/// Measurement helpers for sine-based quality tests (THD+N, amplitude, frequency).
public enum SignalAnalysis {
    public struct SineFit: CustomStringConvertible {
        public var frequency: Double   // cycles per sample * sampleRate
        public var amplitude: Double
        public var offset: Double
        public var residualRMS: Double
        public var residualPeak: Double

        /// THD+N relative to the fitted fundamental, in dB.
        public var thdnDB: Double { 20 * log10(max(residualRMS, 1e-15) / (amplitude / sqrt(2))) }
        public var amplitudeDB: Double { 20 * log10(max(amplitude, 1e-15)) }

        public var description: String {
            String(format: "f=%.4f Hz A=%.6f (%.3f dBFS) THD+N=%.1f dB", frequency, amplitude, amplitudeDB, thdnDB)
        }
    }

    /// 3-parameter least squares fit at a fixed normalized frequency w (rad/sample).
    static func fit3(_ x: UnsafeBufferPointer<Float>, w: Double) -> (a: Double, b: Double, c: Double, res2: Double) {
        let n = x.count
        var scc = 0.0, sss = 0.0, ssc = 0.0, sc = 0.0, ss = 0.0, xc = 0.0, xs = 0.0, xsum = 0.0, xx = 0.0
        // Rotating phasor for cos/sin (re-normalized periodically).
        let cw = cos(w), sw = sin(w)
        var c = 1.0, s = 0.0
        for i in 0..<n {
            let v = Double(x[i])
            scc += c * c; sss += s * s; ssc += s * c; sc += c; ss += s
            xc += v * c; xs += v * s; xsum += v; xx += v * v
            let nc = c * cw - s * sw
            s = s * cw + c * sw
            c = nc
            if i & 1023 == 1023 { let m = 1.0 / sqrt(c * c + s * s); c *= m; s *= m }
        }
        // Solve [scc ssc sc; ssc sss ss; sc ss n] [a b k] = [xc xs xsum]
        let m: [[Double]] = [[scc, ssc, sc, xc], [ssc, sss, ss, xs], [sc, ss, Double(n), xsum]]
        var A = m
        for col in 0..<3 {
            var piv = col
            for r in col..<3 where abs(A[r][col]) > abs(A[piv][col]) { piv = r }
            A.swapAt(col, piv)
            let d = A[col][col]
            if abs(d) < 1e-300 { return (0, 0, 0, xx) }
            for k in col..<4 { A[col][k] /= d }
            for r in 0..<3 where r != col {
                let f = A[r][col]
                for k in col..<4 { A[r][k] -= f * A[col][k] }
            }
        }
        let a = A[0][3], b = A[1][3], k = A[2][3]
        // residual energy = xx - (a*xc + b*xs + k*xsum)
        let res2 = max(xx - (a * xc + b * xs + k * xsum), 0)
        return (a, b, k, res2)
    }

    /// Fit a sine near `guessHz` (searching ±searchPPM) to x[start..<start+count].
    public static func fitSine(_ x: [Float], start: Int, count: Int, sampleRate: Double,
                               guessHz: Double, searchPPM: Double = 3000) -> SineFit {
        precondition(start >= 0 && start + count <= x.count && count > 16)
        return x.withUnsafeBufferPointer { all in
            let seg = UnsafeBufferPointer(rebasing: all[start..<(start + count)])
            var lo = guessHz * (1 - searchPPM * 1e-6), hi = guessHz * (1 + searchPPM * 1e-6)
            func cost(_ f: Double) -> Double { fit3(seg, w: 2 * .pi * f / sampleRate).res2 }
            // Golden-section search on residual energy.
            let g = (sqrt(5.0) - 1) / 2
            var x1 = hi - g * (hi - lo), x2 = lo + g * (hi - lo)
            var f1 = cost(x1), f2 = cost(x2)
            for _ in 0..<60 {
                if f1 < f2 { hi = x2; x2 = x1; f2 = f1; x1 = hi - g * (hi - lo); f1 = cost(x1) }
                else { lo = x1; x1 = x2; f1 = f2; x2 = lo + g * (hi - lo); f2 = cost(x2) }
                if hi - lo < guessHz * 1e-12 { break }
            }
            let f = (lo + hi) / 2
            let w = 2 * .pi * f / sampleRate
            let r = fit3(seg, w: w)
            // Exact residual pass for RMS and peak.
            var peak = 0.0, e2 = 0.0
            for i in 0..<count {
                let t = Double(i) * w
                let e = Double(seg[i]) - (r.a * cos(t) + r.b * sin(t) + r.c)
                e2 += e * e
                peak = max(peak, abs(e))
            }
            return SineFit(frequency: f, amplitude: sqrt(r.a * r.a + r.b * r.b), offset: r.c,
                           residualRMS: sqrt(e2 / Double(count)), residualPeak: peak)
        }
    }

    public struct WindowReport: CustomStringConvertible {
        public var windows: Int = 0
        public var worstTHDN: Double = -.infinity
        public var medianTHDN: Double = 0
        public var badWindows: Int = 0   // windows above the glitch threshold
        public var minAmplitudeDB: Double = .infinity
        public var maxAmplitudeDB: Double = -.infinity
        public var meanFrequency: Double = 0
        public var badPositions: [Int] = []   // sample index of the first bad windows

        public init() {}

        public var description: String {
            String(format: "windows=%d median THD+N=%.1f dB worst=%.1f dB bad=%d amp=[%.3f, %.3f] dBFS f=%.4f Hz",
                   windows, medianTHDN, worstTHDN, badWindows, minAmplitudeDB, maxAmplitudeDB, meanFrequency)
        }
    }

    /// Windowed analysis across a long recording: catches dropouts/glitches that a global fit would average out.
    public static func windowed(_ x: [Float], start: Int, end: Int, window: Int, stride: Int,
                                sampleRate: Double, guessHz: Double, badThresholdDB: Double = -60) -> WindowReport {
        var rep = WindowReport()
        var thdns: [Double] = []
        var fsum = 0.0
        var pos = start
        while pos + window <= end {
            let f = fitSine(x, start: pos, count: window, sampleRate: sampleRate, guessHz: guessHz)
            thdns.append(f.thdnDB)
            fsum += f.frequency
            rep.worstTHDN = max(rep.worstTHDN, f.thdnDB)
            rep.minAmplitudeDB = min(rep.minAmplitudeDB, f.amplitudeDB)
            rep.maxAmplitudeDB = max(rep.maxAmplitudeDB, f.amplitudeDB)
            if f.thdnDB > badThresholdDB {
                rep.badWindows += 1
                if rep.badPositions.count < 20 { rep.badPositions.append(pos) }
            }
            pos += stride
        }
        rep.windows = thdns.count
        if !thdns.isEmpty {
            rep.medianTHDN = thdns.sorted()[thdns.count / 2]
            rep.meanFrequency = fsum / Double(thdns.count)
        }
        return rep
    }

    /// x[start..<start+count] minus the fitted sinusoid.
    public static func subtractFit(_ x: [Float], start: Int, count: Int, fit: SineFit, sampleRate: Double) -> [Float] {
        let w = 2 * Double.pi * fit.frequency / sampleRate
        let r = x.withUnsafeBufferPointer { fit3(UnsafeBufferPointer(rebasing: $0[start..<(start + count)]), w: w) }
        return (0..<count).map { i in Float(Double(x[start + i]) - (r.a * cos(Double(i) * w) + r.b * sin(Double(i) * w) + r.c)) }
    }

    public static func sine(frequency: Double, sampleRate: Double, count: Int, amplitude: Double = 0.5, phase: Double = 0) -> [Float] {
        (0..<count).map { Float(amplitude * sin(2 * .pi * frequency * Double($0) / sampleRate + phase)) }
    }
}
