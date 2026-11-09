// Self-contained test runner (the Command Line Tools toolchain cannot discover Swift Testing tests).
// Run with:  swift run -c release RouterTests [filter]
import Foundation

var currentFailures: [String] = []

func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "",
            file: StaticString = #fileID, line: UInt = #line) {
    if !condition() { currentFailures.append("\(file):\(line) \(message())") }
}

struct TestCase {
    let name: String
    let body: () throws -> Void
}

let src = SRCTests(), bridge = BridgeTests(), drift = DriftTests(), mapping = MappingTests(), models = ModelTests()
let rates: [(Double, Double)] = [(44100, 48000), (48000, 44100), (48000, 96000), (96000, 48000)]

var tests: [TestCase] = [
    TestCase(name: "SRC 44.1k→48k 997 Hz") { src.up() },
    TestCase(name: "SRC 48k→44.1k 997 Hz") { src.down() },
    TestCase(name: "SRC low-latency filter 44.1k→48k") { src.lowLatencyFilter(rates: (44100, 48000)) },
    TestCase(name: "SRC low-latency filter 48k→44.1k") { src.lowLatencyFilter(rates: (48000, 44100)) },
] + rates.map { r in TestCase(name: "Frequency response \(Int(r.0))→\(Int(r.1))") { src.frequencyResponse(rates: r) } } + [
    TestCase(name: "SRC anti-aliasing 48k→44.1k") { src.aliasing() },
    TestCase(name: "Bridge bit-exact bypass") { bridge.bitExact() },
    TestCase(name: "Bridge overrun counting") { bridge.overrun() },
    TestCase(name: "Bridge underrun + recovery") { bridge.underrunRecovery() },
    TestCase(name: "Mapping stereo order") { mapping.stereoOrder() },
    TestCase(name: "Mapping mono → both") { mapping.monoToBoth() },
    TestCase(name: "Mapping mono → ch3 of 4") { mapping.monoToChannel3() },
    TestCase(name: "Gain −6 dB + live mute ramp") { mapping.gainAndMute() },
    TestCase(name: "Stereo → mono sum") { mapping.stereoToMono() },
    TestCase(name: "NaN guard") { mapping.nanGuard() },
    TestCase(name: "Feedback protection") { mapping.protection() },
    TestCase(name: "Model default mappings") { models.defaults() },
    TestCase(name: "Model gain clamp + mutes") { models.gain() },
    TestCase(name: "Model JSON round-trip") { try models.codable() },
    TestCase(name: "Drift 48k/48k +150/−100 ppm, 10 min") { drift.sameRateDrift() },
    TestCase(name: "Drift 44.1k→48k −80/+120 ppm, 5 min") { drift.crossRateDrift() },
    TestCase(name: "Drift low-latency 48k→44.1k +200 ppm") { drift.lowLatencyDrift() },
]

let filter = CommandLine.arguments.dropFirst().first
if let filter { tests = tests.filter { $0.name.localizedCaseInsensitiveContains(filter) } }

var failed: [String] = []
let t0 = Date()
for t in tests {
    currentFailures = []
    let start = Date()
    do { try t.body() } catch { currentFailures.append("threw \(error)") }
    let dt = Date().timeIntervalSince(start)
    if currentFailures.isEmpty {
        print(String(format: "✔ %@ (%.2fs)", t.name, dt))
    } else {
        print(String(format: "✘ %@ (%.2fs)", t.name, dt))
        currentFailures.forEach { print("    \($0)") }
        failed.append(t.name)
    }
}
print(String(format: "\n%d tests, %d passed, %d failed (%.1fs)", tests.count, tests.count - failed.count, failed.count, Date().timeIntervalSince(t0)))
exit(failed.isEmpty ? 0 : 1)
