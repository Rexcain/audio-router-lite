import AppKit
import SwiftUI

/// Developer aid: `AudioRouterLite --snapshot <dir> [--snapshot-start]` renders every page of the
/// real UI offscreen to PNG files and quits. Used to check the UI without screen-recording access.
@MainActor
enum SnapshotRunner {
    static var outputDir: String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--snapshot"), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    static func run(model: AppModel) {
        guard let dir = outputDir else { return }
        let startFirst = CommandLine.arguments.contains("--snapshot-start")
        if startFirst { model.start() }
        let a = CommandLine.arguments
        let delay = a.firstIndex(of: "--snapshot-delay").flatMap { $0 + 1 < a.count ? Double(a[$0 + 1]) : nil } ?? (startFirst ? 4 : 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            render(model: model, dir: dir, items: SidebarItem.allCases)
        }
    }

    private static func render(model: AppModel, dir: String, items: [SidebarItem]) {
        guard let item = items.first else {
            renderBare(model: model, dir: dir)
            return
        }
        let size = NSSize(width: 1280, height: 860)
        let host = NSHostingView(rootView: ContentView(initialSelection: item).environment(model))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))  // offscreen
        window.level = .floating
        window.orderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            host.layoutSubtreeIfNeeded()
            host.display()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                let name = item.rawValue.lowercased().replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "&", with: "and")
                let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                print("snapshot: \(url.path)")
            }
            window.orderOut(nil)
            render(model: model, dir: dir, items: Array(items.dropFirst()))
        }
    }

    /// Routing and Monitoring pages without the split view / toolbar chrome (which offscreen capture cannot always draw).
    private static func renderBare(model: AppModel, dir: String, pages: [(String, AnyView)]? = nil) {
        let pages = pages ?? [("routing-bare", AnyView(RoutingView())), ("monitoring-bare", AnyView(MonitorView()))]
        guard let (name, view) = pages.first else {
            model.shutdown()
            NSApp.terminate(nil)
            return
        }
        let host = NSHostingView(rootView: view.environment(model).frame(width: 1060, height: 760)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(x: 0, y: 0, width: 1060, height: 760)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.orderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            host.layoutSubtreeIfNeeded()
            host.display()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                print("snapshot: \(url.path)")
            }
            window.orderOut(nil)
            renderBare(model: model, dir: dir, pages: Array(pages.dropFirst()))
        }
    }
}
