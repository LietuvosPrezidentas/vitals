import Foundation
import Darwin
import IOKit
import IOKit.ps
import Observation
import Sensors

struct Sensor: Identifiable {
    var id: String { name }
    let name: String
    let value: Double
}

struct Fan {
    let rpm: Double
    let min: Double
    let max: Double
    var spinning: Bool { rpm > 50 }
}

struct Core: Identifiable {
    let id: Int
    let efficiency: Bool
    let load: Double  // 0...1
}

struct TopApp: Identifiable {
    let id: Int  // pid
    let name: String
    let cpu: Double  // percent of one core, like Activity Monitor
}

struct Battery {
    var percent: Int
    var pluggedIn: Bool
    var charging: Bool
    var full: Bool
    var cycles: Int
    var adapterWatts: Int?
    var minutesLeft: Int?  // nil when plugged in or still estimating
}

/// Samples everything every two seconds. Cheap reads only; the process list runs only while the panel is open.
@MainActor @Observable
final class Monitor {
    // Temperatures, °C
    var chipHottest: Double?
    var chipAverage: Double?
    var ssd: Double?
    var batteryTemp: Double?
    var sensors: [Sensor] = []
    var history: [(t: Date, v: Double)] = []  // hottest chip sensor, last five minutes

    var fans: [Fan] = []
    var thermal: ProcessInfo.ThermalState = .nominal

    // Power, watts
    var systemWatts: Double?
    var battery: Battery?
    var batteryHealth: Int?  // the "Maximum Capacity" System Settings shows

    var cpu: Double = 0  // 0...1, all cores
    var cores: [Core] = []
    var gpu: Double?  // 0...1

    var memUsed: Double = 0
    let memTotal = Double(ProcessInfo.processInfo.physicalMemory)
    var swapUsed: Double = 0
    var memPressure = 1  // 1 normal, 2 warning, 4 critical

    var diskFree: Double = 0
    var diskTotal: Double = 0

    var netDown: Double = 0  // bytes per second
    var netUp: Double = 0

    var topApps: [TopApp] = []
    @ObservationIgnored var onTick: (() -> Void)?
    var panelOpen = false { didSet { if panelOpen != oldValue { lookingChanged() } } }
    var sensorsOpen = false { didSet { if sensorsOpen != oldValue { lookingChanged() } } }
    /// Someone is looking at the numbers. Otherwise only the menu bar needs feeding: chip temperature and fan.
    private var looking: Bool { panelOpen || sensorsOpen }

    let model = Monitor.machineName()
    let superName = Monitor.sysctlString("hw.perflevel0.name") ?? "Performance"
    let efficiencyCount = Monitor.sysctlInt("hw.perflevel1.logicalcpu") ?? 0

    private var timer: Timer?
    private var lastTicks: [(busy: UInt64, total: UInt64)] = []
    private var lastNet: [String: (rx: UInt32, tx: UInt32)] = [:]
    private var lastNetTime = Date()
    private var tickCount = 0
    private var lastDisk = Date.distantPast
    private var lastHealth = Date.distantPast

    init() {
        _ = vt_smc_open()
        _ = vt_hid_open()
        tick()
        schedule()
    }

    /// Every 2 s while the panel is open, every 5 s while it is closed. The tolerance lets macOS fold
    /// these wake-ups into ones it was doing anyway, which is most of what saves battery.
    private func schedule() {
        timer?.invalidate()
        let t = Timer(timeInterval: looking ? 2 : 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = looking ? 0.2 : 1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func lookingChanged() {
        schedule()
        if looking { tick() }
    }

    private func tick() {
        tickCount += 1
        readTemperatures(all: looking)
        readFans()
        thermal = ProcessInfo.processInfo.thermalState
        if looking {
            readPower()
            readCPU()
            readGPU()
            readMemory()
            readNetwork()
            if Date().timeIntervalSince(lastDisk) > 30 { readDisk() }
            if Date().timeIntervalSince(lastHealth) > 1800 { refreshHealth() }
            if panelOpen && tickCount % 2 == 1 { refreshTopApps() }
        }
        onTick?()
    }

    // MARK: Temperatures

    private func readTemperatures(all: Bool) {
        var buf = [VTReading](repeating: VTReading(), count: 128)
        let n = Int(vt_hid_read(&buf, Int32(buf.count), all ? 0 : 1))
        var byName: [String: [Double]] = [:]
        for r in buf.prefix(n) {
            let name = withUnsafeBytes(of: r.name) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
            // "tcal" is a calibration constant, not a reading; anything outside 1-150 °C is a dead sensor.
            guard !name.isEmpty, !name.contains("tcal"), r.value > 1, r.value < 150 else { continue }
            byName[name, default: []].append(r.value)
        }
        let read = byName.map { Sensor(name: $0.key, value: $0.value.reduce(0, +) / Double($0.value.count)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let die = read.filter { $0.name.contains("tdie") }.map(\.value)
        chipHottest = die.max()
        chipAverage = die.isEmpty ? nil : die.reduce(0, +) / Double(die.count)
        if all {
            sensors = read
            ssd = read.first { $0.name.hasPrefix("NAND") }?.value
            batteryTemp = read.first { $0.name.hasPrefix("gas gauge") }?.value
        }

        if let h = chipHottest {
            let now = Date()
            history.append((now, h))
            history.removeAll { now.timeIntervalSince($0.t) > 300 }
        }
    }

    // MARK: Fans

    private func readFans() {
        var count = 0.0
        guard vt_smc_read("FNum", &count) == 0, count > 0 else { fans = []; return }
        fans = (0..<Int(count)).map { i in
            var rpm = 0.0, lo = 0.0, hi = 0.0
            _ = vt_smc_read("F\(i)Ac", &rpm)
            _ = vt_smc_read("F\(i)Mn", &lo)
            _ = vt_smc_read("F\(i)Mx", &hi)
            return Fan(rpm: max(0, rpm), min: lo, max: hi)
        }
    }

    // MARK: Power and battery

    private func readPower() {
        var w = 0.0
        systemWatts = vt_smc_read("PSTR", &w) == 0 ? w : nil

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { battery = nil; return }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any] else { return }

        let plugged = d["ExternalConnected"] as? Bool ?? false
        var minutes: Int?
        if !plugged {
            let est = IOPSGetTimeRemainingEstimate()
            if est > 0 { minutes = Int(est / 60) }
        }
        battery = Battery(
            percent: d["CurrentCapacity"] as? Int ?? 0,
            pluggedIn: plugged,
            charging: d["IsCharging"] as? Bool ?? false,
            full: d["FullyCharged"] as? Bool ?? false,
            cycles: d["CycleCount"] as? Int ?? 0,
            adapterWatts: plugged ? (d["AdapterDetails"] as? [String: Any])?["Watts"] as? Int : nil,
            minutesLeft: minutes)
    }

    /// System Settings' "Maximum Capacity" is not in the registry, so read it the way System Information does.
    private func refreshHealth() {
        lastHealth = Date()
        Task.detached {
            let out = Monitor.run("/usr/sbin/system_profiler", ["SPPowerDataType"])
            let value = out.split(separator: "\n")
                .first { $0.contains("Maximum Capacity") }
                .flatMap { Int($0.filter(\.isNumber)) }
            await MainActor.run { self.batteryHealth = value }
        }
    }

    // MARK: CPU and GPU

    private func readCPU() {
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        var cpuCount: natural_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        var ticks: [(busy: UInt64, total: UInt64)] = []
        for i in 0..<Int(cpuCount) {
            let base = i * Int(CPU_STATE_MAX)
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let sys = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            ticks.append((user + sys + nice, user + sys + nice + idle))
        }
        if lastTicks.count == ticks.count {
            var busySum: UInt64 = 0, totalSum: UInt64 = 0
            // Apple silicon lists the efficiency cores first.
            cores = ticks.indices.map { i in
                let busy = ticks[i].busy &- lastTicks[i].busy, total = ticks[i].total &- lastTicks[i].total
                busySum += busy; totalSum += total
                return Core(id: i, efficiency: i < efficiencyCount, load: total > 0 ? Double(busy) / Double(total) : 0)
            }
            cpu = totalSum > 0 ? Double(busySum) / Double(totalSum) : 0
        }
        lastTicks = ticks
    }

    private func readGPU() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            if let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
               let use = stats["Device Utilization %"] as? Int {
                best = max(best ?? 0, Double(use) / 100)
            }
        }
        gpu = best
    }

    // MARK: Memory and disk

    private func readMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        if kr == KERN_SUCCESS {
            let page = Double(vm_kernel_page_size)
            // Activity Monitor's "Memory Used": app memory + wired + compressed.
            let app = Double(stats.internal_page_count) - Double(stats.purgeable_count)
            memUsed = (app + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
        }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 { swapUsed = Double(swap.xsu_used) }
        memPressure = Monitor.sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1
    }

    private func readDisk() {
        lastDisk = Date()
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) else { return }
        diskTotal = Double(v.volumeTotalCapacity ?? 0)
        diskFree = Double(v.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    // MARK: Network

    private func readNetwork() {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return }
        defer { freeifaddrs(head) }
        var now: [String: (rx: UInt32, tx: UInt32)] = [:]
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = p {
            p = ifa.pointee.ifa_next
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  let data = ifa.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }  // Wi-Fi and wired; skips loopback and VPN tunnels
            now[name] = (data.pointee.ifi_ibytes, data.pointee.ifi_obytes)
        }
        let t = Date()
        let dt = t.timeIntervalSince(lastNetTime)
        if !lastNet.isEmpty, dt > 0 {
            var rx: UInt64 = 0, tx: UInt64 = 0
            for (name, v) in now {
                guard let old = lastNet[name] else { continue }
                rx += UInt64(v.rx &- old.rx)  // the counters are 32-bit and wrap; wrapping subtraction handles it
                tx += UInt64(v.tx &- old.tx)
            }
            netDown = Double(rx) / dt
            netUp = Double(tx) / dt
        }
        lastNet = now
        lastNetTime = t
    }

    // MARK: Top apps

    private func refreshTopApps() {
        Task.detached {
            let out = Monitor.run("/bin/ps", ["-Aceo", "pid=,pcpu=,comm=", "-r"])
            let apps: [TopApp] = out.split(separator: "\n").prefix(6).compactMap { line in
                let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                guard parts.count == 3, let pid = Int(parts[0]), let cpu = Double(parts[1]) else { return nil }
                return TopApp(id: pid, name: String(parts[2]), cpu: cpu)
            }
            await MainActor.run { self.topApps = apps }
        }
    }

    // MARK: Helpers

    nonisolated static func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated static func sysctlInt(_ name: String) -> Int? {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &v, &size, nil, 0) == 0 ? Int(v) : nil
    }

    nonisolated static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    /// "MacBook Pro (14-inch, M5)", from the device tree; falls back to the chip name.
    nonisolated static func machineName() -> String {
        let product = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        defer { if product != 0 { IOObjectRelease(product) } }
        if product != 0,
           let data = IORegistryEntryCreateCFProperty(product, "product-name" as CFString, kCFAllocatorDefault, 0)?
               .takeRetainedValue() as? Data {
            let name = String(decoding: data.prefix(while: { $0 != 0 }), as: UTF8.self)
            if !name.isEmpty { return name }
        }
        return sysctlString("machdep.cpu.brand_string") ?? "Mac"
    }
}
