import Cocoa
import Darwin
import IOKit

// MARK: - Models
struct DiskInfo {
    let name: String
    let model: String
    let bsdName: String
    let volumes: [String]
    let temp: Int
    let sensors: [Int]
    let pctUsed: Int
}

struct MemoryInfo {
    let usedGB: Double
    let totalGB: Double
    let percent: Double
}

struct ProcessMemory {
    let name: String
    let memStr: String
    let bytes: UInt64
}

// MARK: - IOHID C-APIs for Apple Silicon CPU Temp
typealias IOHIDEventSystemClientRef = CFTypeRef
typealias IOHIDServiceClientRef = CFTypeRef

@_silgen_name("IOHIDEventSystemClientCreate")
func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> IOHIDEventSystemClientRef?
@_silgen_name("IOHIDEventSystemClientSetMatching")
func IOHIDEventSystemClientSetMatching(_ client: IOHIDEventSystemClientRef, _ matching: CFDictionary)
@_silgen_name("IOHIDEventSystemClientCopyServices")
func IOHIDEventSystemClientCopyServices(_ client: IOHIDEventSystemClientRef) -> CFArray?
@_silgen_name("IOHIDServiceClientCopyProperty")
func IOHIDServiceClientCopyProperty(_ service: IOHIDServiceClientRef, _ key: CFString) -> CFTypeRef?
@_silgen_name("IOHIDServiceClientCopyEvent")
func IOHIDServiceClientCopyEvent(_ service: IOHIDServiceClientRef, _ type: Int64, _ options: Int32, _ timeout: Int64) -> CFTypeRef?
@_silgen_name("IOHIDEventGetFloatValue")
func IOHIDEventGetFloatValue(_ event: CFTypeRef, _ field: Int32) -> Double

// MARK: - Helper for SF Symbol Images & Attachments
func getSymbol(_ name: String, pointSize: CGFloat = 12, weight: NSFont.Weight = .regular) -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
    guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else {
        return nil
    }
    img.isTemplate = true
    return img
}

func makeSymbolAttachment(name: String, pointSize: CGFloat = 11, font: NSFont) -> NSAttributedString {
    guard let img = getSymbol(name, pointSize: pointSize, weight: .medium) else {
        return NSAttributedString(string: "")
    }
    let attachment = NSTextAttachment()
    attachment.image = img
    let yOffset = round((font.capHeight - img.size.height) / 2.0)
    attachment.bounds = CGRect(x: 0, y: yOffset, width: img.size.width, height: img.size.height)
    return NSAttributedString(attachment: attachment)
}

// MARK: - System Monitor
class SystemMonitor {
    var prevTicks: (user: UInt32, sys: UInt32, idle: UInt32, nice: UInt32)?
    
    func getCpuUsage() -> Double {
        var cpuLoad = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let res = withUnsafeMutablePointer(to: &cpuLoad) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard res == KERN_SUCCESS else { return 0.0 }
        
        let cur = (user: cpuLoad.cpu_ticks.0, sys: cpuLoad.cpu_ticks.1, idle: cpuLoad.cpu_ticks.2, nice: cpuLoad.cpu_ticks.3)
        guard let prev = prevTicks else {
            prevTicks = cur
            return 0.0
        }
        
        let uDiff = Double(cur.user - prev.user)
        let sDiff = Double(cur.sys - prev.sys)
        let iDiff = Double(cur.idle - prev.idle)
        let nDiff = Double(cur.nice - prev.nice)
        let total = uDiff + sDiff + iDiff + nDiff
        prevTicks = cur
        
        if total > 0 {
            return ((uDiff + sDiff + nDiff) / total) * 100.0
        }
        return 0.0
    }
    
    func getCpuTemperature() -> Double? {
        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else { return nil }
        let dict: [String: Any] = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5]
        IOHIDEventSystemClientSetMatching(client, dict as CFDictionary)
        guard let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClientRef] else { return nil }
        
        var tdieTemps: [Double] = []
        for s in services {
            var name = ""
            if let prop = IOHIDServiceClientCopyProperty(s, "Product" as CFString) as? String {
                name = prop
            }
            if name.contains("tdie") || name.contains("SOC") || name.contains("CPU") {
                if let ev = IOHIDServiceClientCopyEvent(s, 15, 0, 0) {
                    let val = IOHIDEventGetFloatValue(ev, 15 << 16)
                    if val > 10 && val < 120 {
                        tdieTemps.append(val)
                    }
                }
            }
        }
        if !tdieTemps.isEmpty {
            return tdieTemps.reduce(0, +) / Double(tdieTemps.count)
        }
        return nil
    }
    
    func getMemoryInfo() -> MemoryInfo {
        let totalBytes = Double(ProcessInfo.processInfo.physicalMemory)
        let totalGB = totalBytes / 1024 / 1024 / 1024
        
        var vmStat = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let res = withUnsafeMutablePointer(to: &vmStat) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard res == KERN_SUCCESS else { return MemoryInfo(usedGB: 0, totalGB: totalGB, percent: 0) }
        
        let pageSize = Double(vm_kernel_page_size)
        let active = Double(vmStat.active_count) * pageSize
        let wired = Double(vmStat.wire_count) * pageSize
        let compressed = Double(vmStat.compressor_page_count) * pageSize
        let usedBytes = active + wired + compressed
        let usedGB = usedBytes / 1024 / 1024 / 1024
        let percent = (usedBytes / totalBytes) * 100.0
        return MemoryInfo(usedGB: usedGB, totalGB: totalGB, percent: percent)
    }
    
    private func extractAppName(from path: String) -> String {
        if let range = path.range(of: "\\.app(/|$)", options: .regularExpression) {
            let prefix = path[..<range.lowerBound]
            let components = prefix.components(separatedBy: "/")
            if let last = components.last, !last.isEmpty {
                return last
            }
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }
    
    func getTop5Processes() -> [ProcessMemory] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "/bin/ps -axo rss,comm -m"]
        let pipe = Pipe()
        p.standardOutput = pipe
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard let str = String(data: data, encoding: .utf8) else { return [] }
            
            var appMap: [String: UInt64] = [:]
            
            for line in str.components(separatedBy: "\n").dropFirst() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if parts.count >= 2 {
                    let rssKB = UInt64(parts[0]) ?? 0
                    if rssKB < 1024 { continue }
                    let comm = parts[1...].joined(separator: " ")
                    let appName = extractAppName(from: comm)
                    appMap[appName, default: 0] += rssKB * 1024
                }
            }
            
            let sorted = appMap.sorted { $0.value > $1.value }
            return sorted.prefix(5).map { (name, bytes) in
                let gb = Double(bytes) / 1024 / 1024 / 1024
                let mb = Double(bytes) / 1024 / 1024
                let str = gb >= 1.0 ? String(format: "%.2f GB", gb) : String(format: "%.0f MB", mb)
                return ProcessMemory(name: name, memStr: str, bytes: bytes)
            }
        } catch {
            return []
        }
    }
    
    func fetchDisks() -> [DiskInfo] {
        let smartctl = "/opt/homebrew/bin/smartctl"
        guard FileManager.default.fileExists(atPath: smartctl) else { return [] }
        
        let scanP = Process()
        scanP.executableURL = URL(fileURLWithPath: smartctl)
        scanP.arguments = ["--scan"]
        let scanPipe = Pipe()
        scanP.standardOutput = scanPipe
        do {
            try scanP.run()
            let scanData = scanPipe.fileHandleForReading.readDataToEndOfFile()
            scanP.waitUntilExit()
            guard let scanStr = String(data: scanData, encoding: .utf8) else { return [] }
            
            var devices: [(String, [String])] = []
            for line in scanStr.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                let clean = trimmed.components(separatedBy: " # ")[0]
                let parts = clean.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if !parts.isEmpty {
                    let dev = parts[0]
                    let extra = parts.count > 1 ? Array(parts[1...]) : []
                    devices.append((dev, extra))
                }
            }
            
            var disks: [DiskInfo] = []
            for (dev, extra) in devices {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: smartctl)
                p.arguments = ["-j", "-a", dev] + extra
                let pipe = Pipe()
                p.standardOutput = pipe
                do {
                    try p.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    p.waitUntilExit()
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        let model = json["model_name"] as? String ?? "NVMe SSD"
                        var temp = (json["temperature"] as? [String: Any])?["current"] as? Int
                        let nvme = json["nvme_smart_health_information_log"] as? [String: Any] ?? [:]
                        if temp == nil { temp = nvme["temperature"] as? Int }
                        let sensors = nvme["temperature_sensors"] as? [Int] ?? []
                        let pctUsed = nvme["percentage_used"] as? Int ?? 0
                        
                        if let t = temp {
                            var friendlyName = model
                            var vols: [String] = []
                            var bsd = ""
                            if model.contains("APPLE") {
                                friendlyName = "内置 Apple SSD (512GB)"
                                vols = ["Macintosh HD"]
                                bsd = "disk0"
                            } else if model.contains("Samsung") || model.contains("970") {
                                friendlyName = "三星 970 EVO Plus (1TB)"
                                vols = ["backup"]
                                bsd = "外置雷电"
                            } else if model.contains("Great Wall") || model.contains("GT70") {
                                friendlyName = "长城 GT70 (4TB)"
                                vols = ["A", "B"]
                                bsd = "外置雷电"
                            }
                            disks.append(DiskInfo(name: friendlyName, model: model, bsdName: bsd, volumes: vols, temp: t, sensors: sensors, pctUsed: pctUsed))
                        }
                    }
                } catch {}
            }
            
            // 固定统一的显示排序：1. 内置 Apple SSD, 2. 三星 970, 3. 长城 GT70
            disks.sort { a, b in
                let priA = a.model.contains("APPLE") ? 0 : (a.model.contains("Samsung") || a.model.contains("970") ? 1 : 2)
                let priB = b.model.contains("APPLE") ? 0 : (b.model.contains("Samsung") || b.model.contains("970") ? 1 : 2)
                return priA < priB
            }
            
            return disks
        } catch {
            return []
        }
    }
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var refreshInterval: TimeInterval = 3.0
    var displayMode: Int = 0 // 0: 极简SVG图标 (默认), 1: 紧凑矢量, 2: 极简文字(CPU/RAM/SSD), 3: 纯数字
    var alertStyle: Int = 0  // 0: 极致纯净 (默认, 无感叹号与标记), 1: 温和暖色 (仅高温数字橙色高亮)
    var isQuerying = false
    
    let monitor = SystemMonitor()
    var currentDisks: [DiskInfo] = []
    var currentCpuUsage: Double = 0.0
    var currentCpuTemp: Double = 0.0
    var currentMem: MemoryInfo = MemoryInfo(usedGB: 0, totalGB: 0, percent: 0)
    var currentTop5: [ProcessMemory] = []
    var lastUpdateTime: String = "--:--:--"
    
    let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    
    let launchAgentURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/LaunchAgents/com.forest.DiskTempBar.plist")
    }()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "..."
        }
        
        ensureLaunchAtLoginEnabled()
        
        if let savedInterval = UserDefaults.standard.value(forKey: "refreshInterval") as? Double {
            refreshInterval = savedInterval
        }
        if let savedMode = UserDefaults.standard.value(forKey: "displayMode") as? Int {
            displayMode = savedMode
        }
        if let savedAlertStyle = UserDefaults.standard.value(forKey: "alertStyle") as? Int {
            alertStyle = savedAlertStyle
        }
        
        buildMenu()
        startTimer()
        refreshData()
    }
    
    func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refreshData()
        }
    }
    
    func refreshData() {
        guard !isQuerying else { return }
        isQuerying = true
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let cpuU = self.monitor.getCpuUsage()
            let cpuT = self.monitor.getCpuTemperature() ?? 0.0
            let mem = self.monitor.getMemoryInfo()
            let top5 = self.monitor.getTop5Processes()
            let disks = self.monitor.fetchDisks()
            let timeStr = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            
            DispatchQueue.main.async {
                self.currentCpuUsage = cpuU
                self.currentCpuTemp = cpuT
                self.currentMem = mem
                self.currentTop5 = top5
                self.currentDisks = disks
                self.lastUpdateTime = timeStr
                
                self.updateStatusTitle()
                self.buildMenu()
                self.isQuerying = false
            }
        }
    }
    
    func updateStatusTitle() {
        guard let button = statusItem.button else { return }
        
        let cpuStr = String(format: "%.0f%%", currentCpuUsage)
        let cpuTempStr = currentCpuTemp > 0 ? String(format: "%.0f°", currentCpuTemp) : "--°"
        let memStr = String(format: "%.0f%%", currentMem.percent)
        
        let maxDiskTemp = currentDisks.map { $0.temp }.max() ?? 0
        let maxDiskStr = maxDiskTemp > 0 ? "\(maxDiskTemp)°" : "--°"
        
        let result = NSMutableAttributedString()
        let textAttrs: [NSAttributedString.Key: Any] = [.font: font]
        let warnAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.systemOrange
        ]
        
        func appendDiskTemps(to attrStr: NSMutableAttributedString) {
            if currentDisks.isEmpty {
                attrStr.append(NSAttributedString(string: "--°", attributes: textAttrs))
            } else {
                for (i, d) in currentDisks.enumerated() {
                    if i > 0 {
                        attrStr.append(NSAttributedString(string: " ", attributes: textAttrs))
                    }
                    let str = "\(d.temp)°"
                    let attrs = (alertStyle == 1 && d.temp >= 70) ? warnAttrs : textAttrs
                    attrStr.append(NSAttributedString(string: str, attributes: attrs))
                }
            }
        }
        
        switch displayMode {
        case 0:
            // 极简 SVG / 矢量图标风格（默认）: [内置, 三星, 长城]
            result.append(makeSymbolAttachment(name: "cpu", font: font))
            result.append(NSAttributedString(string: " \(cpuStr) \(cpuTempStr)  ", attributes: textAttrs))
            
            result.append(makeSymbolAttachment(name: "memorychip", font: font))
            result.append(NSAttributedString(string: " \(memStr)  ", attributes: textAttrs))
            
            // 硬盘图标始终保持为内部驱动器图标，绝不跳变或替换为感叹号
            result.append(makeSymbolAttachment(name: "internaldrive", font: font))
            result.append(NSAttributedString(string: " ", attributes: textAttrs))
            appendDiskTemps(to: result)
            
        case 1:
            // 紧凑矢量风格 (最高温)
            result.append(makeSymbolAttachment(name: "cpu", font: font))
            result.append(NSAttributedString(string: " \(cpuStr)  ", attributes: textAttrs))
            
            result.append(makeSymbolAttachment(name: "memorychip", font: font))
            result.append(NSAttributedString(string: " \(memStr)  ", attributes: textAttrs))
            
            result.append(makeSymbolAttachment(name: "internaldrive", font: font))
            result.append(NSAttributedString(string: " ", attributes: textAttrs))
            let maxAttrs = (alertStyle == 1 && maxDiskTemp >= 70) ? warnAttrs : textAttrs
            result.append(NSAttributedString(string: maxDiskStr, attributes: maxAttrs))
            
        case 2:
            // 极简文字工业风 (CPU / RAM / SSD)
            result.append(NSAttributedString(string: "CPU \(cpuStr) \(cpuTempStr) · RAM \(memStr) · SSD ", attributes: textAttrs))
            appendDiskTemps(to: result)
            
        case 3:
            // 纯数字极简 (无任何图标文字)
            result.append(NSAttributedString(string: "\(cpuStr) \(cpuTempStr) | \(memStr) | ", attributes: textAttrs))
            appendDiskTemps(to: result)
            
        default:
            result.append(NSAttributedString(string: "\(cpuStr)", attributes: textAttrs))
        }
        
        button.attributedTitle = result
    }
    
    func buildMenu() {
        let menu = NSMenu()
        
        // 标头
        let header = NSMenuItem(title: "系统硬件状态监控 (更新于 \(lastUpdateTime))", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())
        
        // 1. CPU Section
        let cpuTitle = NSMenuItem(title: "CPU 处理器", action: nil, keyEquivalent: "")
        cpuTitle.attributedTitle = NSAttributedString(string: "CPU 处理器", attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        cpuTitle.image = getSymbol("cpu", pointSize: 14)
        menu.addItem(cpuTitle)
        
        let cpuUsageItem = NSMenuItem(title: String(format: "    ├  总利用率: %.1f%%", currentCpuUsage), action: nil, keyEquivalent: "")
        cpuUsageItem.isEnabled = false
        menu.addItem(cpuUsageItem)
        
        var cpuStatus = "[正常]"
        if currentCpuTemp >= 80 { cpuStatus = "[过热警告]" }
        else if currentCpuTemp >= 65 { cpuStatus = "[偏高]" }
        let cpuTempItem = NSMenuItem(title: String(format: "    └  核心温度: %.1f°C  %@", currentCpuTemp, cpuStatus), action: nil, keyEquivalent: "")
        cpuTempItem.isEnabled = false
        menu.addItem(cpuTempItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 2. RAM Section
        let memTitle = NSMenuItem(title: "内存运行状态", action: nil, keyEquivalent: "")
        memTitle.attributedTitle = NSAttributedString(string: "内存运行状态", attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        memTitle.image = getSymbol("memorychip", pointSize: 14)
        menu.addItem(memTitle)
        
        let memUsageItem = NSMenuItem(title: String(format: "    ├  已用内存: %.2f GB / %.2f GB (%.1f%%)", currentMem.usedGB, currentMem.totalGB, currentMem.percent), action: nil, keyEquivalent: "")
        memUsageItem.isEnabled = false
        menu.addItem(memUsageItem)
        
        let topHeader = NSMenuItem(title: "    └  内存占用 TOP 5 应用 (严格按大小降序):", action: nil, keyEquivalent: "")
        topHeader.isEnabled = false
        menu.addItem(topHeader)
        
        for (i, proc) in currentTop5.enumerated() {
            let isLast = (i == currentTop5.count - 1)
            let branch = isLast ? "        └" : "        ├"
            let procItem = NSMenuItem(title: "\(branch)  \(i+1). \(proc.name) — \(proc.memStr)", action: nil, keyEquivalent: "")
            procItem.isEnabled = false
            menu.addItem(procItem)
        }
        
        menu.addItem(NSMenuItem.separator())
        
        // 3. Disk Section
        let diskTitle = NSMenuItem(title: "硬盘温度与健康 (固定顺序: 内置 / 三星 / 长城)", action: nil, keyEquivalent: "")
        diskTitle.attributedTitle = NSAttributedString(string: "硬盘温度与健康", attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        diskTitle.image = getSymbol("internaldrive", pointSize: 14)
        menu.addItem(diskTitle)
        
        if currentDisks.isEmpty {
            let noDisk = NSMenuItem(title: "    未检测到外置硬盘或正在扫描...", action: nil, keyEquivalent: "")
            noDisk.isEnabled = false
            menu.addItem(noDisk)
        } else {
            for disk in currentDisks {
                var statusIcon = "[正常]"
                if disk.temp >= 70 { statusIcon = "[高温警告]" }
                else if disk.temp >= 55 { statusIcon = "[偏热]" }
                
                let isExternal = disk.bsdName.contains("外置")
                let diskIconName = isExternal ? "externaldrive" : "internaldrive"
                
                let titleItem = NSMenuItem(title: "  \(disk.name) — \(disk.temp)°C  \(statusIcon)", action: nil, keyEquivalent: "")
                titleItem.attributedTitle = NSAttributedString(string: "  \(disk.name)  \(disk.temp)°C  \(statusIcon)", attributes: [
                    .font: NSFont.boldSystemFont(ofSize: 12)
                ])
                titleItem.image = getSymbol(diskIconName, pointSize: 12)
                menu.addItem(titleItem)
                
                if !disk.volumes.isEmpty {
                    let volItem = NSMenuItem(title: "      ├ 挂载卷: \(disk.volumes.joined(separator: ", "))", action: nil, keyEquivalent: "")
                    volItem.isEnabled = false
                    menu.addItem(volItem)
                }
                if disk.sensors.count >= 2 {
                    let sensorItem = NSMenuItem(title: "      ├ 颗粒: \(disk.sensors[0])°C  |  主控: \(disk.sensors[1])°C", action: nil, keyEquivalent: "")
                    sensorItem.isEnabled = false
                    menu.addItem(sensorItem)
                }
                let lifeItem = NSMenuItem(title: "      └ 寿命损耗: \(disk.pctUsed)% (健康度 \(100 - disk.pctUsed)%)", action: nil, keyEquivalent: "")
                lifeItem.isEnabled = false
                menu.addItem(lifeItem)
            }
        }
        
        menu.addItem(NSMenuItem.separator())
        
        // Controls (无任何快捷键冲突)
        let refreshItem = NSMenuItem(title: "立即刷新数据", action: #selector(manualRefresh), keyEquivalent: "")
        refreshItem.image = getSymbol("arrow.clockwise", pointSize: 12)
        refreshItem.target = self
        menu.addItem(refreshItem)
        
        // 刷新频率子菜单
        let intervalMenu = NSMenu()
        let intervals: [(String, TimeInterval)] = [
            ("2 秒", 2.0),
            ("3 秒 (推荐)", 3.0),
            ("5 秒", 5.0),
            ("10 秒", 10.0),
            ("30 秒", 30.0)
        ]
        for (label, val) in intervals {
            let item = NSMenuItem(title: label, action: #selector(changeInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = val
            if abs(self.refreshInterval - val) < 0.1 {
                item.state = .on
            }
            intervalMenu.addItem(item)
        }
        let intervalSub = NSMenuItem(title: "刷新频率", action: nil, keyEquivalent: "")
        intervalSub.image = getSymbol("timer", pointSize: 12)
        intervalSub.submenu = intervalMenu
        menu.addItem(intervalSub)
        
        // 顶栏显示格式子菜单
        let styleMenu = NSMenu()
        let styles = [
            (0, "极简矢量风格 (内置/三星/长城)"),
            (1, "紧凑矢量风格 (最高温)"),
            (2, "纯文字工业风 (CPU / RAM / SSD)"),
            (3, "极简纯数字风格 (无任何图标)")
        ]
        for (mode, label) in styles {
            let item = NSMenuItem(title: label, action: #selector(changeDisplayMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode
            if self.displayMode == mode {
                item.state = .on
            }
            styleMenu.addItem(item)
        }
        let styleSub = NSMenuItem(title: "顶栏显示格式", action: nil, keyEquivalent: "")
        styleSub.image = getSymbol("slider.horizontal.3", pointSize: 12)
        styleSub.submenu = styleMenu
        menu.addItem(styleSub)
        
        // 高温提示样式子菜单
        let alertMenu = NSMenu()
        let alertStyles = [
            (0, "极致纯净 (默认，无感叹号与标记)"),
            (1, "温和暖色 (仅高温数字橙色高亮)")
        ]
        for (style, label) in alertStyles {
            let item = NSMenuItem(title: label, action: #selector(changeAlertStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style
            if self.alertStyle == style {
                item.state = .on
            }
            alertMenu.addItem(item)
        }
        let alertSub = NSMenuItem(title: "高温提示样式", action: nil, keyEquivalent: "")
        alertSub.image = getSymbol("thermometer.medium", pointSize: 12)
        alertSub.submenu = alertMenu
        menu.addItem(alertSub)
        
        // 开机启动
        let launchItem = NSMenuItem(title: "开机自动启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.image = getSymbol("power", pointSize: 12)
        launchItem.target = self
        launchItem.state = isLaunchAtLoginEnabled() ? .on : .off
        menu.addItem(launchItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 退出
        let quitItem = NSMenuItem(title: "退出监控", action: #selector(quitApp), keyEquivalent: "")
        quitItem.image = getSymbol("xmark.circle", pointSize: 12)
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem.menu = menu
    }
    
    @objc func manualRefresh() {
        refreshData()
    }
    
    @objc func changeInterval(_ sender: NSMenuItem) {
        guard let val = sender.representedObject as? TimeInterval else { return }
        refreshInterval = val
        UserDefaults.standard.set(val, forKey: "refreshInterval")
        startTimer()
        buildMenu()
    }
    
    @objc func changeDisplayMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? Int else { return }
        displayMode = mode
        UserDefaults.standard.set(mode, forKey: "displayMode")
        updateStatusTitle()
        buildMenu()
    }
    
    @objc func changeAlertStyle(_ sender: NSMenuItem) {
        guard let style = sender.representedObject as? Int else { return }
        alertStyle = style
        UserDefaults.standard.set(style, forKey: "alertStyle")
        updateStatusTitle()
        buildMenu()
    }
    
    func isLaunchAtLoginEnabled() -> Bool {
        return FileManager.default.fileExists(atPath: launchAgentURL.path)
    }
    
    func ensureLaunchAtLoginEnabled() {
        if !isLaunchAtLoginEnabled() {
            setLaunchAtLogin(enabled: true)
        }
    }
    
    func setLaunchAtLogin(enabled: Bool) {
        if enabled {
            let appPath = "/Applications/DiskTempBar.app/Contents/MacOS/DiskTempBar"
            let plistContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>com.forest.DiskTempBar</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(appPath)</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <false/>
                <key>ProcessType</key>
                <string>Interactive</string>
            </dict>
            </plist>
            """
            let dir = launchAgentURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? plistContent.write(to: launchAgentURL, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: launchAgentURL)
        }
    }
    
    @objc func toggleLaunchAtLogin() {
        let enabled = isLaunchAtLoginEnabled()
        setLaunchAtLogin(enabled: !enabled)
        buildMenu()
    }
    
    @objc func quitApp() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
