import AudioRouterKit
import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case routing = "Routing"
    case devices = "Devices"
    case monitor = "Monitoring"
    case settings = "Settings"
    case diagnostics = "Diagnostics"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .routing: return "point.3.connected.trianglepath.dotted"
        case .devices: return "hifispeaker.2"
        case .monitor: return "waveform.path.ecg"
        case .settings: return "slider.horizontal.3"
        case .diagnostics: return "stethoscope"
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem?

    init(initialSelection: SidebarItem = .routing) {
        _selection = State(initialValue: initialSelection)
    }

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.rawValue, systemImage: item.icon).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            VStack(spacing: 0) {
                StatusBanner()
                Group {
                    switch selection ?? .routing {
                    case .routing: RoutingView()
                    case .devices: DevicesView()
                    case .monitor: MonitorView()
                    case .settings: SettingsView()
                    case .diagnostics: DiagnosticsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) { StatePill(state: model.state) }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.toggle()
                } label: {
                    Label(model.wantRunning ? "Stop" : "Start", systemImage: model.wantRunning ? "stop.fill" : "play.fill")
                        .labelStyle(.titleAndIcon)
                        .frame(minWidth: 70)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.wantRunning ? .red : .green)
                .help("Start or stop all enabled routes (⌘R)")
            }
        }
    }
}

struct StatePill: View {
    let state: EngineState

    var color: Color {
        switch state {
        case .stopped: return .secondary
        case .starting: return .blue
        case .running: return .green
        case .recovering: return .orange
        case .error: return .red
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(state.title).font(.callout.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(color.opacity(0.15), in: Capsule())
        .help(state.detail ?? state.title)
    }
}

/// Explains Error / Recovering states and protection trips at the top of every page.
struct StatusBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if let detail = model.state.detail {
                banner(icon: model.state == .error(detail) ? "exclamationmark.octagon.fill" : "arrow.triangle.2.circlepath",
                       color: model.state == .error(detail) ? .red : .orange, text: detail) {
                    if detail.contains("Microphone") {
                        Button("Open Privacy Settings") { model.openPrivacySettings() }
                    }
                }
            }
            if model.protectionTripped {
                banner(icon: "speaker.slash.fill", color: .red,
                       text: "An output was muted by feedback protection after more than 1.5 s of continuous full-scale signal. Check for feedback loops or reduce gain.") {
                    Button("Unmute Outputs") { model.resetProtection() }
                }
            }
        }
    }

    @ViewBuilder
    private func banner<A: View>(icon: String, color: Color, text: String, @ViewBuilder actions: () -> A) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer()
            actions()
        }
        .padding(10)
        .background(color.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }
}
