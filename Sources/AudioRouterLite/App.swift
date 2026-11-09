import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { SnapshotRunner.run(model: AppModel.shared) }
        // Needed when launched as a bare executable (e.g. `swift run`); harmless inside the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.shutdown() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct AudioRouterLiteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        // Single main window; state restoration disabled so a crash/force-quit can never
        // leave the app relaunching with no window.
        Window("Audio Router Lite", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 640)
        }
        .restorationBehavior(.disabled)
        .commands {
            CommandMenu("Audio") {
                Button(model.wantRunning ? "Stop Routing" : "Start Routing") { model.toggle() }
                    .keyboardShortcut("r", modifiers: [.command])
                Button("Add Route") { model.addRoute() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button("Refresh Devices") { model.refreshDevices() }
            }
        }
    }
}
