import Foundation
import Darwin
import IOKit
import SystemConfiguration

// MARK: - 采样（进程内直读 + 必要的外部命令）
let lsofPath = "/usr/sbin/lsof"

// 全进程单条快照：名字 + CPU 累计时间(纳秒) + 物理实占 + 常驻 RSS（一次 proc_pid_rusage 拿到）
struct ProcessSample {
    let comm: String
    let footprintBytes: UInt64
    let residentBytes: UInt64
    let cpuNs: UInt64
}

func availableBytes() -> UInt64 {
    var cnt = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
    var s = vm_statistics64_data_t()
    let kr = withUnsafeMutablePointer(to: &s) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(cnt)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &cnt)
        }
    }
    guard kr == KERN_SUCCESS else { return 0 }
    let pages = UInt64(s.free_count) + UInt64(s.inactive_count) + UInt64(s.speculative_count) + UInt64(s.purgeable_count)
    return pages * UInt64(vm_page_size)
}

func pressureLevel() -> Int32 {
    var l: Int32 = 0; var sz = MemoryLayout<Int32>.size
    _ = sysctlbyname("kern.memorystatus_vm_pressure_level", &l, &sz, nil, 0)
    return l
}

func swapUsage() -> (used: UInt64, total: UInt64) {
    var x = xsw_usage(); var sz = MemoryLayout<xsw_usage>.size
    _ = sysctlbyname("vm.swapusage", &x, &sz, nil, 0)
    return (x.xsu_used, x.xsu_total)
}

func totalRAMBytes() -> UInt64 {
    var v: UInt64 = 0; var sz = MemoryLayout<UInt64>.size
    _ = sysctlbyname("hw.memsize", &v, &sz, nil, 0)
    return v
}

// 主系统卷容量（/）：剩余用 f_bavail（非 root 可写），总用 f_blocks
func diskInfo() -> (avail: UInt64, total: UInt64)? {
    var s = statfs()
    guard statfs("/", &s) == 0, s.f_bsize > 0 else { return nil }
    let bsize = UInt64(s.f_bsize)
    return (bsize * s.f_bavail, bsize * s.f_blocks)
}

func selfFootprintMB() -> Double {
    var info = task_vm_info_data_t()
    var cnt = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(cnt)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &cnt)
        }
    }
    guard kr == KERN_SUCCESS else { return 0 }
    return Double(info.phys_footprint) / 1_048_576
}

// MARK: - L1 采样
// 一次 lsof -iTCP 同时拿 LISTEN 与 ESTABLISHED 两类结果（原先各跑一次 lsof；
// 重负载机器上单次 lsof 可到秒级，合并后子进程开销减半）。
// ESTABLISHED 连接数按「本地端口」计数（= 正在进行的请求/连接数；客户端临时端口不会命中配置端口）
func tcpStates() -> (listen: [Int: [String: String]], est: [Int: Int]) {
    var lis: [Int: [String: String]] = [:]
    var est: [Int: Int] = [:]
    for rawLine in runProc([lsofPath, "-nP", "-iTCP"], 6).split(separator: "\n") {
        let parts = rawLine.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard parts.count >= 3 else { continue }
        let state = parts.last
        if state == "(LISTEN)" {
            guard !(parts[0] == "COMMAND" && parts[1] == "PID") else { continue }
            let portStr = parts[parts.count - 2].split(separator: ":").last.map(String.init) ?? ""
            guard let port = Int(portStr), let _ = Int(parts[1]) else { continue }
            lis[port, default: [:]][parts[1]] = parts[0]
        } else if state == "(ESTABLISHED)" {
            let addr = parts[parts.count - 2]
            let local = addr.split(separator: "->").first.map(String.init) ?? ""
            guard let portStr = local.split(separator: ":").last.map(String.init), let port = Int(portStr) else { continue }
            est[port, default: 0] += 1
        }
    }
    return (lis, est)
}

// 全进程扫描：proc_listallpids + proc_pid_rusage，一次遍历拿到 名字/RSS/实占/CPU 时间（毫秒级，替代 ps ax + top -l1）
func allProcesses() -> [Int: ProcessSample] {
    var result: [Int: ProcessSample] = [:]
    let n = dsb_pid_count()
    guard n > 0 else { return result }
    var pids = [Int32](repeating: 0, count: Int(n))
    let got = dsb_list_pids(&pids, Int32(n))
    let count = max(0, min(Int(got), Int(n)))
    for i in 0..<count {
        let pid = pids[i]
        guard pid > 0, pid != getpid() else { continue }      // 排除本进程
        var name = [CChar](repeating: 0, count: 256)
        var cpuNs: UInt64 = 0, footprint: UInt64 = 0, resident: UInt64 = 0
        guard dsb_proc_info(pid, &name, 256, &cpuNs, &footprint, &resident) == 0 else { continue }
        result[Int(pid)] = ProcessSample(comm: String(cString: name), footprintBytes: footprint, residentBytes: resident, cpuNs: cpuNs)
    }
    return result
}

// 整机 GPU%：枚举所有 IOAccelerator 节点，取 "Device Utilization %" 最大值（AGX / Intel 核显 / AMD 独显 通用）
func gpuUsagePct() -> Double {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(0, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return 0 }
    defer { IOObjectRelease(iterator) }
    var best = 0.0
    while case let svc = IOIteratorNext(iterator), svc != 0 {
        defer { IOObjectRelease(svc) }
        var cf: Unmanaged<CFMutableDictionary>? = nil
        guard IORegistryEntryCreateCFProperties(svc, &cf, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = cf?.takeRetainedValue() as? [String: Any],
              let ps = props["PerformanceStatistics"] as? [String: Any] else { continue }
        best = max(best, ioNumber(ps["Device Utilization %"]) ?? 0)
    }
    return best
}

func ioNumber(_ v: Any?) -> Double? {
    guard let v else { return nil }
    if let n = v as? NSNumber { return n.doubleValue }
    if let d = v as? Double { return d }
    if let i = v as? Int { return Double(i) }
    if let f = v as? Float { return Double(f) }
    return nil
}

// 整机 CPU ticks：host_processor_info(PROCESSOR_CPU_LOAD_INFO)，差分在 App 里跨 5s 拍做（top/htop 同款）
func hostCpuTicks() -> (user: UInt64, sys: UInt64, idle: UInt64, nice: UInt64)? {
    var cpuInfo: processor_info_array_t? = nil
    var numCpuInfo: mach_msg_type_number_t = 0
    var numCpus: natural_t = 0
    let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCpus, &cpuInfo, &numCpuInfo)
    guard kr == KERN_SUCCESS, let cpuInfo else { return nil }
    defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), vm_size_t(Int(numCpuInfo) * MemoryLayout<integer_t>.size)) }
    // CPU_STATE_* 顺序：USER=0 SYSTEM=1 IDLE=2 NICE=3，每 CPU 4 个 integer_t
    var user: UInt64 = 0, sys: UInt64 = 0, idle: UInt64 = 0, nice: UInt64 = 0
    for i in 0..<Int(numCpus) {
        user += UInt64(cpuInfo[i * 4 + 0])
        sys  += UInt64(cpuInfo[i * 4 + 1])
        idle += UInt64(cpuInfo[i * 4 + 2])
        nice += UInt64(cpuInfo[i * 4 + 3])
    }
    return (user, sys, idle, nice)
}

// 芯片名：machdep.cpu.brand_string（Apple Silicon="Apple M5 Pro"；Intel="Intel(R) Core(TM) i7-10700K CPU @ 3.80GHz" 清一下）
func chipName() -> String {
    var size = 0
    sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
    guard size > 0 else { return "" }
    var buf = [CChar](repeating: 0, count: size)
    _ = sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
    var s = String(cString: buf)
    for token in ["(R)", "(TM)", "CPU @"] { s = s.replacingOccurrences(of: token, with: "") }
    s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    return s.trimmingCharacters(in: .whitespaces)
}

// 由 comm 归一化成"应用名"（聚合用）
func appKey(_ comm: String) -> String {
    let s = comm.trimmingCharacters(in: .whitespaces)
    if s.isEmpty { return moo("其他", "Other") }
    if let r = s.range(of: ".app/") {
        let seg = s[..<r.lowerBound]
        let name = seg.split(separator: "/").last.map(String.init) ?? ""
        if !name.isEmpty, name != "MacOS", name != "Contents" { return name }
    }
    var base = (s as NSString).lastPathComponent
    base = base.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
    base = base.trimmingCharacters(in: .whitespaces)   // 剥括号会留尾空格，不先收尾下面的 Helper$ 就匹配不上（ZCode Helper 漏归并的根因）
    base = base.replacingOccurrences(of: #"\s+Helper$"#, with: "", options: .regularExpression)
    return base.trimmingCharacters(in: .whitespaces).isEmpty ? moo("其他", "Other") : base
}

// MARK: - 进程内系统读数（零子进程、零常驻；只在这档便宜采样里用）
func loadAverage() -> [Double] {
    var a = [Double](repeating: 0, count: 3)
    guard getloadavg(&a, 3) == 3 else { return [] }
    return a
}

func bootTime() -> Date? {
    var tv = timeval()
    var sz = MemoryLayout<timeval>.size
    guard sysctlbyname("kern.boottime", &tv, &sz, nil, 0) == 0 else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
}

/// 全网卡累计字节（rx=接收/下载，tx=发送/上传）。getifaddrs 枚举接口，
/// 瞬时分配用完即释；速率差分在 App.swift 里只留上一帧标量，不涨常驻。
/// 仅排除 lo0（回环）；utun*（VPN 隧道）等其余接口一律计入（原始口径）。
func networkCounters() -> (rx: UInt64, tx: UInt64) {
    var rx: UInt64 = 0, tx: UInt64 = 0
    var head: UnsafeMutablePointer<ifaddrs>? = nil
    guard getifaddrs(&head) == 0, head != nil else { return (0, 0) }
    defer { freeifaddrs(head) }
    var cur = head
    while let ifa = cur {
        defer { cur = ifa.pointee.ifa_next }
        guard let addr = ifa.pointee.ifa_addr, Int32(addr.pointee.sa_family) == AF_LINK else { continue }
        guard let namePtr = ifa.pointee.ifa_name else { continue }
        let name = String(cString: namePtr)
        if name == "lo0" { continue }
        guard let data = ifa.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
        rx &+= UInt64(data.pointee.ifi_ibytes)
        tx &+= UInt64(data.pointee.ifi_obytes)
    }
    return (rx, tx)
}

// MARK: - 网络卡主力出口判型（头图 icon：📡 Wi-Fi / ⚡️ 雷雳 / 🕸️ 有线；判不出回落 🚚）
// 农场隐喻：网络就是场间通路，icon 标的是「这条道路是什么材质」；↑↓ 数字仍是全网卡累计口径（networkCounters），两者各管各的。
// 进程内直读、零子进程：SCDynamicStore 问系统主力 IPv4 出口（VPN 时 PrimaryInterface 仍指底层物理口）。
// 判据 2026-10-04 临时探针（build/probe_netkind）本机实测：
//   · Wi-Fi   → State:/Network/Interface/<name>/AirPort 键存在（实测 en0 有、其余 en* 无）；
//   · 雷雳    → bridge*（雷雳桥接，成员就是 TB 上的 en 口），或该 BSD 名在 IORegistry 的
//               IOEthernetInterface 祖先 IOClass 链含 Thunderbolt（实测 en1/en2/en6 =
//               AppleThunderboltIPService < AppleThunderboltHALType7 < AppleSoCIO）；
//   · 有线    → 其余物理 en/et 口（板载 / USB / 扩展坞 / iPhone USB 共享上网的 NCM 都算走线缆）；
//   · unknown → 无默认出口、或 utun*/ap* 等非上述前缀的怪出口——不猜，🚚 兜底。
// 出口"走哪条路"正是要即时反映的量：**不做 TTL 缓存，每拍（5s Timer / 刷新按钮 / ⌘R 都进 refresh）直读**，
// 网络切换下一拍即换脸。成本压到微秒级：SCDynamicStore 句柄进程内建一次复用；IOKit 判定用
// "BSD Name" 塞进匹配字典的**定向查询**（内核过滤，只回 1 个对象 + ≤8 层祖先属性读），不枚举全量。
enum NetEgress {
    case wifi, thunderbolt, wired, unknown
    var icon: String {
        switch self {
        case .wifi: return "📡"
        case .thunderbolt: return "⚡️"
        case .wired: return "🕸️"
        case .unknown: return "🚚"
        }
    }
    var label: String {
        switch self {
        // 农场通路四型（契约 §6）：中文保留路感，英文走 macOS 专业口径，仅诊断口可见
        case .wifi: return moo("Wi-Fi 无线路", "Wi-Fi")
        case .thunderbolt: return moo("雷雳高速路", "Thunderbolt")
        case .wired: return moo("有线路", "Wired")
        case .unknown: return moo("通路未明", "Unknown")
        }
    }
}

private let netStore: SCDynamicStore? = SCDynamicStoreCreate(nil, "mookeeper" as CFString, nil, nil)

/// 网络卡头图 icon 数据源：当拍实况（refresh 每拍调用，主线程）
func netEgressKind() -> (iface: String, kind: NetEgress) {
    guard let store = netStore else { return ("", .unknown) }
    guard let g = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
          let name = g["PrimaryInterface"] as? String, !name.isEmpty
    else { return ("", .unknown) }   // 断网/无 IPv4 出口：留 🚚，不装懂
    return (name, classifyNetEgress(name, store: store))
}

/// 按接口名判型（--netkind <接口名> 强制判型也走这里，免拔线覆盖分支）
func classifyNetEgress(_ name: String, store: SCDynamicStore) -> NetEgress {
    if name.hasPrefix("bridge") { return .thunderbolt }
    if SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(name)/AirPort" as CFString) != nil { return .wifi }
    if name.hasPrefix("en") || name.hasPrefix("et") {
        return iokitInterfaceIsThunderbolt(name) ? .thunderbolt : .wired
    }
    return .unknown
}

func netEgressClassify(name: String) -> NetEgress {
    guard let store = netStore else { return .unknown }
    return classifyNetEgress(name, store: store)
}

/// 定向匹配：内核按 "BSD Name" 过滤，一次查找只回该接口对象（真键名带空格，探针钉死于 d.md §34）
private func iokitInterfaceIsThunderbolt(_ name: String) -> Bool {
    guard let m = IOServiceMatching("IOEthernetInterface") else { return false }
    let dict = m as NSMutableDictionary   // 本 SDK 里 IOServiceMatching 直接返回托管 CFMutableDictionary（同 L115 用法）
    dict["BSD Name"] = name
    let svc = IOServiceGetMatchingService(0, dict)   // matching 字典被调用方 consume，ARC 记账正好平衡
    defer { if svc != 0 { IOObjectRelease(svc) } }
    return svc != 0 && classChainHasThunderbolt(svc)
}

// 注意 IOServiceMatching 返回 nil 时：IOServiceGetMatchingServices(0, nil, …) 返回全量迭代，判型偏慢但不错判（实测不发生，留着防御）
private func classChainHasThunderbolt(_ entry: io_object_t) -> Bool {
    var cur = entry
    var owns = false
    defer { if owns { IOObjectRelease(cur) } }
    for _ in 0..<8 {   // 实测链深 ≤3（…< AppleSoCIO < AppleARMPE），8 层封顶绰绰有余
        if let clsUn = IORegistryEntryCreateCFProperty(cur, "IOClass" as CFString, kCFAllocatorDefault, 0),
           let cls = clsUn.takeRetainedValue() as? String,
           cls.lowercased().contains("thunderbolt") { return true }
        var parent = io_object_t()
        guard IORegistryEntryGetParentEntry(cur, kIOServicePlane, &parent) == KERN_SUCCESS else { return false }
        if owns { IOObjectRelease(cur) }
        cur = parent
        owns = true
    }
    return false
}
