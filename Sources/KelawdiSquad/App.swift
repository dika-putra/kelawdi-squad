import SwiftUI

// No SwiftUI App/Scene: a Settings scene is what opened the blank Settings window.
@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

private final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
    var onResignKey: (() -> Void)?
    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

// Own panel under the status item instead of MenuBarExtra/NSPopover: both re-anchored wrongly when the content size changed.
// The anchor is read once, when the icon is clicked, and every resize is positioned from it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = Store(demo: CommandLine.arguments.contains("--screenshot"))
    private let panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let host: NSHostingController<AnyView>
    private var item: NSStatusItem?
    private var anchor: NSRect?
    private var anchorScreen: NSScreen?
    private var lastHidden = Date.distantPast
    private var sizeObserver: NSKeyValueObservation?

    override init() {
        host = NSHostingController(rootView: AnyView(EmptyView()))
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = menuBarImage()
        item.button?.target = self
        item.button?.action = #selector(toggle)
        self.item = item

        host.rootView = AnyView(ContentView(close: { [weak self] in self?.hide() }).environmentObject(store))
        host.sizingOptions = .preferredContentSize

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        host.view.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: background.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.onResignKey = { [weak self] in self?.hide() }

        if let i = CommandLine.arguments.firstIndex(of: "--screenshot"), i + 1 < CommandLine.arguments.count {
            captureScreenshots(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
        }

        sizeObserver = host.observe(\.preferredContentSize, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.resize() }
        }
    }

    // Template image: macOS tints it for light/dark menu bars. The PNG is 36 px for an 18 pt icon.
    private func menuBarImage() -> NSImage? {
        if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"), let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            return image
        }
        return NSImage(systemSymbolName: "person.2.circle", accessibilityDescription: "Kelawdi Squad")
    }

    // README screenshots: shows the panel with demo data over a plain backdrop (so the blur never samples the real
    // desktop), captures this app's own window, and quits. Usage: KelawdiSquad --screenshot <dir>
    private func captureScreenshots(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let backdrop = NSWindow(contentRect: NSRect(x: 500, y: 300, width: 460, height: 640), styleMask: .borderless, backing: .buffered, defer: false)
        backdrop.backgroundColor = NSColor(white: 0.94, alpha: 1)
        backdrop.level = .floating
        backdrop.orderFrontRegardless()
        anchor = NSRect(x: 710, y: 930, width: 32, height: 24)
        anchorScreen = NSScreen.main

        func snap(_ name: String) {
            guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(panel.windowNumber),
                                                      [.boundsIgnoreFraming, .bestResolution]) else { return }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
        }
        func show() {
            resize()
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(nil)  // no focus ring on the first button
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { show() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { snap("popup.png") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            self.host.rootView = AnyView(ContentView(close: {}, startManaging: true).environmentObject(self.store).id("manage"))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { show() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { snap("manage.png") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.4) { NSApp.terminate(nil) }
    }

    @objc private func toggle() {
        // Clicking the icon while the panel is open first resigns key (hide), then lands here; do not reopen it.
        if panel.isVisible || Date().timeIntervalSince(lastHidden) < 0.25 {
            hide()
            return
        }
        guard let window = item?.button?.window else { return }
        anchor = window.frame
        anchorScreen = window.screen
        store.refreshRunning()
        store.checkForUpdate()
        resize()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(nil)  // no focus ring on the first button
    }

    private func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        lastHidden = Date()
    }

    private func resize() {
        let size = host.preferredContentSize
        guard size.width > 0, size.height > 0, let anchor else { return }
        panel.setContentSize(size)
        var x = anchor.midX - size.width / 2
        if let visible = anchorScreen?.visibleFrame {
            x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        }
        panel.setFrameOrigin(NSPoint(x: x, y: anchor.minY - size.height - 4))
    }
}
