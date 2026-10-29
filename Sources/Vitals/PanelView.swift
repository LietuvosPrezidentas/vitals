import SwiftUI
import Charts
import ServiceManagement

/// Orange is the only colour, and it means one thing: running hot or under strain.
private let hot = Color.orange

struct PanelView: View {
    let monitor: Monitor
    var showSensors: () -> Void = {}
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            temperatures
            Divider()
            fanAndPower
            Divider()
            chips
            Divider()
            memoryDiskNetwork
            Divider()
            topApps
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 340)
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(monitor.model).font(.system(size: 13, weight: .semibold))
            Spacer()
            let state = Fmt.thermal(monitor.thermal)
            Text(state.text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(state.strained ? hot : .secondary)
        }
    }

    private var temperatures: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(Fmt.temp(monitor.chipHottest))
                        .font(.system(size: 44, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(isHot(monitor.chipHottest, 85) ? hot : .primary)
                    Text("hottest spot on the chip").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Sparkline(points: monitor.history, tint: isHot(monitor.chipHottest, 85) ? hot : .primary)
                    .frame(width: 150, height: 46)
            }
            HStack(spacing: 0) {
                MiniStat(label: "Chip avg", value: Fmt.temp(monitor.chipAverage), hot: isHot(monitor.chipAverage, 80))
                MiniStat(label: "SSD", value: Fmt.temp(monitor.ssd), hot: isHot(monitor.ssd, 70))
                MiniStat(label: "Battery", value: Fmt.temp(monitor.batteryTemp), hot: isHot(monitor.batteryTemp, 40))
            }
        }
    }

    private var fanAndPower: some View {
        VStack(alignment: .leading, spacing: 10) {
            if monitor.fans.isEmpty {
                Row(label: "Fan", value: "None", detail: "this Mac cools without a fan")
            }
            ForEach(Array(monitor.fans.enumerated()), id: \.offset) { i, fan in
                let label = monitor.fans.count > 1 ? "Fan \(i + 1)" : "Fan"
                if fan.spinning {
                    Row(label: label, value: "\(Fmt.int(fan.rpm)) rpm",
                        detail: "\(Int((fan.rpm / max(fan.max, 1) * 100).rounded()))% of max speed")
                    Bar(value: fan.rpm / max(fan.max, 1))
                } else {
                    Row(label: label, value: "Off", detail: "cool enough to stay silent")
                }
            }
            if let w = monitor.systemWatts {
                Row(label: "Power draw", value: "\(Fmt.watts(w))", detail: "whole Mac, right now")
            }
            if let b = monitor.battery {
                Row(label: "Battery", value: "\(b.percent)%", detail: batteryStatus(b))
                let health = monitor.batteryHealth.map { "\($0)% health · " } ?? ""
                Text("\(health)\(b.cycles) charge cycles")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var chips: some View {
        VStack(alignment: .leading, spacing: 10) {
            Row(label: "CPU", value: Fmt.percent(monitor.cpu), detail: "all \(monitor.cores.count) cores")
            CoreBars(cores: monitor.cores, superName: monitor.superName)
            if let g = monitor.gpu {
                Row(label: "GPU", value: Fmt.percent(g), detail: nil)
                Bar(value: g)
            }
        }
    }

    private var memoryDiskNetwork: some View {
        VStack(alignment: .leading, spacing: 10) {
            Row(label: "Memory",
                value: "\(Fmt.gb(monitor.memUsed, binary: true)) of \(Fmt.gb(monitor.memTotal, decimals: 0, binary: true))",
                detail: nil)
            Bar(value: monitor.memUsed / max(monitor.memTotal, 1), tint: monitor.memPressure > 1 ? hot : .primary)
            HStack(spacing: 0) {
                Text("pressure ").foregroundStyle(.secondary)
                Text(Fmt.pressure(monitor.memPressure)).foregroundStyle(monitor.memPressure > 1 ? hot : .secondary)
                Text(" · swap \(Fmt.gb(monitor.swapUsed, binary: true))").foregroundStyle(.secondary)
            }
            .font(.system(size: 11))

            Row(label: "Disk", value: "\(Fmt.gb(monitor.diskFree, decimals: 0)) free",
                detail: "\(Fmt.gb(monitor.diskTotal - monitor.diskFree, decimals: 0)) used ·")
            Bar(value: monitor.diskTotal > 0 ? 1 - monitor.diskFree / monitor.diskTotal : 0)

            HStack {
                Text("Network").font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
                Label(Fmt.speed(monitor.netDown), systemImage: "arrow.down")
                Label(Fmt.speed(monitor.netUp), systemImage: "arrow.up")
            }
            .font(.system(size: 13, weight: .semibold))
            .monospacedDigit()
        }
    }

    private var topApps: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Busiest apps").font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
                Text("100% = one core").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            if monitor.topApps.isEmpty {
                Text("reading…").font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            ForEach(monitor.topApps.prefix(5)) { app in
                HStack {
                    Text(app.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text("\(Int(app.cpu.rounded()))%").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("All \(monitor.sensors.count) temperature sensors…", action: showSensors)
                .buttonStyle(.link)
                .foregroundStyle(.primary)
                .font(.system(size: 12))

            HStack {
                Toggle("Open at login", isOn: $openAtLogin)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .onChange(of: openAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            openAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .font(.system(size: 12))
            }
        }
    }

    // MARK: Helpers

    private func isHot(_ v: Double?, _ limit: Double) -> Bool { (v ?? 0) >= limit }

    private func batteryStatus(_ b: Battery) -> String {
        if b.pluggedIn {
            let adapter = b.adapterWatts.map { " (\($0) W charger)" } ?? ""
            if b.charging { return "charging\(adapter)" }
            if b.full { return "full\(adapter)" }
            return "plugged in, not charging\(adapter)"
        }
        if let m = b.minutesLeft { return "\(m / 60) h \(m % 60) min left" }
        return "on battery"
    }
}

/// Every sensor the chip reports, live, in its own window: too long a list for the panel.
struct SensorsView: View {
    let monitor: Monitor

    var body: some View {
        let hottest = monitor.sensors.map(\.value).max() ?? 1
        List(monitor.sensors) { s in
            HStack(spacing: 10) {
                Text(s.name).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Bar(value: s.value / max(hottest, 1), tint: s.value >= 85 ? hot : .primary)
                    .frame(width: 90)
                Text(String(format: "%.1f°", s.value))
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(s.value >= 85 ? hot : .primary)
                    .frame(width: 48, alignment: .trailing)
            }
        }
        .frame(minWidth: 340, minHeight: 420)
        .safeAreaInset(edge: .bottom) {
            Text("tdie = inside the chip · tdev = other parts of the board · NAND = the SSD · gas gauge = battery")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.bar)
        }
    }
}

// MARK: - Pieces

private struct Row: View {
    let label: String
    let value: String
    let detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 13)).foregroundStyle(.secondary)
            Spacer()
            if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
            Text(value).font(.system(size: 13, weight: .semibold)).monospacedDigit()
        }
    }
}

private struct MiniStat: View {
    let label: String
    let value: String
    let hot: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 17, weight: .bold)).monospacedDigit()
                .foregroundStyle(hot ? Color.orange : .primary)
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Bar: View {
    let value: Double
    var tint: Color = .primary

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(tint.opacity(0.85))
                    .frame(width: max(3, g.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 5)
        .animation(.easeOut(duration: 0.4), value: value)
    }
}

private struct CoreBars: View {
    let cores: [Core]
    let superName: String

    var body: some View {
        let groups = [(superName, cores.filter { !$0.efficiency }), ("Efficiency", cores.filter(\.efficiency))]
        // Fixed-width bars, so a group of 4 and a group of 6 share one scale.
        let barWidth = max(8, (308 - 14 - 3 * Double(max(cores.count - 2, 0))) / Double(max(cores.count, 1)))
        HStack(alignment: .top, spacing: 14) {
            ForEach(groups, id: \.0) { name, group in
                if !group.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 3) {
                            ForEach(group) { core in
                                ZStack(alignment: .bottom) {
                                    RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.1))
                                    RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.85))
                                        .frame(height: max(2, 30 * core.load))
                                }
                                .frame(width: barWidth, height: 30)
                            }
                        }
                        Text("\(group.count) \(name)").font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
            }
        }
        .animation(.easeOut(duration: 0.4), value: cores.map(\.load))
    }
}

private struct Sparkline: View {
    let points: [(t: Date, v: Double)]
    let tint: Color

    var body: some View {
        let values = points.map(\.v)
        let lo = (values.min() ?? 0) - 2, hi = (values.max() ?? 1) + 2
        let now = points.last?.t ?? Date()
        // Until five minutes have been recorded, stretch what there is across the full width.
        let start = max(points.first?.t ?? now, now.addingTimeInterval(-300))
        let span = now.timeIntervalSince(start)
        let caption = span >= 290 ? "last 5 min" : span < 60 ? "last \(Int(span)) s" : "last \(Int(span / 60)) min"
        Chart(Array(points.enumerated()), id: \.offset) { _, p in
            AreaMark(x: .value("t", p.t), yStart: .value("lo", lo), yEnd: .value("°", p.v))
                .foregroundStyle(tint.opacity(0.06))
            LineMark(x: .value("t", p.t), y: .value("°", p.v))
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
        }
        .chartXScale(domain: start...max(now, start.addingTimeInterval(1)))
        .chartYScale(domain: lo...hi)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .overlay(alignment: .topTrailing) {
            Text(caption).font(.system(size: 9)).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Formatting

enum Fmt {
    static func temp(_ v: Double?) -> String { v.map { "\(Int($0.rounded()))°" } ?? "--" }
    static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
    static func int(_ v: Double) -> String { Int(v.rounded()).formatted(.number) }
    static func watts(_ v: Double) -> String { v < 10 ? String(format: "%.1f W", v) : "\(Int(v.rounded())) W" }

    /// Disks count in thousands (like Finder); memory counts in 1024s (like Activity Monitor, so 24 GB reads 24).
    static func gb(_ bytes: Double, decimals: Int = 1, binary: Bool = false) -> String {
        let gb = bytes / (binary ? 1_073_741_824 : 1_000_000_000)
        return gb >= 1000 ? String(format: "%.1f TB", gb / 1000) : String(format: "%.\(decimals)f GB", gb)
    }

    static func speed(_ bps: Double) -> String {
        switch bps {
        case ..<1_000: return "0 KB/s"
        case ..<1_000_000: return "\(Int(bps / 1_000)) KB/s"
        default: return String(format: "%.1f MB/s", bps / 1_000_000)
        }
    }

    static func pressure(_ level: Int) -> String {
        switch level {
        case 4: return "critical"
        case 2: return "high"
        default: return "normal"
        }
    }

    static func thermal(_ s: ProcessInfo.ThermalState) -> (text: String, strained: Bool) {
        switch s {
        case .nominal: return ("Cool", false)
        case .fair: return ("Warm", false)
        case .serious: return ("Hot, slowing down", true)
        case .critical: return ("Very hot, slowed down", true)
        @unknown default: return ("", false)
        }
    }
}
