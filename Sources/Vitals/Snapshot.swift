import SwiftUI

/// For checking the app without screen-recording permission: launched with VITALS_SNAPSHOT=<folder>
/// (`open --env VITALS_SNAPSHOT=/some/folder ~/Applications/Vitals.app`), it waits, then writes a picture of each
/// of its own visible windows and a text dump of every reading into that folder. Off unless that variable is set.
@MainActor
enum Snapshot {
    static func scheduleIfAsked(_ monitor: Monitor, button: NSStatusBarButton?) {
        benchIfAsked(monitor)
        guard let dir = ProcessInfo.processInfo.environment["VITALS_SNAPSHOT"], !dir.isEmpty else { return }
        // Click our own menu bar button, the way a person would, so the real panel opens.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { button?.performClick(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { write(monitor, to: URL(fileURLWithPath: dir)) }
    }

    /// VITALS_BENCH=open|closed VITALS_BENCH_OUT=<file>: sample for 60 s as if the panel were open or closed
    /// (nothing drawn), write the CPU time used, including the `ps` it starts, then quit.
    private static func benchIfAsked(_ m: Monitor) {
        let env = ProcessInfo.processInfo.environment
        guard let mode = env["VITALS_BENCH"], let out = env["VITALS_BENCH_OUT"] else { return }
        m.panelOpen = mode == "open"
        func cpu() -> Double {
            var me = rusage(), kids = rusage()
            getrusage(RUSAGE_SELF, &me); getrusage(RUSAGE_CHILDREN, &kids)
            let s = { (r: rusage) in Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1e6 }
            return s(me) + s(kids)
        }
        let start = cpu()
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            let used = cpu() - start
            try? String(format: "%@: %.3f s CPU in 60 s = %.2f%% of one core\n", mode, used, used / 60 * 100)
                .write(toFile: out, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    private static func write(_ m: Monitor, to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        writeReadings(m, to: dir)
        // The real panel, as opened by the click above (its blurred background may draw flat here).
        for (i, window) in NSApp.windows.enumerated() where window.isVisible && !(window.className.contains("StatusBar")) {
            guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("real-window-\(i).png"))
        }
        // Then draw the panel into an off-screen window of our own, once light and once dark.
        m.panelOpen = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            for (name, look) in [("panel-light", NSAppearance.Name.aqua), ("panel-dark", .darkAqua)] {
                render(PanelView(monitor: m), appearance: NSAppearance(named: look), to: dir.appendingPathComponent("\(name).png"))
            }
            render(SensorsView(monitor: m).frame(width: 380, height: 560), appearance: NSAppearance(named: .darkAqua),
                   to: dir.appendingPathComponent("sensors-dark.png"))
        }
    }

    private static func render(_ view: some View, appearance: NSAppearance?, to url: URL) {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = appearance
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: host.frame.size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
            window.orderOut(nil)
        }
    }

    private static func writeReadings(_ m: Monitor, to dir: URL) {
        let fans = m.fans.map { "rpm=\($0.rpm) min=\($0.min) max=\($0.max)" }.joined(separator: "; ")
        let b = m.battery
        let lines = [
            "time \(Date()) panelOpen \(m.panelOpen)",
            "windows " + NSApp.windows.map { "\(type(of: $0)) visible=\($0.isVisible) key=\($0.isKeyWindow) \(Int($0.frame.width))x\(Int($0.frame.height))" }
                .joined(separator: "; "),
            "chipHottest \(m.chipHottest ?? -1) chipAverage \(m.chipAverage ?? -1) ssd \(m.ssd ?? -1) batteryTemp \(m.batteryTemp ?? -1)",
            "sensors \(m.sensors.count) history \(m.history.count) thermal \(m.thermal.rawValue)",
            "fans \(fans)",
            "systemWatts \(m.systemWatts ?? -1)",
            "battery percent=\(b?.percent ?? -1) plugged=\(b?.pluggedIn ?? false) charging=\(b?.charging ?? false) cycles=\(b?.cycles ?? -1) adapter=\(b?.adapterWatts ?? -1) health=\(m.batteryHealth ?? -1)",
            "cpu \(m.cpu) cores \(m.cores.map { String(format: "%@%.2f", $0.efficiency ? "E" : "S", $0.load) }.joined(separator: " "))",
            "gpu \(m.gpu ?? -1)",
            "mem used=\(m.memUsed) total=\(m.memTotal) swap=\(m.swapUsed) pressure=\(m.memPressure)",
            "disk free=\(m.diskFree) total=\(m.diskTotal)",
            "net down=\(m.netDown) up=\(m.netUp)",
            "top \(m.topApps.map { "\($0.name)=\($0.cpu)" }.joined(separator: ", "))",
        ]
        try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("readings.txt"), atomically: true, encoding: .utf8)
    }
}
