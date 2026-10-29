import SwiftUI

@main
struct VitalsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    // Everything lives in the menu bar item the delegate makes; this app has no windows of its own.
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let monitor = Monitor()
    private var item: NSStatusItem!
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.imagePosition = .imageLeading

        let host = NSHostingController(rootView: PanelView(monitor: monitor, showSensors: { [weak self] in self?.showSensors() }))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.delegate = self

        monitor.onTick = { [weak self] in self?.updateLabel() }
        updateLabel()
        Snapshot.scheduleIfAsked(monitor, button: item.button)
    }

    /// The menu bar shows the hottest chip sensor; the icon turns into a fan while the fan spins.
    private var shownLabel = ""

    private func updateLabel() {
        guard let button = item.button else { return }
        let spinning = monitor.fans.contains(where: \.spinning)
        let text = Fmt.temp(monitor.chipHottest)
        // Redrawing the menu bar costs more than reading the sensors, so only redraw on a change.
        guard "\(spinning)\(text)" != shownLabel else { return }
        shownLabel = "\(spinning)\(text)"
        let icon = NSImage(systemSymbolName: spinning ? "fan.fill" : "thermometer.medium", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        icon?.isTemplate = true
        button.image = icon
        button.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)])
    }

    @objc private func toggle() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate()
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private var sensorsWindow: NSWindow?

    func showSensors() {
        popover.performClose(nil)
        if sensorsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SensorsView(monitor: monitor)))
            window.title = "Temperature sensors"
            window.setContentSize(NSSize(width: 380, height: 560))
            window.isReleasedWhenClosed = false
            window.center()
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.monitor.sensorsOpen = false }
            }
            sensorsWindow = window
        }
        monitor.sensorsOpen = true
        NSApp.activate()
        sensorsWindow?.makeKeyAndOrderFront(nil)
    }

    func popoverDidShow(_ notification: Notification) { monitor.panelOpen = true }
    func popoverDidClose(_ notification: Notification) { monitor.panelOpen = false }
}
