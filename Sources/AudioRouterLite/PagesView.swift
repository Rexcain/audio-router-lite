import AppKit
import AudioRouterKit
import CRouterCore
import SwiftUI

// MARK: - Devices

struct DevicesView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: AudioDeviceInfo.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Devices").font(.largeTitle.weight(.semibold))
                    Text("All Core Audio devices: USB, built-in and virtual. Updates automatically when devices are plugged in or changed.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.refreshDevices() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
            Table(model.devices, selection: $selection) {
                TableColumn("Name") { d in
                    HStack(spacing: 6) {
                        Image(systemName: icon(d)).foregroundStyle(.secondary).frame(width: 16)
                        Text(d.name)
                        if d.isVirtualSink { Text("Virtual output").font(.caption2).padding(.horizontal, 4).background(.blue.opacity(0.15), in: Capsule()) }
                    }
                }
                .width(min: 180, ideal: 220)
                TableColumn("Type") { d in Text(d.transport.rawValue) }.width(80)
                TableColumn("In") { d in Text(d.inputChannels > 0 ? "\(d.inputChannels)" : "–").monospacedDigit() }.width(36)
                TableColumn("Out") { d in Text(d.outputChannels > 0 ? "\(d.outputChannels)" : "–").monospacedDigit() }.width(36)
                TableColumn("Rate") { d in Text("\(Int(d.nominalSampleRate)) Hz").monospacedDigit() }.width(80)
                TableColumn("Buffer") { d in Text("\(d.bufferFrameSize)").monospacedDigit() }.width(56)
                TableColumn("Status") { d in
                    Text(status(d)).foregroundStyle(d.isHoggedByOther || !d.isAlive ? .red : .secondary)
                }
                .width(min: 80, ideal: 110)
                TableColumn("UID") { d in Text(d.uid).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            if let id = selection, let d = model.devices.first(where: { $0.id == id }) {
                DeviceDetail(device: d)
            }
        }
        .padding(20)
    }

    private func icon(_ d: AudioDeviceInfo) -> String {
        switch d.transport {
        case .usb: return "cable.connector"
        case .virtual: return "square.stack.3d.up"
        case .builtIn: return "laptopcomputer"
        case .bluetooth: return "dot.radiowaves.left.and.right"
        case .aggregate: return "square.grid.2x2"
        default: return "hifispeaker"
        }
    }

    private func status(_ d: AudioDeviceInfo) -> String {
        if !d.isAlive { return "Not responding" }
        if d.isHoggedByOther { return "Exclusive (pid \(d.hogModePID))" }
        return d.isRunningSomewhere ? "In use" : "Idle"
    }
}

struct DeviceDetail: View {
    let device: AudioDeviceInfo

    var body: some View {
        GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                row("Manufacturer", device.manufacturer.isEmpty ? "—" : device.manufacturer)
                row("Supported rates", device.availableSampleRates.map { "\(Int($0))" }.joined(separator: ", "))
                row("Buffer range", device.bufferFrameSizeRange.map { "\($0.lowerBound)–\($0.upperBound) frames" } ?? "—")
                row("Latency (in / out)", "\(device.inputLatencyFrames) / \(device.outputLatencyFrames) frames, safety offset \(device.inputSafetyOffset) / \(device.outputSafetyOffset)")
                row("Clock domain", device.clockDomain == 0 ? "unknown (treated as independent)" : "\(device.clockDomain)")
                if device.inputChannels > 0 {
                    row("Input channels", (0..<min(device.inputChannels, 16)).map { device.channelName($0, input: true) }.joined(separator: ", "))
                }
                if device.outputChannels > 0 {
                    row("Output channels", (0..<min(device.outputChannels, 16)).map { device.channelName($0, input: false) }.joined(separator: ", "))
                }
                if device.isVirtualSink {
                    row("Note", "Virtual output device: audio sent here is handed to the software that created it, which plays it on the output chosen in its own settings.")
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(device.name).font(.headline)
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Monitoring

struct MonitorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Monitoring").font(.largeTitle.weight(.semibold))
                        Text("Live levels, buffer state, clock correction and dropout counters per route. A moving input meter only proves audio arrives; check that you hear it on the destination.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Reset Counters") { model.resetCounters() }
                    Button("Clear Clip") { model.clearClipIndicators() }
                }
                if !model.wantRunning {
                    ContentUnavailableView("Not running", systemImage: "waveform.slash", description: Text("Press Start to see live data."))
                }
                ForEach(model.routes.filter(\.enabled)) { r in
                    MonitorCard(route: r)
                }
            }
            .padding(20)
        }
    }
}

struct MonitorCard: View {
    @Environment(AppModel.self) private var model
    let route: Route

    var body: some View {
        let st = model.routeStatus[route.id]
        let rt = model.runtime[route.id]
        GroupBox {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Input").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    ForEach(route.inputChannelsUsed, id: \.self) { ch in
                        LiveChannelMeter(label: "In \(ch + 1)", input: true, device: rt?.inputDeviceID, channel: ch)
                    }
                    Text("Output").font(.caption.weight(.bold)).foregroundStyle(.secondary).padding(.top, 4)
                    ForEach(route.outputChannelsUsed, id: \.self) { ch in
                        LiveChannelMeter(label: "Out \(ch + 1)", input: false, device: rt?.outputDeviceID, channel: ch)
                    }
                }
                .frame(minWidth: 260)
                if let s = st?.stats, let rt {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                        row("Sample rates", "\(Int(rt.inRate)) → \(Int(rt.outRate)) Hz")
                        row("Processing", s.bypass != 0 ? "Bit-exact pass-through (shared clock)" :
                            (rt.inRate != rt.outRate ? "Sample-rate conversion (\(s.halfTaps * 2)-tap sinc) + drift compensation"
                                                     : "Drift compensation (\(s.halfTaps * 2)-tap sinc)"))
                        row("Device buffers", "in \(rt.inBuffer) / out \(rt.outBuffer) frames")
                        row("Router buffer", String(format: "%.0f frames (target %.0f) = %.2f ms", s.fillFrames, s.targetFillFrames, s.fillFrames / rt.inRate * 1000))
                        row("Clock correction", s.bypass != 0 ? "none needed" : String(format: "%+.2f ppm", s.correctionPPM))
                        row("Latency: router", String(format: "%.2f ms", s.targetFillFrames / rt.inRate * 1000))
                        row("Latency: devices", String(format: "in %.2f ms + out %.2f ms (reported by drivers)", rt.inputDeviceLatency * 1000, rt.outputDeviceLatency * 1000))
                        row("Latency: estimated total", String(format: "%.1f ms (not measured)", (rt.inputDeviceLatency + rt.outputDeviceLatency) * 1000 + s.targetFillFrames / rt.inRate * 1000))
                        row("Underruns / overruns", "\(s.underruns) / \(s.overruns)", warn: s.underruns + s.overruns > 0)
                        row("Resyncs", "\(s.resyncs)", warn: s.resyncs > 0)
                        if let h = st?.health {
                            row("IO callbacks", "in \(h.inputCallbacks) / out \(h.outputCallbacks)", warn: h.inputCallbacks == 0 || h.outputCallbacks == 0)
                            if h.inputErrors + h.outputErrors > 0 {
                                row("IO errors", "in \(h.inputErrors) / out \(h.outputErrors)", warn: true)
                            }
                        }
                    }
                    .font(.callout.monospacedDigit())
                } else {
                    Text(statusText(st)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("\(route.name): \(route.input?.name ?? "—") → \(route.output?.name ?? "—")").font(.headline)
        }
    }

    private func statusText(_ st: RouteStatus?) -> String {
        switch st?.kind {
        case .waiting(let e), .error(let e): return e
        default: return model.wantRunning ? "Starting…" : "Stopped"
        }
    }

    private func row(_ k: String, _ v: String, warn: Bool = false) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).foregroundStyle(warn ? .orange : .primary)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Latency") {
                Picker("Mode", selection: $model.settings.latencyMode) {
                    ForEach(LatencyMode.allCases) { m in Text(m.rawValue).tag(m) }
                }
                .pickerStyle(.segmented)
                Text(model.settings.latencyMode.summary).font(.caption).foregroundStyle(.secondary)
                Toggle("Set device buffer size for this mode", isOn: $model.settings.setDeviceBufferSize)
                Text("Changes the IO buffer of the devices in use. Other apps using the same device are affected while Audio Router Lite runs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Sample rate") {
                Toggle("Match output sample rate to input when possible", isOn: $model.settings.matchSampleRates)
                Text("Off by default: switching a device's rate affects every app using it. When off, rates are converted with a high-quality resampler (measured THD+N below −110 dB).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Safety") {
                Toggle("Feedback protection", isOn: $model.settings.feedbackProtection)
                Text("Mutes an output after more than 1.5 s of continuous full-scale signal (typical of a feedback loop). Does not alter normal audio.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Startup") {
                Toggle("Start routing when the app opens", isOn: $model.autoStart)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Diagnostics

struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Diagnostics").font(.largeTitle.weight(.semibold))
                    Text("Event log. Copy it when reporting a problem.").foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.diagnosticsText(), forType: .string)
                } label: { Label("Copy Diagnostics", systemImage: "doc.on.doc") }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([Persistence.stateURL])
                } label: { Label("Show Settings File", systemImage: "folder") }
            }
            List(model.log.reversed()) { e in
                HStack(alignment: .top) {
                    Text(e.date, format: .dateTime.hour().minute().second()).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Image(systemName: e.level == .error ? "xmark.octagon.fill" : e.level == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                        .foregroundStyle(e.level == .error ? .red : e.level == .warning ? .orange : .secondary)
                    Text(e.message).textSelection(.enabled)
                }
            }
        }
        .padding(20)
    }
}
