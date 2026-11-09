import AudioRouterKit
import CoreAudio
import SwiftUI

// MARK: - Channel selection helpers

/// Simple (non-matrix) channel selection: one mono channel or a stereo pair.
enum ChannelSel: Hashable {
    case mono(Int)
    case stereo(Int)

    var channels: [Int] {
        switch self { case .mono(let c): return [c]; case .stereo(let c): return [c, c + 1] }
    }

    static func options(count: Int) -> [ChannelSel] {
        var o: [ChannelSel] = []
        var c = 0
        while c + 1 < count { o.append(.stereo(c)); c += 2 }
        for m in 0..<count { o.append(.mono(m)) }
        return o
    }

    func label(_ device: AudioDeviceInfo?, input: Bool) -> String {
        let p = input ? "In" : "Out"
        switch self {
        case .mono(let c):
            if let d = device, c < (input ? d.inputChannelNames : d.outputChannelNames).count,
               !(input ? d.inputChannelNames : d.outputChannelNames)[c].isEmpty {
                return "\(p) \(c + 1) – \((input ? d.inputChannelNames : d.outputChannelNames)[c]) (mono)"
            }
            return "\(p) \(c + 1) (mono)"
        case .stereo(let c): return "\(p) \(c + 1)+\(c + 2) (stereo)"
        }
    }

    static func crosspoints(_ i: ChannelSel, _ o: ChannelSel) -> [Crosspoint] {
        switch (i, o) {
        case (.mono(let a), .mono(let b)): return [Crosspoint(input: a, output: b)]
        case (.mono(let a), .stereo(let b)): return [Crosspoint(input: a, output: b), Crosspoint(input: a, output: b + 1)]
        case (.stereo(let a), .stereo(let b)): return [Crosspoint(input: a, output: b), Crosspoint(input: a + 1, output: b + 1)]
        case (.stereo(let a), .mono(let b)): return [Crosspoint(input: a, output: b, gain: 0.5), Crosspoint(input: a + 1, output: b, gain: 0.5)]
        }
    }

    /// Recognise a simple mapping; nil means a custom matrix.
    static func detect(_ xps: [Crosspoint]) -> (ChannelSel, ChannelSel)? {
        let ins = Array(Set(xps.map(\.input))).sorted()
        let outs = Array(Set(xps.map(\.output))).sorted()
        func sel(_ a: [Int]) -> ChannelSel? {
            if a.count == 1 { return .mono(a[0]) }
            if a.count == 2 && a[1] == a[0] + 1 { return .stereo(a[0]) }
            return nil
        }
        guard let i = sel(ins), let o = sel(outs) else { return nil }
        return Set(crosspoints(i, o)) == Set(xps) ? (i, o) : nil
    }

    static func defaultFor(_ count: Int) -> ChannelSel { count >= 2 ? .stereo(0) : .mono(0) }
}

func deviceLabel(_ d: AudioDeviceInfo, all: [AudioDeviceInfo]) -> String {
    let dup = all.filter { $0.name == d.name }.count > 1
    let suffix = dup ? " [\(d.uid.suffix(8))]" : ""
    return "\(d.name)\(suffix) · \(d.transport.rawValue)"
}

// MARK: - Routing page

struct RoutingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Routing").font(.largeTitle.weight(.semibold))
                        Text("Each route sends selected input channels of one device to channels of another device. Press Start to run all enabled routes.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { model.addRoute() } label: { Label("Add Route", systemImage: "plus") }
                }
                PresetBar()
                if model.routes.isEmpty {
                    ContentUnavailableView("No routes", systemImage: "point.3.connected.trianglepath.dotted",
                                           description: Text("Add a route to send audio from an input device to an output device."))
                }
                ForEach($model.routes) { $route in
                    RouteCard(route: $route)
                }
            }
            .padding(20)
        }
    }
}

// MARK: - Preset bar

struct PresetBar: View {
    @Environment(AppModel.self) private var model
    @State private var showSave = false
    @State private var name = ""

    var body: some View {
        let current = model.matchingPreset
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up").foregroundStyle(.secondary)
            Text("Preset").foregroundStyle(.secondary)
            Menu {
                if model.presets.isEmpty {
                    Text("No presets yet")
                }
                ForEach(model.presets) { p in
                    Button { model.loadPreset(p) } label: {
                        if p.id == current?.id { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                    }
                }
                if !model.presets.isEmpty {
                    Divider()
                    Menu("Delete") {
                        ForEach(model.presets) { p in
                            Button(p.name, role: .destructive) { model.deletePreset(p) }
                        }
                    }
                }
            } label: {
                Text(current?.name ?? (model.presets.isEmpty ? "None" : "Unsaved changes"))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Load a saved routing preset")

            Button {
                name = current?.name ?? ""
                showSave = true
            } label: { Label("Save Preset…", systemImage: "square.and.arrow.down") }
            .popover(isPresented: $showSave, arrowEdge: .bottom) { savePopover }

            Spacer()
            if let current {
                Text(current.routes.map { "\($0.input?.name ?? "—") → \($0.output?.name ?? "—")" }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
    private var overwrites: Bool { model.presets.contains { $0.name == trimmed } }

    private var savePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Save current routing as preset").font(.headline)
            TextField("Name", text: $name, prompt: Text("e.g. Audio Device 1 → Audio Device 2"))
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit(save)
            Text(overwrites ? "A preset with this name exists and will be replaced." : "Saves all routes plus the latency and sample-rate settings.")
                .font(.caption).foregroundStyle(overwrites ? .orange : .secondary)
            HStack {
                Spacer()
                Button("Cancel") { showSave = false }.keyboardShortcut(.cancelAction)
                Button(overwrites ? "Replace" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(16)
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        model.savePreset(named: trimmed)
        showSave = false
    }
}

// MARK: - Route card

struct RouteCard: View {
    @Environment(AppModel.self) private var model
    @Binding var route: Route
    @State private var showMatrix = false
    @State private var showVirtualHelp = false

    private var inDev: AudioDeviceInfo? { model.device(for: route.input, input: true) }
    private var outDev: AudioDeviceInfo? { model.device(for: route.output, input: false) }
    private var status: RouteStatus? { model.routeStatus[route.id] }
    private var runtime: RouteRuntimeSummary? { model.runtime[route.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack(alignment: .top, spacing: 0) {
                sourceBox
                FlowArrow()
                processorBox
                FlowArrow()
                destinationBox
            }
            if outDev?.isVirtualSink == true { virtualSinkNote }
            messages
            DisclosureGroup(isExpanded: $showMatrix) {
                MatrixView(route: $route, inDev: inDev, outDev: outDev).padding(.top, 6)
            } label: {
                Text("Channel matrix (advanced)").font(.callout)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(borderColor.opacity(0.6), lineWidth: 1))
        .opacity(route.enabled ? 1 : 0.6)
    }

    private var borderColor: Color {
        switch status?.kind {
        case .running: return .green
        case .waiting: return .orange
        case .error: return .red
        default: return .secondary.opacity(0.4)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Toggle("Enabled", isOn: $route.enabled).toggleStyle(.switch).labelsHidden().help("Enable or disable this route")
            TextField("Route name", text: $route.name).textFieldStyle(.plain).font(.title3.weight(.semibold))
            Spacer()
            RouteStatusBadge(kind: route.enabled ? (status?.kind ?? .idle) : .idle, enabled: route.enabled, engineOn: model.wantRunning)
            Menu {
                Button("Duplicate") { model.duplicateRoute(route.id) }
                Divider()
                Button("Delete Route", role: .destructive) { model.removeRoute(route.id) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    // MARK: Source

    private var sourceBox: some View {
        EndpointBox(title: "SOURCE", systemImage: "mic") {
            Picker("Device", selection: Binding(get: { inDev?.uid ?? route.input?.uid ?? "" }, set: setInput)) {
                Text("— Select input —").tag("")
                ForEach(model.inputDevices) { d in Text(deviceLabel(d, all: model.devices)).tag(d.uid) }
                if let ref = route.input, inDev == nil { Text("\(ref.name) (not connected)").tag(ref.uid) }
            }
            .labelsHidden()
            channelPicker(input: true)
            if let d = inDev {
                Text("\(d.inputChannels) ch · \(rate(d.nominalSampleRate)) · buffer \(d.bufferFrameSize)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(route.inputChannelsUsed, id: \.self) { ch in
                LiveChannelMeter(label: inDev?.channelName(ch, input: true) ?? "In \(ch + 1)", input: true,
                                 device: runtime?.inputDeviceID, channel: ch)
            }
        }
    }

    // MARK: Destination

    private var destinationBox: some View {
        EndpointBox(title: "DESTINATION", systemImage: "hifispeaker") {
            Picker("Device", selection: Binding(get: { outDev?.uid ?? route.output?.uid ?? "" }, set: setOutput)) {
                Text("— Select output —").tag("")
                ForEach(model.outputDevices) { d in Text(deviceLabel(d, all: model.devices)).tag(d.uid) }
                if let ref = route.output, outDev == nil { Text("\(ref.name) (not connected)").tag(ref.uid) }
            }
            .labelsHidden()
            channelPicker(input: false)
            if let d = outDev {
                Text("\(d.outputChannels) ch · \(rate(d.nominalSampleRate)) · buffer \(d.bufferFrameSize)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(route.outputChannelsUsed, id: \.self) { ch in
                LiveChannelMeter(label: outDev?.channelName(ch, input: false) ?? "Out \(ch + 1)", input: false,
                                 device: runtime?.outputDeviceID, channel: ch,
                                 trailing: AnyView(channelMuteButton(ch)))
            }
        }
    }

    private func channelMuteButton(_ ch: Int) -> some View {
        let muted = route.mutedOutputChannels.contains(ch)
        return Button {
            if muted { route.mutedOutputChannels.remove(ch) } else { route.mutedOutputChannels.insert(ch) }
        } label: {
            Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .foregroundStyle(muted ? .red : .secondary)
        }
        .buttonStyle(.borderless)
        .help(muted ? "Unmute this output channel" : "Mute this output channel")
    }

    @ViewBuilder
    private func channelPicker(input: Bool) -> some View {
        let dev = input ? inDev : outDev
        let count = input ? (dev?.inputChannels ?? 0) : (dev?.outputChannels ?? 0)
        let detected = ChannelSel.detect(route.crosspoints)
        let current: ChannelSel? = input ? detected?.0 : detected?.1
        Picker("Channels", selection: Binding<ChannelSel?>(
            get: { current },
            set: { newSel in
                guard let newSel else { showMatrix = true; return }
                let other: ChannelSel = input
                    ? (detected?.1 ?? ChannelSel.defaultFor(outDev?.outputChannels ?? 2))
                    : (detected?.0 ?? ChannelSel.defaultFor(inDev?.inputChannels ?? 2))
                route.crosspoints = input ? ChannelSel.crosspoints(newSel, other) : ChannelSel.crosspoints(other, newSel)
            })) {
            ForEach(ChannelSel.options(count: min(count, 64)), id: \.self) { sel in
                Text(sel.label(dev, input: input)).tag(Optional(sel))
            }
            if current == nil { Text(route.crosspoints.isEmpty ? "No channels" : "Custom matrix…").tag(ChannelSel?.none) }
        }
        .labelsHidden()
        .disabled(dev == nil)
    }

    private func setInput(_ uid: String) {
        guard let d = model.devices.first(where: { $0.uid == uid }) else { route.input = nil; return }
        route.input = DeviceRef(d)
        if !route.crosspoints.allSatisfy({ $0.input < d.inputChannels }) || route.crosspoints.isEmpty {
            route.crosspoints = Route.defaultCrosspoints(inputChannels: d.inputChannels, outputChannels: outDev?.outputChannels ?? 2)
        }
    }

    private func setOutput(_ uid: String) {
        guard let d = model.devices.first(where: { $0.uid == uid }) else { route.output = nil; return }
        route.output = DeviceRef(d)
        if !route.crosspoints.allSatisfy({ $0.output < d.outputChannels }) || route.crosspoints.isEmpty {
            route.crosspoints = Route.defaultCrosspoints(inputChannels: inDev?.inputChannels ?? 2, outputChannels: d.outputChannels)
        }
        route.mutedOutputChannels = route.mutedOutputChannels.filter { $0 < d.outputChannels }
    }

    // MARK: Processor

    private var processingDescription: (title: String, detail: String, color: Color) {
        if let rt = runtime {
            if !rt.resampling { return ("Bit-exact", "Shared clock, \(rate(rt.inRate)). No resampling.", .green) }
            if rt.inRate != rt.outRate {
                return ("Sample-rate conversion", "\(rate(rt.inRate)) → \(rate(rt.outRate)) with drift compensation", .blue)
            }
            return ("Drift compensation", "Independent clocks at \(rate(rt.inRate)); tiny adaptive resampling (ppm)", .blue)
        }
        guard let i = inDev, let o = outDev else { return ("—", "Select both devices", .secondary) }
        let locked = i.id == o.id || (i.clockDomain != 0 && i.clockDomain == o.clockDomain)
        if locked && i.nominalSampleRate == o.nominalSampleRate { return ("Bit-exact", "Shared clock, \(rate(i.nominalSampleRate))", .green) }
        if i.nominalSampleRate != o.nominalSampleRate {
            return ("Sample-rate conversion", "\(rate(i.nominalSampleRate)) → \(rate(o.nominalSampleRate)) with drift compensation", .blue)
        }
        return ("Drift compensation", "Independent clocks at \(rate(i.nominalSampleRate))", .blue)
    }

    private var processorBox: some View {
        let p = processingDescription
        return EndpointBox(title: "ROUTER", systemImage: "arrow.triangle.branch") {
            VStack(alignment: .leading, spacing: 2) {
                Text(p.title).font(.callout.weight(.semibold)).foregroundStyle(p.color)
                Text(p.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Text("Gain").font(.caption)
                Slider(value: $route.gainDB, in: Route.minGainDB...Route.maxGainDB, step: 0.5)
                Text(route.gainDB <= Route.minGainDB ? "−∞ dB" : String(format: "%+.1f dB", route.gainDB))
                    .font(.caption.monospacedDigit()).frame(width: 52, alignment: .trailing)
            }
            HStack(spacing: 6) {
                Toggle(isOn: $route.muted) { Label("Mute", systemImage: route.muted ? "speaker.slash.fill" : "speaker.fill") }
                    .toggleStyle(.button).tint(.red)
                Button("0 dB") { route.gainDB = 0 }.help("Reset gain to unity")
                Toggle(isOn: $route.testTone) { Label("Test tone", systemImage: "waveform") }
                    .toggleStyle(.button)
                    .help("Replace this route's signal with a 1 kHz sine at −20 dBFS to verify the output path")
            }
            .controlSize(.small)
            if let s = status?.stats, let rt = runtime {
                let internalMs = s.targetFillFrames / rt.inRate * 1000
                let total = (rt.inputDeviceLatency + rt.outputDeviceLatency) * 1000 + internalMs
                Text(String(format: "Latency ≈ %.1f ms (router %.1f + devices %.1f)", total, internalMs,
                            (rt.inputDeviceLatency + rt.outputDeviceLatency) * 1000))
                    .font(.caption).foregroundStyle(.secondary)
                if s.underruns + s.overruns > 0 {
                    Text("Dropouts: \(s.underruns) underruns, \(s.overruns) overruns").font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: Notes

    private var virtualSinkText: AttributedString {
        var md = "Audio goes to this virtual device's input. The software that created it processes the audio and plays the result on the output device chosen **in that software's own settings**. This app cannot read that choice or the software's state, so check them there."
        if let d = outDev, d.outputLatencyFrames > 0, d.nominalSampleRate > 0 {
            md += String(format: " The device reports %.1f ms of processing latency.", Double(d.outputLatencyFrames) / d.nominalSampleRate * 1000)
        }
        return (try? AttributedString(markdown: md)) ?? AttributedString(md)
    }

    private var virtualSinkNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill").foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 4) {
                Text("Sending to a virtual output device").font(.callout.weight(.semibold))
                Text(virtualSinkText).font(.caption).fixedSize(horizontal: false, vertical: true)
                Button("How to verify the processing is applied…") { showVirtualHelp = true }
                    .buttonStyle(.link).font(.caption)
            }
        }
        .padding(10)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .popover(isPresented: $showVirtualHelp) { VirtualSinkHelp().padding().frame(width: 420) }
    }

    @ViewBuilder
    private var messages: some View {
        let kind = status?.kind
        if case .error(let e) = kind { MessageRow(icon: "xmark.octagon.fill", color: .red, text: e) }
        if case .waiting(let e) = kind { MessageRow(icon: "hourglass", color: .orange, text: e + " Waiting for it to reconnect…") }
        ForEach((status?.warnings ?? model.staticWarnings(for: route)), id: \.self) { w in
            MessageRow(icon: "exclamationmark.triangle.fill", color: .orange, text: w)
        }
    }

    private func rate(_ r: Double) -> String {
        r.truncatingRemainder(dividingBy: 1000) == 0 ? "\(Int(r / 1000)) kHz" : String(format: "%.1f kHz", r / 1000)
    }
}

// MARK: - Pieces

struct EndpointBox<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage).font(.caption.weight(.bold)).foregroundStyle(.secondary)
            content
        }
        .padding(10)
        .frame(minWidth: 230, maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }
}

struct FlowArrow: View {
    var body: some View {
        Image(systemName: "arrow.right")
            .font(.title3.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 30)
            .padding(.top, 40)
    }
}

struct LiveChannelMeter: View {
    @Environment(AppModel.self) private var model
    let label: String
    let input: Bool
    let device: AudioObjectID?
    let channel: Int
    var trailing: AnyView? = nil

    var body: some View {
        ChannelMeterRow(label: label,
                        level: model.meters.level(input: input, device: device, channel: channel),
                        clipped: model.meters.clipped(input: input, device: device, channel: channel),
                        trailing: trailing)
    }
}

struct RouteStatusBadge: View {
    let kind: RouteStatus.Kind
    let enabled: Bool
    let engineOn: Bool

    var body: some View {
        let (text, color): (String, Color) = {
            if !enabled { return ("Disabled", .secondary) }
            switch kind {
            case .running: return ("Running", .green)
            case .waiting: return ("Waiting for device", .orange)
            case .error: return ("Error", .red)
            case .idle: return (engineOn ? "Starting…" : "Stopped", .secondary)
            }
        }()
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

struct MessageRow: View {
    let icon: String
    let color: Color
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct VirtualSinkHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Verifying a virtual output device").font(.headline)
            Text("Signal flow: this router → virtual output device → the software that created it (processing) → the output chosen in that software.")
                .font(.callout)
            Text("1. In the virtual device's software, set the **output device** and enable its processing.\n2. In this app, route your input to the virtual device and press Start.\n3. Play something. Toggle the software's processing on and off (bypass): the sound should change audibly. If it doesn't, the software is not processing this signal.\n4. Mute this route: the sound on the physical device must stop. If it continues, another app or route is also feeding that device.\n5. Do not also route the same input directly to that output device unless you want to hear it twice.\n6. If the software's output is set to a loopback device that feeds this app's input, you create a feedback loop.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text("This app cannot read the software's internal state, so these checks are manual.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Matrix

struct MatrixView: View {
    @Binding var route: Route
    let inDev: AudioDeviceInfo?
    let outDev: AudioDeviceInfo?

    var body: some View {
        let ins = min(inDev?.inputChannels ?? 0, 64)
        let outs = min(outDev?.outputChannels ?? 0, 64)
        if ins == 0 || outs == 0 {
            Text("Select an input and an output device first.").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Rows: input channels · Columns: output channels. Multiple inputs on one output are summed.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") { route.crosspoints = [] }
                    Button("Identity") {
                        route.crosspoints = (0..<min(ins, outs)).map { Crosspoint(input: $0, output: $0) }
                    }
                }
                .controlSize(.small)
                ScrollView([.horizontal, .vertical]) {
                    Grid(horizontalSpacing: 4, verticalSpacing: 2) {
                        GridRow {
                            Text("")
                            ForEach(0..<outs, id: \.self) { o in
                                Text("\(o + 1)").font(.caption2.monospacedDigit()).frame(width: 22)
                            }
                        }
                        ForEach(0..<ins, id: \.self) { i in
                            GridRow {
                                Text(inDev?.channelName(i, input: true) ?? "In \(i + 1)")
                                    .font(.caption).lineLimit(1).frame(width: 90, alignment: .leading)
                                ForEach(0..<outs, id: \.self) { o in
                                    Toggle("", isOn: binding(i, o)).toggleStyle(.checkbox).labelsHidden().frame(width: 22)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
    }

    private func binding(_ i: Int, _ o: Int) -> Binding<Bool> {
        Binding(
            get: { route.crosspoints.contains { $0.input == i && $0.output == o } },
            set: { on in
                if on {
                    if !route.crosspoints.contains(where: { $0.input == i && $0.output == o }) {
                        route.crosspoints.append(Crosspoint(input: i, output: o))
                    }
                } else {
                    route.crosspoints.removeAll { $0.input == i && $0.output == o }
                }
            })
    }
}
