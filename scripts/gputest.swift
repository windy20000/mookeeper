// MooKeeper 采样直读探针 —— 跨芯片自检（Apple Silicon / Intel / AMD 通用）
// 用途：确认整机 GPU%(IOAccelerator)、整机 CPU%(host_processor_info) 直读在这台机器上的值。
// 在目标机器上跑：swiftc -o /tmp/gputest gputest.swift && /tmp/gputest
import Foundation
import IOKit
import Darwin

func numValue(_ v: Any?) -> Double? {
    guard let v else { return nil }
    if let d = v as? Double { return d }
    if let i = v as? Int { return Double(i) }
    if let f = v as? Float { return Double(f) }
    if let n = v as? NSNumber { return n.doubleValue }
    return nil
}

func printMachine() {
    print("== 机器 ==")
    var size = 0
    sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
    var buf = [CChar](repeating: 0, count: max(size, 1))
    sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
    print("CPU: \(String(cString: buf))")

    var u = utsname()
    uname(&u)
    let arch = withUnsafeBytes(of: &u.machine) { raw in
        String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
    }
    print("arch: \(arch)")
    let ver = ProcessInfo.processInfo.operatingSystemVersion
    print("macOS: \(ver.majorVersion).\(ver.minorVersion).\(ver.patchVersion)")
}

// 整机 CPU%：连续两次 host_processor_info 差分（约 sleep 秒）
func cpuUsage(sampleSeconds: Double = 1.0) {
    // CPU_STATE_* 顺序（processor_info.h）：USER=0 SYSTEM=1 IDLE=2 NICE=3，每 CPU 占 4 个 integer_t
    func readTicks() -> (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)? {
        var cpuInfo: processor_info_array_t?
        var numCpuInfo: mach_msg_type_number_t = 0
        var numCpus: natural_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCpus, &cpuInfo, &numCpuInfo)
        guard kr == KERN_SUCCESS, let cpuInfo else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), vm_size_t(Int(numCpuInfo) * MemoryLayout<integer_t>.size)) }
        var user: UInt64 = 0, system: UInt64 = 0, idle: UInt64 = 0, nice: UInt64 = 0
        let stride = 4
        for i in 0..<Int(numCpus) {
            user   += UInt64(cpuInfo[i * stride + 0])
            system += UInt64(cpuInfo[i * stride + 1])
            idle   += UInt64(cpuInfo[i * stride + 2])
            nice   += UInt64(cpuInfo[i * stride + 3])
        }
        return (user, system, idle, nice)
    }
    guard let a = readTicks() else { print("CPU 直读失败"); return }
    Thread.sleep(forTimeInterval: sampleSeconds)
    guard let b = readTicks() else { print("CPU 直读失败"); return }
    func d(_ x: UInt64, _ y: UInt64) -> UInt64 { x > y ? x - y : 0 }
    let du = d(b.user, a.user) + d(b.nice, a.nice) + d(b.system, a.system)
    let di = d(b.idle, a.idle)
    let total = du + di
    print("CPU%（host_processor_info 差分）: \(total > 0 ? String(format: "%.1f%%", Double(du) / Double(total) * 100) : "n/a")")
}

// 整机 GPU%：枚举所有 IOAccelerator 节点，取各节点 "Device Utilization %" 的最大值
func gpuScan() {
    print("== IOAccelerator 扫描 ==")
    var iterator: io_iterator_t = 0
    let match = IOServiceMatching("IOAccelerator")
    let kr = IOServiceGetMatchingServices(0, match, &iterator)
    guard kr == KERN_SUCCESS else { print("IOServiceGetMatchingServices 失败 \(kr)"); return }

    var found = 0
    var maxDevice = 0.0
    while case let svc = IOIteratorNext(iterator), svc != 0 {
        defer { IOObjectRelease(svc) }
        found += 1

        var cname = [CChar](repeating: 0, count: 128)
        IORegistryEntryGetName(svc, &cname)
        var cpath = [CChar](repeating: 0, count: 512)
        IORegistryEntryGetPath(svc, kIOServicePlane, &cpath)
        print("[节点\(found)] \(String(cString: cname))  path=\(String(cString: cpath))")

        var cfProps: Unmanaged<CFMutableDictionary>?
        let ok = IORegistryEntryCreateCFProperties(svc, &cfProps, kCFAllocatorDefault, 0)
        if ok == KERN_SUCCESS, let props = cfProps?.takeRetainedValue() as? [String: Any],
           let ps = props["PerformanceStatistics"] as? [String: Any] {
            let keys = ["Device Utilization %", "Renderer Utilization %", "Tiler Utilization %", "GPU Activity(%)"]
            for k in keys {
                if let v = numValue(ps[k]) {
                    print("    \(k) = \(v)")
                    if k == "Device Utilization %" { maxDevice = max(maxDevice, v) }
                }
            }
        } else {
            print("    （该节点无 PerformanceStatistics）")
        }
    }
    IOObjectRelease(iterator)
    print("整机 GPU%（Device Utilization % 最大值）: \(found > 0 ? String(maxDevice) + "%" : "无 IOAccelerator 节点")")
}

printMachine()
print()
cpuUsage()
print()
gpuScan()