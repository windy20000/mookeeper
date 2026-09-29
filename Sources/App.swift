import AppKit
import Foundation
import SwiftUI

// MARK: - 预警/趋势常量
let swapTrendWin: TimeInterval = 60
let swapTrendEps = 100
let warnRepeat: TimeInterval = 1800
let critRepeat: TimeInterval = 600
let githubRepoURL = "https://github.com/windy20000/mookeeper"

final class MenuAction: NSObject { let verb: String; let key: String?; init(_ v: String, _ k: String?) { verb = v; key = k } }

/// 按 ESC 关闭的窗口（配置 / 关于：`cancelOperation` 即 ESC 键）。
final class EscClosableWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

struct ProbeResult { let running: Bool; let pids: [String]; let est: Int }

func reasonOf(_ out: String) -> String {
    let lines = out.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    guard let last = lines.last else { return "" }
    for mark in ["⚠", "🔻", "⬆", "✅"] {
        if let idx = last.range(of: mark) { return String(last[idx.upperBound...]).trimmingCharacters(in: .whitespaces) }
    }
    return last
}

func hlColor(_ name: String) -> NSColor {
    switch name.lowercased() {
    case "red": return .systemRed
    case "yellow": return .systemYellow
    case "blue": return .systemBlue
    case "purple": return .systemPurple
    case "green": return .systemGreen
    default: return .systemOrange
    }
}

// MARK: - 应用控制器
final class App: NSObject, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var cfg = loadConfig()

    var smcConn: UInt32 = 0
    var swapPeakMB = 0
    var swapRing: [(Date, Int)] = []
    var groups: [Group] = []
    var footer: [FooterAction] = []
    var lisCache: [Int: [String: String]] = [:]
    var estCache: [Int: Int] = [:]
    var probeCache: [String: ProbeResult] = [:]
    var procCache: [Int: ProcessSample] = [:]      // 全进程快照（名字/RSS/实占/CPU 累计纳秒）
    var cpuNsPrev: [Int: (ns: UInt64, t: Date)] = [:]   // 每进程 CPU% 差分锚
    var pcpuCache: [Int: Double] = [:]             // 每进程 CPU%（Activity Monitor 口径，跨 5s 拍差分）
    var cpuTicksPrev: (u: UInt64, s: UInt64, i: UInt64, n: UInt64, t: Date)?   // 整机 CPU% 差分锚
    var cpuWhole = 0.0
    var gpuWhole = 0.0
    var chipStr = ""
    var checkAt: [String: Date] = [:]             // 用户 check 命令的低频栅（30s，防每拍阻塞主线程）
    var ioCache: [Int: Double] = [:]
    var ioPrev: [Int: (r: UInt64, w: UInt64, t: Date)] = [:]
    var netPrev: (rx: UInt64, tx: UInt64, t: Date)?
    var refreshTimer: Timer?
    var fenceTimer: Timer?
    var lastRefreshAt: Date?            // 上次 refresh 的瞬间：围栏线的进度 = 距它的时间 / 5s，与主 Timer 同源对齐
    var lastUptimeMin = -1              // 已值守按分钟跳字的节流锚（去秒后文案 1 分钟一变；围栏 tick 内顺路查）
    var bootAt: Date?                   // 开机时刻缓存：已值守文案按分钟刷新用，不反复 sysctl
    var logoDark: Bool?                 // 头图 logo 当前用的明暗变体（nil=未设）；刷新时按此判断是否要切图
    var headerView: MenuHeaderView?
    var menuOpen = false
    var lastUserRefreshAt: Date?        // 用户触发的刷新去重（点击/⌘R 双路径保险，0.25s 内合并）
    var keyMonitor: Any?
    var busy: [String: Date] = [:]
    var pending: [String: Date] = [:]
    var lastError: (Date, String)?
    var alert: [String: Any] = [:]
    var cpuTempKey: String?
    var gpuTempKey: String?
    var fanCount: Int?
    var titleWidthPin: CGFloat?
    var settingsWC: SettingsWindowController?
    var aboutWC: NSWindowController?

    func start() {
        smcConn = smc_open()
        setupMainMenu()
        menu.delegate = self
        // .common 模式：菜单展开（eventTracking）时定时器也继续刷新——否则盯菜单时数值会冻结
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
        installKeyMonitor()
    }
    deinit { smc_close(smcConn) }

    // MARK: ⌘R
    // 自绘视图条目（刷新行）不进菜单的快捷键匹配，菜单跟踪期的 keyDown 也不会沿窗口/视图链问
    // performKeyEquivalent（--menu-keytest 对两条路都做了实证：均不被调用）。能接住菜单跟踪期
    // 按键的只有本地事件监视器——命中 ⌘R 即刷新并吞掉事件，菜单保持展开。
    func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self, self.menuOpen else { return ev }
            let m = ev.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard m.contains(.command), !m.contains(.shift), !m.contains(.control), !m.contains(.option),
                  ev.charactersIgnoringModifiers?.lowercased() == "r" else { return ev }
            self.userRefresh()
            return nil
        }
    }

    // MARK: 围栏计时器（5s 刷新倒计时的可视化；只菜单展开时驱动，进度从 lastRefreshAt 派生、不与主 Timer 竞争秒表）
    private func startFenceTicker() {
        guard fenceTimer == nil else { return }
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = Date()
            let t0 = self.lastRefreshAt ?? now
            let f = min(1.0, max(0.0, now.timeIntervalSince(t0) / 5.0))
            self.headerView?.setFenceProgress(CGFloat(f))

            // 已值守文案每分钟跳一次（去秒后不再逐秒追字，「正在持续工作」由围栏进度条表现）：
            // 与围栏共用同一个轻量 tick，不另开 Timer
            if let boot = self.bootAt {
                let m = Int(now.timeIntervalSince(boot) / 60)
                if m != self.lastUptimeMin {
                    self.lastUptimeMin = m
                    self.updateUptimeText()
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        fenceTimer = t
    }

    /// 就地刷「已值守」文案（只改副标题的文字，不重建头图）
    private func updateUptimeText() {
        guard let boot = bootAt else { return }
        let text = moo("已值守 " + fmtUptime(Date().timeIntervalSince(boot)),
                       "On Watch " + fmtUptime(Date().timeIntervalSince(boot)))
        headerView?.setUptime([(text, NSColor.secondaryLabelColor)])
    }

    private func stopFenceTicker() {
        fenceTimer?.invalidate()
        fenceTimer = nil
    }

    // MARK: NSMenuDelegate（跟踪菜单是否展开：展开中只就地刷新头图，不整棵重建）
    // 注：§24 试过的 menuShouldClose 拦截在本机 macOS 26/27 上拦不住条目点击收起，已删——
    // 「刷新」不收菜单靠自绘视图行机制（RefreshRowView），见 d.md §25/§26。
    //
    // menuNeedsUpdate：在跟踪循环**启动之前**同步触发（AppKit 文档语义），是安全的重建点。
    // 这里做一次节流 rebuild（0.5s 内跳过）：修「点完全部停止→重开菜单还是上一轮旧快照、
    // 要等下一拍 5s Timer 才变」——旧快照来自「展开中 refresh() 早退、不重建分组行」
    // （见下面 menuOpen 分支，d.md §32.5 的尾巴），菜单开着时的原地实时化仍不做（§33 拍板）。
    // 节流窗口取 Hardwired.menuRebuildThrottle：连续快速开关只重建第一下。
    func menuNeedsUpdate(_ menu: NSMenu) {
        if let t = lastRefreshAt, Date().timeIntervalSince(t) < Hardwired.menuRebuildThrottle { return }
        refresh()
    }

    func menuWillOpen(_ menu: NSMenu) {
        // 兜底清悬停残留（见清法注释）。willOpen 里条目的 view 都已在位。
        clearStaleHover()
        menuOpen = true; startFenceTicker()
        geoLogAtWillOpen()
    }
    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false; stopFenceTicker()
        // 悬停态必须在收起这刻清掉：批量按钮走的是 mouseDown → cancelTracking()（§32.2），
        // 菜单窗口被代码直接关掉时 AppKit **不会**给自绘视图的 tracking area 补发 mouseExited，
        // hovered=true 就滞留在这批 view 实例上——而菜单要到下一拍关闭态 refresh() 才 removeAllItems
        // 重建（坑 17：重建不进跟踪期），快速重开用的还是同一批旧实例，于是「鼠标根本没碰它，
        // 按钮却带着一颗蓝色药丸/整行高亮」。2026-10-04 用户实测「点了全部停止、重开后 onfocus
        // 还停在全部停止」根因即此（d.md §33）。
        clearStaleHover()
    }

    /// 清掉菜单里所有自绘可悬停行的残留 hovered 态。只翻状态、不重建条目。
    private func clearStaleHover() {
        for mi in menu.items {
            if let gh = mi.view as? GroupHeaderView { gh.clearHover() }
            if let rr = mi.view as? RefreshRowView { rr.clearHover() }
            if let er = mi.view as? ErrorNoteRowView { er.clearHover() }
        }
    }

    // MOO_MENU_GEO=1 时在菜单打开瞬间量真实窗口几何（willOpen 同步触发，不受跟踪循环
    // 冻结 .common Timer 影响——--menu-geo 的定时器打法在跟踪期时灵时不灵，见 d.md §26）
    private func geoLogAtWillOpen() {
        guard ProcessInfo.processInfo.environment["MOO_MENU_GEO"] != nil else { return }
        let rows = menu.items.compactMap { mi -> String? in
            guard let v = mi.view else { return nil }
            let tag = v is MenuHeaderView ? "header" : (v is GroupHeaderView ? "group" : (v is RefreshRowView ? "refresh" : (v is ErrorNoteRowView ? "errnote" : "view")))
            return "\(tag)=\(Int(v.frame.width))"
        }.joined(separator: " ")
        let w = NSApp.windows.first { String(describing: type(of: $0)).lowercased().contains("menu") }
        fputs("menu-geo: willOpen window=\(w?.frame ?? .zero) \(rows)\n", stderr)
    }

    // MARK: SMC
    private func smcVal(_ key: String) -> Double? {
        guard smcConn != 0 else { return nil }
        var v = 0.0
        let ok = key.withCString { smc_read(smcConn, $0, &v) }
        return ok != 0 && v.isFinite ? v : nil
    }
    private func cachedTemp(_ key: inout String?, _ candidates: [String]) -> Double? {
        if key == nil {
            key = candidates.first { k in
                guard let t = smcVal(k), t >= 10, t <= 120 else { return false }
                return true
            }
        }
        guard let k = key, let t = smcVal(k), t >= 10, t <= 120 else { return nil }
        return t
    }
    private func fanRPMs() -> [Int] {
        let count = fanCount ?? Int(smcVal("FNum") ?? 0)
        fanCount = count
        guard (1...8).contains(count) else { return [] }
        return (0..<count).compactMap { i in
            guard let rpm = smcVal("F\(i)Ac"), rpm >= 0 else { return nil }
            return Int(rpm.rounded())
        }
    }

    // MARK: 菜单构建
    func addInfo(_ text: String, _ color: NSColor? = nil) {
        let it = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        if let c = color {
            let a = NSMutableAttributedString(string: text)
            a.addAttribute(.foregroundColor, value: c, range: NSRange(location: 0, length: (text as NSString).length))
            it.attributedTitle = a
        }
        it.isEnabled = false
        menu.addItem(it)
    }
    func addMono(_ text: String, _ color: NSColor? = nil) {
        let it = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        let a = NSMutableAttributedString(string: text)
        let r = NSRange(location: 0, length: (text as NSString).length)
        a.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), range: r)
        if let c = color { a.addAttribute(.foregroundColor, value: c, range: r) }
        it.attributedTitle = a
        it.isEnabled = false
        menu.addItem(it)
    }
    func addRich(_ segs: [(String, NSColor)]) {
        let it = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let a = NSMutableAttributedString()
        for (txt, c) in segs { a.append(NSAttributedString(string: txt, attributes: [.foregroundColor: c])) }
        it.attributedTitle = a
        it.isEnabled = false
        menu.addItem(it)
    }
    func addActionMono(_ text: String, _ verb: String, _ key: String?) {
        let it = NSMenuItem(title: text, action: #selector(handle(_:)), keyEquivalent: "")
        it.target = self
        it.representedObject = MenuAction(verb, key)
        let a = NSMutableAttributedString(string: text)
        let r = NSRange(location: 0, length: (text as NSString).length)
        a.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), range: r)
        it.attributedTitle = a
        menu.addItem(it)
    }
    @discardableResult
    func addAction(_ text: String, _ verb: String, _ key: String?, color: NSColor? = nil) -> NSMenuItem {
        let it = NSMenuItem(title: text, action: #selector(handle(_:)), keyEquivalent: "")
        it.target = self
        it.representedObject = MenuAction(verb, key)
        if let color {
            let a = NSMutableAttributedString(string: text)
            a.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: (text as NSString).length))
            it.attributedTitle = a
        }
        menu.addItem(it)
        return it
    }
    // 区块节标题：13pt 半粗 + 主色（与分组头同层级语言）
    func addSection(_ text: String) {
        let it = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        it.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor])
        it.isEnabled = false
        menu.addItem(it)
    }
    // 主段 + 尾巴两段式动作行（尾巴次级灰）：如「关于 MooKeeper · 占内存 15M」
    func addActionSplit(_ main: String, _ tail: String, _ verb: String, _ key: String?) {
        let it = NSMenuItem(title: "", action: #selector(handle(_:)), keyEquivalent: "")
        it.target = self
        it.representedObject = MenuAction(verb, key)
        let full = main + tail
        let a = NSMutableAttributedString(string: full)
        let total = NSRange(location: 0, length: (full as NSString).length)
        a.addAttribute(.font, value: NSFont.systemFont(ofSize: 13), range: total)
        let tailR = NSRange(location: (main as NSString).length, length: (tail as NSString).length)
        if tailR.length > 0 { a.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: tailR) }
        it.attributedTitle = a
        menu.addItem(it)
    }
    // 尾部右贴：算「前面文本」与「尾部文本」之间要补多少空格，让尾部右缘压在 Trunc.menuRightPx
    private func rightPad(_ front: String, _ tail: String) -> String {
        let n = Int(((Trunc.menuRightPx - 14 - monoWidth(front) - monoWidth(tail)) / monoSpace).rounded())
        return n > 1 ? String(repeating: " ", count: n) : "  "
    }
    // 条目尾字（未运行/已卸载）右贴制表位：手补空格按 6.8px/格取整，行与行的取整余数不同会
    // 翻桶（超长名走「…」截断的行错位 5.6px 的根因）；右对齐 tab stop 把尾字右缘钉死在
    // menuRightPx−14，与前行内容宽度彻底解耦，行间像素级恒定
    private lazy var tailRightPara: NSParagraphStyle = {
        let ps = NSMutableParagraphStyle()
        ps.tabStops = [NSTextTab(textAlignment: .right, location: Trunc.menuRightPx - 14, options: [:])]
        return ps
    }()
    // 分段着色 + 可点击（等宽）：每段可给独立字重/颜色——等宽半粗与常规同字宽，列对齐不受影响；
    // nil 色 = 主色、nil 字重 = 常规
    func addSegsF(_ segs: [(String, NSColor?, NSFont?)], _ verb: String, _ key: String?, para: NSParagraphStyle? = nil) {
        let it = NSMenuItem(title: "", action: #selector(handle(_:)), keyEquivalent: "")
        it.target = self
        it.representedObject = MenuAction(verb, key)
        let a = NSMutableAttributedString()
        for (txt, c, f) in segs {
            var attrs: [NSAttributedString.Key: Any] = [.font: f ?? monoFont]
            if let c = c { attrs[.foregroundColor] = c }
            if let para = para { attrs[.paragraphStyle] = para }
            a.append(NSAttributedString(string: txt, attributes: attrs))
        }
        it.attributedTitle = a
        menu.addItem(it)
    }
    func addSegs(_ segs: [(String, NSColor?)], _ verb: String, _ key: String?) {
        addSegsF(segs.map { ($0.0, $0.1, nil) }, verb, key)
    }
    // 分段着色 + 不可点（等宽；nil 色段 = 次级灰）：每段可给独立字重
    func addSegsMonoF(_ segs: [(String, NSColor?, NSFont?)], para: NSParagraphStyle? = nil) {
        let it = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let a = NSMutableAttributedString()
        for (txt, c, f) in segs {
            var attrs: [NSAttributedString.Key: Any] = [.font: f ?? monoFont]
            attrs[.foregroundColor] = c ?? NSColor.secondaryLabelColor
            if let para = para { attrs[.paragraphStyle] = para }
            a.append(NSAttributedString(string: txt, attributes: attrs))
        }
        it.attributedTitle = a
        it.isEnabled = false
        menu.addItem(it)
    }
    func addSegsMono(_ segs: [(String, NSColor?)]) {
        addSegsMonoF(segs.map { ($0.0, $0.1, nil) })
    }

    // MARK: 动作入口
    @objc func handle(_ sender: NSMenuItem) {
        guard let ma = sender.representedObject as? MenuAction else { return }
        switch ma.verb {
        case "open-am": NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
        case "refresh": userRefresh()
        case "quit": NSApp.terminate(nil)
        case "confirm": confirmStop(ma.key ?? "")
        case "settings": openSettings()
        case "about": openAbout()
        default: runAction(ma.verb, ma.key)
        }
    }

    func findItem(_ key: String) -> GroupItem? {
        for g in groups { if let it = g.items.first(where: { $0.key == key }) { return it } }
        return nil
    }

    func confirmStop(_ key: String) {
        guard let it = findItem(key), it.confirmStop else { return }
        if let ts = pending[key], Date().timeIntervalSince(ts) <= cfg.confirmWindow {
            pending.removeValue(forKey: key)
            runAction("stop", key)
        } else {
            pending[key] = Date()
            notify(moo("🐮 哞…… 再确认一次", "🐮 Moo… one more tap"),
                   moo("再点菜单里的「⚠ 再点一次确认停止 \(nameBrief(it.label))」完成停止（\(Int(cfg.confirmWindow)) 秒内有效）",
                       "Click “⚠ tap again to confirm stop \(nameBrief(it.label))” to finish (valid for \(Int(cfg.confirmWindow))s)"))
            refresh()
        }
    }

    // MARK: 分组查找 / 内存门槛
    func groupOf(_ it: GroupItem) -> Group? { groups.first { g in g.items.contains { $0.key == it.key } } }
    func groupByTitle(_ title: String) -> Group? { groups.first { $0.title == title } }

    private func freeGB() -> Double { Double(availableBytes()) / 1_073_741_824 }

    private func memoryGate(_ it: GroupItem) -> (have: Double, need: Double)? {
        guard let need = it.requireFreeGB, need > 0 else { return nil }
        let have = freeGB()
        return have < need ? (have, need) : nil
    }

    func runAction(_ verb: String, _ key: String?) {
        switch verb {
        case "start": startItem(key)
        case "stop": stopItem(key)
        case "start-all": bulk(key, start: true)
        case "stop-all": bulk(key, start: false)
        case "footer":
            guard let label = key, let fa = footer.first(where: { $0.label == label }) else { return }
            exec(fa.cmd, fa.timeout, busy: "footer-\(fa.label)", label: fa.label, doing: fa.label, done: fa.label, port: nil)
        case "open-url":
            if let key, let it = findItem(key), let u = it.url, let url = URL(string: u) {
                NSWorkspace.shared.open(url)
            }
        default: break
        }
    }

    func startItem(_ key: String?) {
        guard let key, let it = findItem(key), let c = it.start, !c.isEmpty else { return }
        guard busy["start-\(it.key)"] == nil else { return }   // 防重入：连点/与「全部启动」并发时直接忽略
        // 内置内存门槛（同步快速失败：纯进程内读，不阻塞）
        if let gate = memoryGate(it) {
            recordError(moo("剩余可用 \(gate.have)G < 需 \(gate.need)G",
                            "\(gate.have)G free < \(gate.need)G needed"))
            notify(moo("🐮 哞…… 内存不够", "🐮 Moo… not enough memory"),
                   moo("\(nameBrief(it.label))：剩余 \(gate.have)G < 需 \(gate.need)G，无法启动",
                       "\(nameBrief(it.label)): \(gate.have)G free < \(gate.need)G needed, can't start"),
                   sound: true)
            refresh(); return
        }
        // 互斥组：先停组内其它运行中条目，再开新的（读主线程缓存，留在主线程计算）
        var oldSteps: [(String, Cmd, TimeInterval)] = []
        if let g = groupOf(it), g.exclusive {
            for o in g.items where o.key != it.key && probeResult(o).running && o.stop != nil && !o.stop!.isEmpty {
                oldSteps.append((o.label, o.stop!, o.stopTimeout))
            }
        }
        // precheck + 停旧 + 启动整链后台化：precheck 最长 30s，同步跑会把主线程冻成彩虹球，
        // 且阻塞期间连点的点击事件会在解冻后连续派发（= 串行多个 precheck 再并发多个脚本）。
        // busy 先占位挡住重入，菜单立刻换「⏳ 进行中」；全部结果回主线程再决定是否 exec
        busy["start-\(it.key)"] = Date()
        refresh()
        DispatchQueue.global(qos: .utility).async {
            // 脚本前置门禁（后台快速失败）
            if let pre = it.precheck, !pre.isEmpty {
                let (rc, out) = runCmd(pre, 30)
                if rc != 0 {
                    DispatchQueue.main.async {
                        self.busy.removeValue(forKey: "start-\(it.key)")
                        self.recordError(reasonOf(out))
                        let reason = reasonOf(out)
                        notify(moo("🐮 哞…… 启动被阻", "🐮 Moo… start blocked"),
                               moo("\(nameBrief(it.label))：\(reason.isEmpty ? "前置检查未通过" : reason)",
                                   "\(nameBrief(it.label)): \(reason.isEmpty ? "precheck failed" : reason)"),
                               sound: true)
                        self.refresh()
                    }
                    return
                }
            }
            for s in oldSteps {
                notify(moo("🐮 哞…… 自动停旧", "🐮 Moo… stopping previous"),
                       moo("先卸载 \(s.0)…", "Unloading \(s.0)…"))
                _ = runCmd(s.1, s.2)
            }
            DispatchQueue.main.async {
                self.exec(c, it.startTimeout, busy: "start-\(it.key)", label: it.label, doing: moo("启动/装载", "starting/loading"), done: moo("启动完成", "started"), port: (it.probe == .port && it.port > 0) ? it.port : nil, mooOnDone: it.soundOnStart)
            }
        }
    }

    func stopItem(_ key: String?) {
        guard let key, let it = findItem(key), let c = it.stop, !c.isEmpty else { return }
        guard busy["stop-\(it.key)"] == nil else { return }    // 防重入：连点直接忽略
        busy["stop-\(it.key)"] = Date()
        notify(moo("🐮 哞…… 停止中", "🐮 Moo… stopping"),
               moo("\(nameBrief(it.label))——进行中，完成后会再通知", "\(nameBrief(it.label)) — in progress, will notify when done"))
        refresh()
        DispatchQueue.global(qos: .utility).async {
            let (rc, out) = runCmd(c, it.stopTimeout)
            // 停止后立即复查：目标已退出就算成功（pkill 找不到进程 / 进程本来已退，都不算失败）。
            // 复查也在后台跑（port 分支要跑 lsof、check 分支最长 6s），不再卡主线程
            let still = self.probeNow(it).running
            DispatchQueue.main.async {
                self.busy.removeValue(forKey: "stop-\(it.key)")
                if rc == 0 || !still {
                    self.lastError = nil
                    notify(moo("🐮 哞～ 停止完成", "🐮 Moo~ stopped"), nameBrief(it.label))
                } else {
                    let state = reasonOf(out)
                    let msg = state.isEmpty ? moo("命令已执行但进程仍在（返回码 \(rc)）",
                                                  "command ran but the process is still there (rc \(rc))") : state
                    self.recordError(msg)
                    notify(moo("🐮 哞？！ 停止失败", "🐮 Moo?! stop failed"), msg, sound: true)
                }
                self.refresh()
            }
        }
    }

    // 分组「全部启动 / 全部停止」：按顺序逐条执行脚本
    func bulk(_ groupTitle: String?, start: Bool) {
        guard let t = groupTitle, let g = groupByTitle(t) else { return }
        guard busy[(start ? "bulk-start-" : "bulk-stop-") + t] == nil else { return }   // 防重入：连点/与单条动作并发时忽略
        var steps: [(label: String, cmd: Cmd, timeout: TimeInterval, isStart: Bool, moo: Bool)] = []   // moo=条目勾了「启动完成响哞」（仅启动步携带）
        if start {
            let candidates = g.items.filter { $0.start != nil && !$0.start!.isEmpty && $0.loadable && !probeResult($0).running }
            let seq = g.exclusive ? Array(candidates.prefix(1)) : candidates
            for it in seq {
                if let gate = memoryGate(it) {
                    notify(moo("🐮 哞…… 跳过 \(nameBrief(it.label))", "🐮 Moo… skipped \(nameBrief(it.label))"),
                           moo("内存不够：剩余 \(gate.have)G < 需 \(gate.need)G", "not enough memory: \(gate.have)G free < \(gate.need)G needed"),
                           sound: true)
                    continue
                }
                steps.append((label: it.label, cmd: it.start!, timeout: it.startTimeout, isStart: true, moo: it.soundOnStart))
            }
        } else {
            for it in g.items where probeResult(it).running && it.stop != nil && !it.stop!.isEmpty {
                steps.append((label: it.label, cmd: it.stop!, timeout: it.stopTimeout, isStart: false, moo: false))
            }
        }
        guard !steps.isEmpty else { refresh(); return }
        runBulk(t, steps, start: start)
    }

    private func runBulk(_ groupTitle: String, _ steps: [(label: String, cmd: Cmd, timeout: TimeInterval, isStart: Bool, moo: Bool)], start: Bool) {
        let bk = (start ? "bulk-start-" : "bulk-stop-") + groupTitle
        busy[bk] = Date()
        refresh()
        // 通知聚合：只发「批量启动中」1 条 + 结束汇总 1 条，逐条的进行中/完成横幅全省去——
        // 10 条的组原来会刷 21 条通知（失败还各响一次铃），把真正的内存告急淹没
        notify(moo("🐮 哞…… 批量" + (start ? "启动" : "停止") + "中", "🐮 Moo… batch " + (start ? "starting" : "stopping")),
               moo("\(nameBrief(groupTitle))：\(steps.count) 条依次执行中…", "\(nameBrief(groupTitle)): \(steps.count) steps in order…"))
        DispatchQueue.global(qos: .utility).async {
            var ok = 0
            var fails: [String] = []   // 失败明细（label + 原因），合并进结束汇总
            for s in steps {
                let (rc, out) = runCmd(s.cmd, s.timeout)
                if rc == 0 {
                    ok += 1
                    // 批量平时不发逐条通知（通知聚合）；勾了「启动完成响哞」的条目是指定豁免——
                    // 完成当下就哞一声，慢启动的跑到一半也能听见「这个起好了」
                    if s.moo {
                        notify(moo("🐮 哞～ 启动完成", "🐮 Moo~ started"), nameBrief(s.label), sound: true)
                    }
                }
                else {
                    let state = reasonOf(out)
                    fails.append(state.isEmpty
                                 ? moo("\(nameBrief(s.label))（返回码 \(rc)）", "\(nameBrief(s.label)) (rc \(rc))")
                                 : moo("\(nameBrief(s.label))（\(state)）", "\(nameBrief(s.label)) (\(state))"))
                }
            }
            DispatchQueue.main.async {
                self.busy.removeValue(forKey: bk)
                if let last = fails.last { self.recordError(last) } else { self.lastError = nil }
                self.refresh()
                let zh = fails.isEmpty ? "\(nameBrief(groupTitle))：成功 \(ok)" : "\(nameBrief(groupTitle))：成功 \(ok) · 失败 \(fails.count)——\(fails.joined(separator: "、"))"
                let en = fails.isEmpty ? "\(nameBrief(groupTitle)): \(ok) ok" : "\(nameBrief(groupTitle)): \(ok) ok · \(fails.count) failed — \(fails.joined(separator: ", "))"
                notify(moo("🐮 哞～ 批量完成", "🐮 Moo~ batch done"), moo(zh, en), sound: !fails.isEmpty)
            }
        }
    }

    private func exec(_ cmd: Cmd, _ timeout: TimeInterval, busy bk: String, label: String, doing: String, done: String, port: Int?, mooOnDone: Bool = false) {
        busy[bk] = Date()
        notify(moo("🐮 哞…… ", "🐮 Moo… ") + doing,
               moo("\(nameBrief(label))——进行中，完成后会再通知", "\(nameBrief(label)) — in progress, will notify when done"))
        refresh()
        DispatchQueue.global(qos: .utility).async {
            let (rc, out) = runCmd(cmd, timeout)
            let state = reasonOf(out)
            DispatchQueue.main.async {
                self.busy.removeValue(forKey: bk)
                if rc == 124 {
                    self.recordError(moo("\(nameBrief(label)) 超过 \(Int(timeout))s 未返回",
                                         "\(nameBrief(label)) exceeded \(Int(timeout))s without returning"))
                    notify(moo("🐮 哞…… 仍在进行", "🐮 Moo… still running"),
                           moo("\(nameBrief(label)) 超时未返回——以菜单状态为准", "\(nameBrief(label)) timed out — check the menu for real status"),
                           sound: true)
                } else if rc == 0 {
                    self.lastError = nil
                    var txt = state.isEmpty ? nameBrief(label) : state
                    if let port {
                        txt += portOpen(port) ? moo(" · 端口已就绪", " · port ready") : moo(" · 就绪后自动刷新", " · auto-refreshes once ready")
                    }
                    // 默认「启动完成」静默（响/不响铁律）；条目勾了 soundOnStart 才带哞声
                    notify(moo("🐮 哞～ ", "🐮 Moo~ ") + done, txt, sound: mooOnDone)
                } else {
                    let msg = state.isEmpty ? moo("命令返回码 \(rc)", "command returned rc \(rc)") : state
                    self.recordError(msg)
                    notify(moo("🐮 哞？！ ", "🐮 Moo?! ") + doing + moo("失败", " failed"), msg, sound: true)
                }
                self.refresh()
            }
        }
    }

    // MARK: 配置界面
    @objc func openSettings() {
        if settingsWC == nil { settingsWC = SettingsWindowController(app: self) }
        settingsWC?.show()
    }

    // MARK: 关于
    @objc func openAbout() {
        if aboutWC == nil {
            let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
            let host = NSHostingController(rootView: AboutView(version: v))
            let w = EscClosableWindow(contentViewController: host)
            w.title = moo("关于 MooKeeper", "About MooKeeper")
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            host.view.layoutSubtreeIfNeeded()
            w.setContentSize(host.view.fittingSize)   // 按内容实际高度定格，避免多行文本被截断成「…」
            w.center()
            aboutWC = NSWindowController(window: w)
        }
        aboutWC?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func reloadConfig() {
        cfg = loadConfig()
        cpuNsPrev = [:]
        cpuTicksPrev = nil
        checkAt = [:]
        refresh()
    }

    private func setupMainMenu() {
        let mm = NSMenu()
        let appItem = NSMenuItem()
        mm.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: moo("关于 MooKeeper", "About MooKeeper"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        let prefs = NSMenuItem(title: moo("配置…", "Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        prefs.keyEquivalentModifierMask = [.command]
        prefs.target = self
        appMenu.addItem(prefs)
        appMenu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: moo("退出 MooKeeper", "Quit MooKeeper"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.command]
        quit.target = self
        appMenu.addItem(quit)
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mm.addItem(editItem)
        let editMenu = NSMenu(title: moo("编辑", "Edit"))
        editMenu.addItem(withTitle: moo("撤销", "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: moo("重做", "Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: moo("剪切", "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: moo("拷贝", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: moo("粘贴", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: moo("全选", "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = mm
    }

    func recordError(_ msg: String) {
        let m = msg.trimmingCharacters(in: .whitespaces)
        if !m.isEmpty { lastError = (Date(), String(m.prefix(120))) }
    }

    // MARK: 分组解析（直接来自配置，无外部清单回退）
    private func resolveGroups() {
        groups = cfg.groups
        footer = cfg.footer
    }

    // MARK: 条目运行状态（端口 / 进程 / PID 文件 / 检测命令 / 无状态）
    private func probeResult(_ it: GroupItem) -> ProbeResult {
        switch it.probe {
        case .port:
            let pids = lisCache[it.port] ?? [:]
            return ProbeResult(running: !pids.isEmpty, pids: Array(pids.keys), est: estCache[it.port] ?? 0)
        default:
            return probeCache[it.key] ?? ProbeResult(running: false, pids: [], est: 0)
        }
    }
    // 同步重探单条目（停止后立刻判断「是否真的停了」；不依赖 L1 缓存，stop 频率低，开销可忽略）
    private func probeNow(_ it: GroupItem) -> ProbeResult {
        switch it.probe {
        case .port:
            let m = tcpStates().listen[it.port] ?? [:]
            return ProbeResult(running: !m.isEmpty, pids: Array(m.keys), est: 0)
        case .process:
            let pids = pgrepPIDs(it.process ?? "")
            return ProbeResult(running: !pids.isEmpty, pids: pids, est: 0)
        case .pidFile:
            let (r, pids) = pidFileState(it.pidFile ?? "")
            return ProbeResult(running: r, pids: pids, est: 0)
        case .check:
            guard let c = it.checkCmd, !c.isEmpty else { return ProbeResult(running: false, pids: [], est: 0) }
            let (rc, _) = runCmd(c, 6)
            return ProbeResult(running: rc == 0, pids: [], est: 0)
        case .none:
            return ProbeResult(running: false, pids: [], est: 0)
        }
    }
    private func computeProbes(_ now: Date) -> [String: ProbeResult] {
        var res: [String: ProbeResult] = [:]
        for g in groups {
            for it in g.items {
                switch it.probe {
                case .process:
                    let pids = pgrepPIDs(it.process ?? "")
                    res[it.key] = ProbeResult(running: !pids.isEmpty, pids: pids, est: 0)
                case .pidFile:
                    let (r, pids) = pidFileState(it.pidFile ?? "")
                    res[it.key] = ProbeResult(running: r, pids: pids, est: 0)
                case .check:
                    // 用户自定义 check 命令是任意脚本：低频（30s）重跑，避免每 5s 阻塞主线程；其余探测每拍跑
                    if let last = checkAt[it.key], now.timeIntervalSince(last) < 30 {
                        res[it.key] = probeCache[it.key] ?? ProbeResult(running: false, pids: [], est: 0)
                        continue
                    }
                    checkAt[it.key] = now
                    // 先沿用上次结果，命令丢后台重跑，完成回主线程回填缓存并刷新菜单——
                    // check 最长 6s，不再卡主线程（probeCache 只在主线程读写，后台只算结果）
                    res[it.key] = probeCache[it.key] ?? ProbeResult(running: false, pids: [], est: 0)
                    if let c = it.checkCmd, !c.isEmpty {
                        let k = it.key
                        DispatchQueue.global(qos: .utility).async {
                            let (rc, _) = runCmd(c, 6)
                            let r = ProbeResult(running: rc == 0, pids: [], est: 0)
                            DispatchQueue.main.async {
                                self.probeCache[k] = r
                                self.refresh()   // checkAt[k] 刚更新过，这次刷新不会再触发同一条 check
                            }
                        }
                    }
                default: break
                }
            }
        }
        return res
    }
    private func probeCol(_ it: GroupItem) -> String {
        switch it.probe {
        case .port: return it.port > 0 ? ":" + String(it.port) : moo("·无状态", "· no state")
        case .process: return moo("·进程 ", "· proc ") + (it.process ?? "?")
        case .pidFile: return moo("·PID 文件", "· PID file")
        case .check: return moo("·检测命令", "· check")
        case .none: return moo("·按需执行", "· on demand")
        }
    }

    // 采样运行中条目的磁盘 IO（累计字节 diff → KB/s）
    private func sampleIO(_ pids: [Int], now: Date) {
        for pid in pids {
            var r: UInt64 = 0, w: UInt64 = 0
            guard dsb_proc_diskio(Int32(pid), &r, &w) == 0 else { continue }
            if let prev = ioPrev[pid] {
                let dt = max(0.5, now.timeIntervalSince(prev.t))
                let cur = r &+ w, old = prev.r &+ prev.w
                let bytes = cur > old ? cur - old : 0
                ioCache[pid] = Double(bytes) / dt / 1024.0
            }
            ioPrev[pid] = (r, w, now)
        }
    }

    // 每进程 CPU%：跨拍差分 CPU 累计纳秒 → 单核占用 %（Activity Monitor 口径，比 ps 的开机均值更跟手）
    private func computePcpu(_ fresh: [Int: ProcessSample], _ now: Date) {
        var pcpu: [Int: Double] = [:]
        for (pid, s) in fresh {
            if let prev = cpuNsPrev[pid] {
                let dt = max(0.5, now.timeIntervalSince(prev.t))
                let delta = s.cpuNs >= prev.ns ? s.cpuNs - prev.ns : 0
                pcpu[pid] = Double(delta) / 1_000_000_000.0 / dt * 100.0
            }
            cpuNsPrev[pid] = (s.cpuNs, now)
        }
        for pid in cpuNsPrev.keys where fresh[pid] == nil { cpuNsPrev.removeValue(forKey: pid) }
        pcpuCache = pcpu
    }

    // 整机 CPU%：host_processor_info 跨拍差分（active / total）
    private func computeWholeCpu(_ now: Date) -> Double {
        guard let ticks = hostCpuTicks() else { return 0 }
        defer { cpuTicksPrev = (ticks.user, ticks.sys, ticks.idle, ticks.nice, now) }
        guard let prev = cpuTicksPrev else { return 0 }
        func d(_ a: UInt64, _ b: UInt64) -> UInt64 { a >= b ? a - b : 0 }
        let active = d(ticks.user, prev.u) + d(ticks.nice, prev.n) + d(ticks.sys, prev.s)
        let idle = d(ticks.idle, prev.i)
        let total = active + idle
        return total > 0 ? Double(active) / Double(total) * 100.0 : 0
    }

    // 条目的 CPU%/GPU%/IO/在途连接 汇总 + 负载分级（空转/中度/重度，取最重一档）
    // ⚠ i18n 雷区隔离（契约 D4）：tier 是逻辑值（0/1/2），着色等判断一律比 tier；
    //   level 只是显示词（moo 双语），**绝不允许**拿显示字符串做逻辑判断
    private func itemLoad(_ it: GroupItem, _ pr: ProbeResult) -> (cpu: Double, gpu: Double, io: Double, est: Int, tier: Int, level: String) {
        let ps = pr.pids.compactMap { Int($0) }
        let cpu = ps.reduce(0.0) { $0 + (pcpuCache[$1] ?? 0) }
        // 每进程 GPU% 无免 sudo 真值（mactop 的 per-process 属比例分摊估算，已删）；gpuEngine 条目走整机直读，其余不再估算
        let gpu: Double = it.gpuEngine ? gpuWhole : 0
        let io = ps.reduce(0.0) { $0 + (ioCache[$1] ?? 0) }
        let t = cfg.load
        func band(_ v: Double, _ mod: Double, _ heavy: Double) -> Int { v >= heavy ? 2 : (v >= mod ? 1 : 0) }
        let estBand = pr.est >= t.connHeavy ? 2 : (pr.est >= t.connMod ? 1 : 0)
        let worst = max(estBand, band(cpu, t.cpuMod, t.cpuHeavy), band(gpu, t.gpuMod, t.gpuHeavy), band(io, t.ioModKBs, t.ioHeavyKBs))
        let level = worst == 2 ? moo("重度", "Heavy") : (worst == 1 ? moo("中度", "Moderate") : moo("空转", "Idle"))
        return (cpu, gpu, io, pr.est, worst, level)
    }

    // MARK: 刷新
    // 用户触发的刷新（自绘行点击 / ⌘R）：0.25s 去重——点击走视图 mouseDown、⌘R 走本地事件监视器，
    // 万一哪条路径双触发，也不至于连刷两拍把 CPU/IO 差分采样打坏
    func userRefresh() {
        let now = Date()
        if let t = lastUserRefreshAt, now.timeIntervalSince(t) < 0.25 { return }
        lastUserRefreshAt = now
        refresh()
    }
    func refresh() {
        let now = Date()
        lastRefreshAt = now                   // 围栏线「到底」的瞬间 = 这里，归零与数据刷新同刻发生
        // 计时器跟着归零：点击/⌘R 手动刷新后重新数 5s（否则自动那拍会在旧时刻插进来，围栏线走到一半又跳回 0）
        refreshTimer?.fireDate = now.addingTimeInterval(5)
        if menuOpen { headerView?.blink() }    // 小牛每 5 秒眨一次眼，确认农场状态
        let loadAvg = loadAverage()
        if bootAt == nil { bootAt = bootTime() }     // 缓存开机时刻：已值守文案按分钟跳字用
        let upText = bootAt.map { moo("已值守 " + fmtUptime(now.timeIntervalSince($0)),
                                      "On Watch " + fmtUptime(now.timeIntervalSince($0))) } ?? moo("已值守 —", "On Watch —")
        let (netRx, netTx) = networkCounters()
        var netUp: Double? = nil
        var netDown: Double? = nil
        if let p = netPrev {
            let dt = max(0.5, now.timeIntervalSince(p.t))
            netDown = netRx > p.rx ? Double(netRx - p.rx) / dt / 1024.0 : 0
            netUp = netTx > p.tx ? Double(netTx - p.tx) / dt / 1024.0 : 0
        }
        netPrev = (netRx, netTx, now)
        let avaB = availableBytes()
        let totB = totalRAMBytes()
        let lvl = pressureLevel()
        let sw = swapUsage()
        let swapMB = Int(sw.used / 1_048_576)

        swapRing = swapRing.filter { now.timeIntervalSince($0.0) <= swapTrendWin * 2 }
        swapRing.append((now, swapMB))
        if swapMB > swapPeakMB { swapPeakMB = swapMB }

        var trend = "→"
        let recent = swapRing.filter { now.timeIntervalSince($0.0) <= swapTrendWin }
        if let f = recent.first, let l = recent.last, l.1 - f.1 >= swapTrendEps { trend = "↗" }
        else if let f = recent.first, let l = recent.last, f.1 - l.1 >= swapTrendEps { trend = "↘" }

        let (pName, pColor): (String, NSColor) = lvl == 2 ? (moo("偏高", "Elevated"), .systemOrange) : (lvl == 4 ? (moo("告急", "Critical"), .systemRed) : (moo("正常", "Normal"), .systemGreen))
        let levelKey = lvl == 2 ? "warn" : (lvl == 4 ? "crit" : "ok")

        resolveGroups()

        // 单节奏采样：全进程/整机 GPU/整机 CPU 皆进程内直读（毫秒级），lsof + 探测子进程每拍跑（check 命令低频防阻塞）
        let proc = allProcesses()
        computePcpu(proc, now)
        procCache = proc
        cpuWhole = computeWholeCpu(now)
        gpuWhole = gpuUsagePct()
        if chipStr.isEmpty { chipStr = chipName() }
        (lisCache, estCache) = tcpStates(); probeCache = computeProbes(now)

        var runningPids: [Int] = []
        for g in groups { for it in g.items { runningPids += probeResult(it).pids.compactMap { Int($0) } } }
        if !runningPids.isEmpty { sampleIO(Array(Set(runningPids)), now: now) }
        let runningSet = Set(runningPids)
        for pid in ioPrev.keys where !runningSet.contains(pid) { ioPrev.removeValue(forKey: pid); ioCache.removeValue(forKey: pid) }

        maybeAlert(levelKey, swapMB, avaB)

        let titleText = "\(avaB / 1_073_741_824)"
        let t = NSMutableAttributedString(string: titleText)
        let full = NSRange(location: 0, length: (titleText as NSString).length)
        t.addAttribute(.foregroundColor, value: pColor, range: full)
        t.addAttribute(.font, value: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), range: full)
        item.button?.attributedTitle = t
        // tooltip（契约 §1 定稿 A）：中文保持原样；英文状态值前必须带 "Memory pressure:" 点名语义
        item.button?.toolTip = moo("MooKeeper — 可用 \(fmtGB(avaB)) · SWAP \(fmtSwap(swapMB)) · 压力 \(pName) · 点击看详情",
                                   "MooKeeper — \(fmtGB(avaB)) free · SWAP \(fmtSwap(swapMB)) · Memory pressure: \(pName) · Click for details")
        let tw = ceil((titleText as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)]).width)
        titleWidthPin = max(titleWidthPin ?? 0, tw)   // 只增不减：1→2→3 位数自适应，≥100G 不被截断，也避免抖动
        item.length = titleWidthPin! + 4

        // 顶部信息块：真·栅格（左列：内存/风扇/功率；右列：计算/温度）。
        // 图标独立放大渲染，值做成独立标签——列用固定 x 坐标对齐，不再靠等宽空格补位（emoji 宽度不是空格整数倍，永远对不齐）。
        let titleSegs: [(String, NSColor)] = [("MooKeeper", .labelColor)]
        let warningSegs: [(String, NSColor)]? = configLoadWarning.map { [("⚠ " + $0, .systemOrange)] }

        let hc = hlColor(cfg.highlights.color)
        let sg = NSColor.secondaryLabelColor  // 正常态统一：数据/数值一律灰；标题 labelColor、正常标签绿、芯片淡灰

        // —— 内存卡（🐏 + 3 行值）——
        let aGB = String(format: "%.1f", Double(avaB) / 1_073_741_824)
        let bGB = String(format: "%.1f", Double(totB) / 1_073_741_824)
        let memMain = (avaB > 0 && totB > 0)
            ? moo("剩余 \(aGB) / \(bGB) GB", "\(aGB) / \(bGB) GB free")
            : moo("内存吃紧", "Memory Pressure")
        let trendColor: NSColor = trend == "↗" ? NSColor.systemOrange : sg   // 只有「↗」才橙
        var memRows: [HeaderRow] = [
            HeaderRow(icon: "🐏", segs: [(memMain, sg), (" ", sg), (pName, pColor)]),
            HeaderRow(icon: nil, segs: [("SWAP \(fmtSwap(swapMB))", sg), (" ", sg), (trend, trendColor), (" ", sg), (moo("峰\(fmtSwap(swapPeakMB))", "peak \(fmtSwap(swapPeakMB))"), sg)]),
        ]
        // 磁盘（主系统卷 /）：剩余/总，向下取整；占用 ≥70% 「资源不足」橙、≥90% 「资源告急」红
        if let dk = diskInfo() {
            let availGB = Int((Double(dk.avail) / 1_073_741_824).rounded(.down))
            let totalGB = Int((Double(dk.total) / 1_073_741_824).rounded(.down))
            let usedPct = dk.total > 0 ? Int(Double(dk.total - dk.avail) * 100 / Double(dk.total)) : 0
            let dkName: String
            let dkColor: NSColor
            if usedPct >= cfg.highlights.diskCritPercent { dkName = moo("资源告急", "Critical"); dkColor = .systemRed }
            else if usedPct >= cfg.highlights.diskWarnPercent { dkName = moo("资源不足", "Low"); dkColor = .systemOrange }
            else { dkName = moo("正常", "Normal"); dkColor = .systemGreen }
            memRows.append(HeaderRow(icon: nil, segs: [(moo("存储 \(availGB)/\(totalGB) GB", "Storage \(availGB)/\(totalGB) GB"), sg), (" ", sg), (dkName, dkColor)]))
        }
        let memCard = HeaderCard(rows: memRows)

        // —— 计算卡（🚜：CPU·GPU 合一行 + 负载均值一行 + 芯片一行）——
        let loadLine = loadAvg.count == 3
            ? moo(String(format: "负载 %.2f · %.2f · %.2f", loadAvg[0], loadAvg[1], loadAvg[2]),
                  String(format: "Load %.2f · %.2f · %.2f", loadAvg[0], loadAvg[1], loadAvg[2]))
            : moo("负载 —", "Load —")
        let cpuC = cpuWhole > cfg.highlights.cpuPercent ? hc : sg
        let gpuC = gpuWhole > cfg.highlights.gpuPercent ? hc : sg
        let compCard = HeaderCard(rows: [
            HeaderRow(icon: "🚜", segs: [(String(format: "CPU %.0f%%", cpuWhole), cpuC), (" · ", sg), (String(format: "GPU %.0f%%", gpuWhole), gpuC)]),
            HeaderRow(icon: nil, segs: [(loadLine, sg)]),
            HeaderRow(icon: nil, segs: [(chipStr, NSColor.tertiaryLabelColor)]),
        ])

        // —— 风扇 🐝 与 功率 🐎 拆成两卡（各一行，卡间留 rowGap 分隔）——
        let fans = fanRPMs()
        let fanCard: HeaderCard? = fans.isEmpty ? nil : {
            let hot = fans.contains { $0 > cfg.highlights.fanRPM }
            // D7 ✅ 英文去「转速」前缀：🐝 图标已表意，"Fan … RPM" 属重复且占宽
            let joined = fans.map(String.init).joined(separator: " / ")
            let txt = moo("转速 \(joined) RPM", "\(joined) RPM")
            return HeaderCard(rows: [HeaderRow(icon: "🐝", segs: [(txt, hot ? hc : sg)])])
        }()
        let powerCard: HeaderCard? = smcVal("PDTR").map { w in
            let vv = smcVal("VD0R").map { String(format: "%.1f V", $0) }
            let aa = smcVal("ID0R").map { String(format: "%.2f A", $0) }
            let extra = [vv, aa].compactMap { $0 }.joined(separator: " · ")
            return HeaderCard(rows: [HeaderRow(icon: "🐎", segs: [(String(format: "%.1f W", w) + (extra.isEmpty ? "" : " · " + extra), sg)])])
        }

        // —— 温度 ☀️ 与 网络（icon 随主力出口变 📡/⚡️/🕸️，判不出 🚚）拆成两卡（各一行，卡间留 rowGap 分隔）——
        let cpuT = cachedTemp(&cpuTempKey, ["Tp0X", "Tp0T", "Tp09", "TC0P", "TC0D", "Tp01", "Tp05", "Tp0D"])
        let gpuT = cachedTemp(&gpuTempKey, ["Tg0j", "TG0D", "TG0P", "TG0H", "Tg0T"])
        let tempSeg = [cpuT.map { String(format: "CPU %.0f°C", $0) }, gpuT.map { String(format: "GPU %.0f°C", $0) }]
            .compactMap { $0 }.joined(separator: " · ")
        let tempCard: HeaderCard? = tempSeg.isEmpty ? nil : HeaderCard(rows: [HeaderRow(icon: "☀️", segs: [(tempSeg, sg)])])
        let upTxt = netUp.map { "↑ " + fmtRate($0) } ?? "↑ —"
        let downTxt = netDown.map { "↓ " + fmtRate($0) } ?? "↓ —"
        // 头图 icon = 主力出口材质（📡 Wi-Fi / ⚡️ 雷雳 / 🕸️ 有线；判不出回落 🚚）；每拍直读，微秒级，刷新按钮天然同步。
        // ↑↓ 数字是全网卡累计口径，icon 只认系统主力出口——VPN 流量计入数字、icon 指其脚下物理腿。
        let egress = netEgressKind()
        let netCard = HeaderCard(rows: [HeaderRow(icon: egress.kind.icon, segs: [(upTxt + " · " + downTxt, sg)])])

        // 组织成栅格：左列 [内存, 风扇, 功率]，右列 [计算, 温度, 网络]
        var leftCards: [HeaderCard] = [memCard]
        var rightCards: [HeaderCard] = [compCard]
        if let f = fanCard { leftCards.append(f) }
        if let p = powerCard { leftCards.append(p) }
        if let t = tempCard { rightCards.append(t) }
        rightCards.append(netCard)

        let subtitleSegs: [(String, NSColor)] = [(upText, NSColor.secondaryLabelColor)]
        let logoDarkNow = menuLogoUsesDark()
        // 菜单展开中：只就地刷新头图数值，别整棵重建菜单（removeAllItems 会闪、可能顶关菜单）
        if menuOpen, let hv = headerView {
            if logoDark != logoDarkNow {          // 系统白天/黑夜切换：随 5s 刷新就地换 logo，不必关菜单
                logoDark = logoDarkNow
                hv.setLogo(menuLogoImage())
            }
            hv.update(title: titleSegs, subtitle: subtitleSegs, warning: warningSegs, left: leftCards, right: rightCards)
            return
        }
        menu.removeAllItems()

        menu.addItem(NSMenuItem.separator())
        addSection(moo("内存大户 · TOP \(cfg.topN)", "Memory Hogs · TOP \(cfg.topN)"))
        let fpAgg = footprintAggregate()
        if !fpAgg.isEmpty {
            let cpuAgg = cpuAggregate()
            for (name, v) in fpAgg.sorted(by: { $0.value.mb > $1.value.mb }).prefix(cfg.topN) {
                // 左起三格占位 = 状态符号列：名称与下方条目同起点；数值尾右贴固定右缘。
                // 「N进程」按*像素*定宽（padPx 实测）——CJK 是双宽字，按字符数凑定宽会在
                // 有/无进程数时让整条尾变宽、内存/CPU 两列跟着漂移（错位根因）
                let nCol = "   " + pad(name, 24)
                let mCol = pad(fmtMem(Int(v.mb * 1024)), 8, right: true)
                let cpu = cpuAgg[name] ?? 0
                let cCol = cpu > 0 ? pad(String(format: "CPU %.0f%%", cpu), 10, right: true) : pad("CPU —", 10, right: true)
                let cntPx = padPx(v.count > 1 ? moo("\(v.count)进程", "×\(v.count)") : "", 6 * monoSpace)
                let tailStr = mCol + "  " + cCol + "  " + cntPx   // 全程 ASCII 列定宽 + 进程数像素定宽 → 每行像素等宽
                // 应用名半粗主色，数值尾次级灰（Apple 风格层级）
                addSegsMonoF([(nCol, NSColor.labelColor, monoFontB),
                              (rightPad(nCol, tailStr), nil, nil),
                              (tailStr, NSColor.secondaryLabelColor, nil)])
            }
        } else {
            addInfo(moo("（读不到进程，无法列）", "Can't read the process list"), .secondaryLabelColor)
        }

        renderGroups()

        if let (ts, msg) = lastError, now.timeIntervalSince(ts) <= Hardwired.lastErrorTTL {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            // 自绘行（2026-10-04 用户拍板）：整行可点关闭 + 行尾 ✕，点完清掉并收菜单。
            // 旧版是 disabled 文本行、整行 systemOrange——浅色菜单底上对比度 ~2:1 看不清，且只能干等 5 分钟。
            let err = NSMenuItem()
            err.view = ErrorNoteRowView(time: f.string(from: ts), msg: msg) { [weak self] in
                guard let self else { return }
                self.lastError = nil
                // 与批量按钮同款收尾（坑 17）：点完＝替你按 ESC，先收菜单。
                self.menu.cancelTracking()
                // ⚠ 重建必须 hop 回主队列、不能在 cancelTracking 后同步调 refresh()——
                // 那一刻 menuDidClose 还没跑到、menuOpen 仍为 true，refresh() 会走「展开中只刷头图」
                // 早退分支不重建条目，而且早退前已把 lastRefreshAt 顶新 → 0.5s 内重开连节流 rebuild
                // 都跳过，旧行会复活一下（--errtest B 实测 okGone=false 抓到，d.md §39）。
                // hop 之后菜单已关，重建真发生：行没了、lastRefreshAt 也是重建后时刻，重开即干净。
                DispatchQueue.main.async { self.refresh() }
            }
            menu.addItem(err)
        }
        let fm = selfFootprintMB()

        menu.addItem(NSMenuItem.separator())
        addAction("Activity Monitor", "open-am", nil)
        // 刷新行=自绘整行可点视图（分组头批量启停同机制）：点它不收菜单、就地刷头图。
        // ⌘R 不挂条目 keyEquivalent——视图条目进不了菜单的快捷键匹配（本机实测纯摆设），
        // 点击/按键都由 RefreshRowView 自己接（mouseDown / performKeyEquivalent），不会双发。
        let r = NSMenuItem()
        r.view = RefreshRowView { [weak self] in self?.userRefresh() }
        menu.addItem(r)
        let prefs = NSMenuItem(title: moo("配置…", "Settings…"), action: #selector(handle(_:)), keyEquivalent: ",")
        prefs.keyEquivalentModifierMask = [.command]
        prefs.target = self
        prefs.representedObject = MenuAction("settings", nil)
        menu.addItem(prefs)
        menu.addItem(NSMenuItem.separator())
        let aboutBase = moo("关于 MooKeeper", "About MooKeeper")
        if fm > 0 { addActionSplit(aboutBase, moo(String(format: " · 占内存 %.0fM", fm), String(format: " · %.0fM memory", fm)), "about", nil) }
        else { addAction(aboutBase, "about", nil) }
        let quit = NSMenuItem(title: moo("退出", "Quit"), action: #selector(handle(_:)), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.command]
        quit.target = self
        quit.representedObject = MenuAction("quit", nil)
        menu.addItem(quit)
        // 顶部头图：标题行 + 双列栅格；品牌牛 logo 只放标题行右侧（宽度对齐菜单）
        let headerItem = NSMenuItem()
        logoDark = logoDarkNow
        let hv = MenuHeaderView(title: titleSegs, subtitle: subtitleSegs, warning: warningSegs, left: leftCards, right: rightCards, logo: menuLogoImage())
        headerView = hv
        headerItem.view = hv
        menu.insertItem(headerItem, at: 0)
        // 分组头拉齐菜单总宽：按最宽行（文本行+左右边距、自绘视图行原宽）拉伸 GroupHeaderView，
        // 按钮贴右（否则固定 300px 的头只有菜单左 2/3 宽，右侧大空洞）。必须在头图插入之后量，
        // 头图（480px 定宽者）不进 menu.items 就量不到
        var textW: CGFloat = 0      // 分组头拉伸基准（≈右缘线 600 + 边距）——保持原行为，右贴内容勿动
        var inkMax: CGFloat = 0     // 最宽文本行墨迹：AppKit 真实行宽 ≈ ink + 81（--menu-geo 实测，见 d.md §26）
        for mi in menu.items where !mi.isSeparatorItem {
            if let v = mi.view {
                textW = max(textW, v.frame.width)   // 顶部头图等自绘行本来撑开菜单宽
            } else {
                let w = mi.attributedTitle?.size().width
                    ?? (mi.title as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 13)]).width
                textW = max(textW, w + 34)          // 文本行左右内边距（旧估）
                inkMax = max(inkMax, w)
            }
        }
        // 菜单真实宽度：AppKit 给文本行加的水平空间实测 ≈81（含快捷键列预留；--menu-geo 量得
        // 窗口 669 vs 旧估 621.6）。只有「刷新」行按菜单全宽拉伸——它的 ⌘R 提示要对齐系统画的
        // ⌘,/⌘Q 快捷键列；分组头/头图保持原宽（其右贴内容锚在 600 线，是定稿设计）。
        let menuW = max(textW, inkMax + 82)
        if textW > 0 {
            for mi in menu.items {
                if let gh = mi.view as? GroupHeaderView { gh.stretch(to: textW) }
                if let rr = mi.view as? RefreshRowView { rr.stretch(to: menuW) }
                // 失败提醒行同「刷新」行拉全宽：悬停药丸要盖满整行，✕ 才贴得到右缘
                if let er = mi.view as? ErrorNoteRowView { er.stretch(to: menuW) }
            }
        }
        item.menu = menu
    }

    // MARK: 进程聚合
    private func footprintAggregate() -> [String: (mb: Double, count: Int)] {
        var res: [String: (mb: Double, count: Int)] = [:]
        for p in procCache.values {
            let name = appKey(p.comm)
            var v = res[name] ?? (0, 0)
            v.mb += Double(p.footprintBytes) / 1_048_576
            v.count += 1
            res[name] = v
        }
        return res
    }
    private func cpuAggregate() -> [String: Double] {
        var res: [String: Double] = [:]
        for (pid, v) in pcpuCache {
            if let p = procCache[pid] { res[appKey(p.comm), default: 0] += v }
        }
        return res
    }

    // MARK: 服务/模型渲染
    private func renderGroups() {
        menu.addItem(NSMenuItem.separator())
        guard !groups.isEmpty else {
            addInfo(moo("尚未配置服务/模型分组", "No groups configured yet"), .secondaryLabelColor)
            addInfo(moo("按 ⌘, 添加你的分组与脚本（条目 = 启动/停止命令 + 端口状态）",
                        "Press ⌘, to add groups and scripts (item = start/stop commands + port status)"), .secondaryLabelColor)
            return
        }

        for (i, g) in groups.enumerated() {
            let anyRunningInGroup = g.items.contains { probeResult($0).running }
            let anyStartableIdle = g.items.contains { $0.start != nil && !$0.start!.isEmpty && $0.loadable && !probeResult($0).running }
            let headerItem = NSMenuItem()
            headerItem.title = g.title        // 供 --dump 展示；实际渲染用 headerItem.view
            headerItem.view = makeGroupHeader(g, anyRunning: anyRunningInGroup, anyIdle: anyStartableIdle)
            menu.addItem(headerItem)
            for it in g.items { renderItem(it) }
            if i < groups.count - 1 { menu.addItem(NSMenuItem.separator()) }
        }

        let anyRun = groups.contains { g in g.items.contains { probeResult($0).running } }
        for fa in footer {
            if fa.showWhenAnyRunning && !anyRun { continue }
            if busy["footer-\(fa.label)"] != nil { addInfo("⏳ " + nameBrief(fa.label) + moo("进行中…", " in progress…"), .secondaryLabelColor) }
            else {
                // 底部动作只显名称（不展示脚本），名称预算比条目宽：行里没有端口/状态列
                addAction(truncPx(fa.label, Trunc.footerNamePx, font: NSFont.menuFont(ofSize: 13)), "footer", fa.label)
            }
        }
        }

    // MARK: 分组头：标题 + 右侧「全部启动/全部停止」按钮（单行，不拆两行）
    func makeGroupHeader(_ g: Group, anyRunning: Bool, anyIdle: Bool) -> NSView {
        var startBtn: BulkActionButton?
        var stopBtn: BulkActionButton?
        var busyText: String?
        if busy["bulk-start-\(g.title)"] != nil { busyText = moo("⏳ 全部启动中…", "⏳ Starting all…") }
        else if busy["bulk-stop-\(g.title)"] != nil { busyText = moo("⏳ 全部停止中…", "⏳ Stopping all…") }
        else {
            if g.allowStartAll && !g.exclusive && anyIdle {
                startBtn = makeBulkButton(moo("▶ 全部启动", "▶ Start All"), title: g.title, isStart: true)
            }
            if g.allowStopAll && anyRunning {
                stopBtn = makeBulkButton(moo("■ 全部停止", "■ Stop All"), title: g.title, isStart: false)
            }
        }
        return GroupHeaderView(title: g.title, startButton: startBtn, stopButton: stopBtn, busyText: busyText)
    }

    private func makeBulkButton(_ text: String, title: String, isStart: Bool) -> BulkActionButton {
        let b = BulkActionButton(title: text)
        b.groupTitle = title
        b.isStart = isStart
        b.onClick = { [weak self] sender in self?.bulkButtonTapped(sender) }
        return b
    }

    func bulkButtonTapped(_ sender: BulkActionButton) {
        bulk(sender.groupTitle, start: sender.isStart)
        // 点完＝替你按一下 ESC（2026-10-04 用户拍板）：bulk() 已经同步把整批丢进后台队列，
        // 这里收菜单不影响它继续跑（完成照旧发通知；重开菜单能看到 ⏳ 忙碌行）。
        // 对照组实测（d.md §32）：不收菜单的话批量收尾（busy 清空 + 完成通知）会一直卡在主队列
        // 上排不到——跟踪期 DispatchQueue.main.async 不排水，直到人工关菜单才补跑。
        // 「刷新」行故意不收起，别跟着改（那是用户明确要的）。
        menu.cancelTracking()
    }

    // 忙碌行（⏳ …（完成会通知））不做列排，但一样要防长名字撑爆菜单：
    // 名字统一走 nameBrief（150px），前缀/尾巴原样
    private func busyLine(_ doing: String, _ label: String) -> String {
        let prefix = "⏳ " + doing + " "
        let capped = nameBrief(label)
        // 名字截断时自带「…」，尾巴不再重复加；没截断才补分隔「…」，否则会出现「名字……（完成会通知）」
        let tail = capped != label ? moo("（完成会通知）", " (will notify when done)")
                                   : moo("…（完成会通知）", "… (will notify when done)")
        return prefix + capped + tail
    }

    private func renderItem(_ it: GroupItem) {
        let pr = probeResult(it)
        let running = pr.running
        let pids = pr.pids
        // 规整列布局（2026-10-03 改）：状符号 2 字宽 → 名称列（130px，超长「…」截断）
        // → 探测列（110px，同样截断）→ 尾列（「未运行」/运行指标）。列宽固定，超长不撑爆菜单
        let mCol = padPx(running ? "●" : "○", monoSpace * 2)
        let lCol = padPx(truncPx(it.label, Trunc.nameColPx), Trunc.nameColPx)
        let pCol = padPx(truncPx(probeCol(it), Trunc.probeColPx), Trunc.probeColPx)
        let off = truncPx(it.labelOff, Trunc.labelOffPx)   // labelOff 也来自配置，尾列一样截断防撑爆
        // 视觉层级（2026-10-03 整体设计改版）：●=系统绿/○=三级灰；名称列等宽半粗主色；探测/指标次级灰；
        // 负载档标签照旧着色。等宽半粗与常规同字宽，列对齐不受影响
        let markC: NSColor = running ? .systemGreen : .tertiaryLabelColor
        if running {
            let rss = pids.compactMap { Int($0) }.reduce(0) { $0 + (procCache[$1].map { Int($0.footprintBytes / 1024) } ?? 0) }
            let load = itemLoad(it, pr)
            let lvlColor: NSColor = load.tier == 2 ? .systemRed : (load.tier == 1 ? .systemOrange : .secondaryLabelColor)   // ⚠ 比 tier 不比显示串（契约 D4 雷区）
            // 指标段拼成一串后按剩余预算截断，压进固定右缘线内不贴边；等级标签永远保留
            let front = mCol + " " + lCol + " " + pCol
            var mid = ""
            if !pids.isEmpty { mid += "  PID " + pids.compactMap(Int.init).sorted().map(String.init).joined(separator: ",") }
            if rss > 0 { mid += "  " + fmtMem(rss) }
            if load.est > 0 { mid += moo("  连接 \(load.est)", "  \(load.est) conns") }
            mid += String(format: "  CPU %.0f%%", load.cpu)
            if load.gpu >= 0.5 { mid += String(format: "  GPU %.0f%%", load.gpu) }
            if load.io >= 1 { mid += "  IO " + fmtIO(load.io) }
            let tag = "  " + load.level   // 负载档无方括号（省宽防截断，视觉也干净）；颜色照旧
            let midT = truncPx(mid, Trunc.menuRightPx - 14 - monoWidth(front) - monoWidth(tag))
            var segs: [(String, NSColor?, NSFont?)] = [
                (mCol, markC, nil),
                (" " + lCol, nil, monoFontB),
                (" " + pCol, NSColor.secondaryLabelColor, nil),
                (midT, NSColor.secondaryLabelColor, nil),
                (tag, lvlColor, nil)]
            if busy["stop-\(it.key)"] != nil { addInfo(busyLine(moo("停止/卸载中", "stopping/unloading"), it.label), .secondaryLabelColor) }
            else if it.confirmStop {
                if let ts = pending[it.key], Date().timeIntervalSince(ts) <= cfg.confirmWindow {
                    let remain = max(1, Int(cfg.confirmWindow - Date().timeIntervalSince(ts)))
                    addAction(moo("⚠ 再点一次确认停止 ", "⚠ tap again to confirm stop ") + nameBrief(it.label)
                              + moo("（剩 \(remain)s）", " (\(remain)s left)"), "confirm", it.key, color: .systemOrange)
                } else { addSegsF(segs, "confirm", it.key) }
            } else if it.stop != nil, !it.stop!.isEmpty { addSegsF(segs, "stop", it.key) }
            else { addSegsMonoF(segs) }
            if let u = it.url, !u.isEmpty, URL(string: u) != nil {
                addAction("        " + moo("↗ 打开网页", "↗ Open URL"), "open-url", it.key, color: .tertiaryLabelColor)
            }
        } else {
            if busy["start-\(it.key)"] != nil { addInfo(busyLine(moo("启动/装载中", "starting/loading"), it.label), .secondaryLabelColor) }
            else {
                // 「未运行/已卸载」右贴：右对齐制表位把尾字右缘钉死在 menuRightPx−14——
                // 与前行内容宽度解耦（原 rightPad 手补空格按整格取整，截断名会翻桶错位 5px+）
                if !it.loadable || it.start == nil || it.start!.isEmpty {
                    addSegsMonoF([(mCol, nil, nil), (" " + lCol, nil, monoFontB), (" " + pCol, nil, nil), ("\t" + off, nil, nil)], para: tailRightPara)
                } else {
                    addSegsF([(mCol, markC, nil), (" " + lCol, nil, monoFontB),
                              (" " + pCol, NSColor.secondaryLabelColor, nil),
                              ("\t" + off, NSColor.secondaryLabelColor, nil)], "start", it.key, para: tailRightPara)
                }
            }
        }
    }

    // MARK: 预警
    private func maybeAlert(_ level: String, _ swapMB: Int, _ ava: UInt64) {
        let now = Date().timeIntervalSince1970
        let prev = alert["level"] as? String ?? "ok"
        let changed = prev != level
        let critDue = (alert["crit_ts"] as? Double).map { now - $0 } ?? critRepeat >= critRepeat
        let memTxt = ava > 0 ? moo("剩余可用 \(fmtGB(ava))", "\(fmtGB(ava)) free") : moo("内存吃紧", "memory pressure")   // D1 ✅ 契约词（弃 low on memory）
        if level == "crit" && (changed || critDue) {
            notify(moo("🐮 哞！内存告急", "🐮 Moo! memory critical"),
                   moo("\(memTxt)，SWAP \(fmtSwap(swapMB))——先卸载大户（菜单可一键卸载）",
                       "\(memTxt), SWAP \(fmtSwap(swapMB)) — unload the memory hogs (one click in the menu)"),
                   sound: true)
            alert["crit_ts"] = now
        } else if level == "warn" && changed {
            notify(moo("🐮 哞…… 内存预警", "🐮 Moo… memory warning"),
                   moo("\(memTxt)，SWAP \(fmtSwap(swapMB))——检查谁在吃内存",
                       "\(memTxt), SWAP \(fmtSwap(swapMB)) — check what's eating memory"),
                   sound: true)
            alert["warn_ts"] = now
        }
        if swapMB > 0 { alert["swap_seen"] = true }
        alert["level"] = level
        alert["swap"] = swapMB
    }
}

// MARK: 分组头视图（内嵌于菜单项：左标题 + 右按钮列）
// 「刷新」行=自绘整行可点视图：菜单对带自绘视图的条目不做「点击即收起」（分组头的批量
// 启停按钮同机制，本机实测点按钮菜单不收），点击在视图内直接回调、菜单保持展开；
// 悬停画系统菜单同款高亮。⌘R 仍挂在条目的 keyEquivalent 上（菜单展开时按下=走 handle
// 的 refresh 分支，收不收由 menuShouldClose 的 delegate 兜底管）。
final class RefreshRowView: NSView {
    static let height: CGFloat = 22
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    /// 诊断口（--menu-keytest openrefresh）：核对悬停残留有没有被清干净
    var isHovered: Bool { hovered }
    /// 菜单收起/打开时清残留：cancelTracking 关窗不会补发 mouseExited（d.md §33）
    func clearHover() { hovered = false }
    private var geoLogged = false
    private let onFire: () -> Void

    init(onFire: @escaping () -> Void) {
        self.onFire = onFire
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: Self.height))   // 宽度建完菜单后 stretch 拉齐
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func stretch(to width: CGFloat) {
        guard width > 0, abs(width - frame.width) > 0.5 else { return }
        frame.size.width = width
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // MOO_MENU_GEO=1：画帧即窗口已定稿——量真实窗宽/行宽最可靠的时机（跟踪期定时器不排水，
        // stderr 无缓冲先落盘，进程就算被 pkill 日志也在）
        if !geoLogged, ProcessInfo.processInfo.environment["MOO_MENU_GEO"] != nil {
            geoLogged = true
            fputs("menu-geo: refresh-draw window=\(window?.frame ?? .zero) bounds=\(bounds)\n", stderr)
        }
        if hovered {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        let isHi = hovered
        // 文字左缘 16.5 = 原生条目文本缩进（真机截图实测，原 14 比系统行靠左 2.5pt）
        (moo("刷新", "Refresh") as NSString).draw(at: NSPoint(x: 16.5, y: 4), withAttributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: isHi ? NSColor.alternateSelectedControlTextColor : NSColor.labelColor])
        // 快捷键提示=三级灰 tertiaryLabel（§26.2 用户拍板：对齐系统 ⌘Q/⌘, 的快捷键灰）
        // secondaryLabelColor 偏亮（§26.1 实测 153 vs 系统 104），tertiary 才压得上系统列；
        let key = NSAttributedString(string: "⌘R", attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: isHi ? NSColor.alternateSelectedControlTextColor
                                   : NSColor.tertiaryLabelColor,
            .kern: 1.0])   // ⌘|R 间距补到 3pt（系统 ⌘|Q 实测 3.0pt，默认排版只有 2.0pt）
        // 右缘 17 对齐系统快捷键列：窗宽 670 时 ⌘Q 墨迹右缘 651.5，R 字形墨迹比布局点短 ~1.1，
        // 669.63−17−1.1 ≈ 651.5 正好压上。位置/字距沿用 §26.1 已确认的校准，只动颜色。
        key.draw(at: NSPoint(x: bounds.width - 17 - key.size().width, y: 4))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for ta in trackingAreas { removeTrackingArea(ta) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    // 注：⌘R 不由视图行接——视图条目进不了菜单的快捷键匹配，菜单跟踪期的 keyDown 也不会沿
    // 窗口/视图链问 performKeyEquivalent（--menu-keytest 实证两条都不被调用）。⌘R 走 App
    // 的本地事件监视器（installKeyMonitor），这里是纯粹的行点击。
    override func mouseDown(with event: NSEvent) {
        guard event.type == .leftMouseDown else { return }
        onFire()
    }
}

/// 「⚠ 上次动作失败」提醒行（2026-10-04 用户报障：整行 systemOrange 在浅色菜单底看不清、且只能干等超时）。
/// 与「刷新」行同族的自绘行：整行可点、悬停蓝色药丸（selectedContentBackgroundColor）+ 文字翻白
/// （alternateSelectedControlTextColor）——不用 NSButton（坑 17 两条都实锤）。
/// 配色：⚠ 保持橙色只做警示符号（图标不背正文对比度指标），正文 labelColor、时间戳 tertiaryLabelColor，
/// 可读性不再依赖橙色；行尾常驻 ✕（三级灰，悬停翻白）作「可点关闭」的视觉暗示。
/// 点击 = 清 lastError + 收菜单（调用方接线处注释说明为何先 cancelTracking 再 refresh）。
final class ErrorNoteRowView: NSView {
    static let height: CGFloat = 22
    static let textX: CGFloat = 16.5     // 文本左缘 = 原生条目缩进（RefreshRowView 同一定标）
    static let rightInset: CGFloat = 16.5
    var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }   // 非 private：诊断离屏出图置位（同 BulkActionButton 先例）
    func clearHover() { hovered = false }
    private let full: String
    private let timeStr: String
    private let msg: String
    private let onDismiss: () -> Void
    private let font = NSFont.systemFont(ofSize: 13)

    init(time: String, msg: String, onDismiss: @escaping () -> Void) {
        self.timeStr = time
        // 命令输出可能带换行，自绘行不折行——拍平成空格（旧文本条目同样不会换行，观感一致）
        self.msg = msg.replacingOccurrences(of: "\n", with: " ")
        self.full = moo("⚠ 上次动作失败（\(time)）：\(self.msg)",
                        "⚠ Last action failed (\(time)): \(self.msg)")
        self.onDismiss = onDismiss
        let textW = (full as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
        let crossW = ("✕" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
        super.init(frame: NSRect(x: 0, y: 0,
                                 width: ceil(Self.textX + textW + 10 + crossW + Self.rightInset),
                                 height: Self.height))   // 菜单建完后 stretch 到全宽，✕ 贴右缘
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func stretch(to width: CGFloat) {
        guard width > 0, abs(width - frame.width) > 0.5 else { return }
        frame.size.width = width
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovered {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        let a = NSMutableAttributedString()
        func seg(_ s: String, _ c: NSColor) {
            a.append(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: c]))
        }
        if hovered {
            seg(full, .alternateSelectedControlTextColor)
        } else {
            seg("⚠", .systemOrange)
            seg(moo(" 上次动作失败", " Last action failed"), .labelColor)
            seg(moo("（\(timeStr)）", " (\(timeStr))"), .tertiaryLabelColor)
            seg(moo("：\(msg)", ": \(msg)"), .labelColor)
        }
        a.draw(at: NSPoint(x: Self.textX, y: 4))
        let cross = NSAttributedString(string: "✕", attributes: [
            .font: font,
            .foregroundColor: hovered ? NSColor.alternateSelectedControlTextColor : NSColor.tertiaryLabelColor])
        cross.draw(at: NSPoint(x: bounds.width - Self.rightInset - cross.size().width, y: 4))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for ta in trackingAreas { removeTrackingArea(ta) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) {
        guard event.type == .leftMouseDown else { return }
        onDismiss()
    }
}

/// 分组头右侧「▶ 全部启动 / ■ 全部停止」（2026-10-04 加悬停高亮 + 点完收菜单）。
/// **自绘 NSView，不是 NSButton**——沿用「刷新」行已在真机验证的那套：`.activeAlways` 跟踪 +
/// 自绘 selectedContentBackgroundColor 药丸 + 文字翻白（alternateSelectedControlTextColor）。
/// 为什么不用 NSButton（d.md §32 实测记录，两条都踩过）：
///   ① NSButton 子类只要 override draw(_:)（连空壳 `super.draw(r)` 都算），标题就整体从
///      controlTextColor 变强调色蓝；
///   ② 改用 attributedTitle 塞动态色（alternateSelectedControlTextColor）时 cell 不认，仍按
///      controlTextColor 画 → 悬停时深字压蓝底。自绘文本两档事都没有。
/// 只亮按钮本身、不亮整行（用户拍板）。
final class BulkActionButton: NSView {
    var groupTitle = ""
    var isStart = true
    let title: String
    var onClick: ((BulkActionButton) -> Void)?
    var hovered = false {          // 非 private：离线出图核对高亮时由诊断程序置位
        didSet { if hovered != oldValue { needsDisplay = true } }
    }
    private let font = NSFont.systemFont(ofSize: 12)
    private let padX: CGFloat = 8   // 左右内边距（药丸比文字宽出来，跟原来 NSButton 的 bezel 观感一致）

    init(title: String) {
        self.title = title
        let tw = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
        super.init(frame: NSRect(x: 0, y: 0, width: ceil(tw) + padX * 2, height: 18))
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 菜单收起/打开时由 App 的 clearStaleHover() 调用：cancelTracking 关菜单不会补发 mouseExited，
    /// 不清的话重开（同一批旧 view）会带着残留的蓝色药丸（d.md §33）。
    func clearHover() { hovered = false }

    /// 诊断用：走与真实点击完全同一条回调（--menu-keytest bulk / 离线出图）
    func performBulkClick() { onClick?(self) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for ta in trackingAreas { removeTrackingArea(ta) }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func draw(_ dirtyRect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: hovered ? NSColor.alternateSelectedControlTextColor : NSColor.controlTextColor]
        if hovered {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        let s = title as NSString
        let sz = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: (bounds.width - sz.width) / 2, y: (bounds.height - sz.height) / 2), withAttributes: attrs)
    }

    // 自绘视图条目：菜单对带自绘视图的条目不自动收起，点击直接回调（同 RefreshRowView 机制）
    override func mouseDown(with event: NSEvent) {
        guard event.type == .leftMouseDown else { return }
        onClick?(self)
    }
}

final class GroupHeaderView: NSView {
    static let defaultWidth: CGFloat = 300   // 初建宽度；菜单建完后按最宽文本行 stretch 拉齐
    static let height: CGFloat = 24
    private var rightViews: [NSView] = []    // 从右往左贴的右侧控件（stop/start 按钮或忙碌文案）
    private(set) var buttons: [BulkActionButton] = []   // 诊断用（--menu-keytest bulk 要能拿到按钮）

    init(title: String, startButton: BulkActionButton?, stopButton: BulkActionButton?, busyText: String?) {
        super.init(frame: NSRect(x: 0, y: 0, width: GroupHeaderView.defaultWidth, height: GroupHeaderView.height))

        let tl = NSTextField(labelWithString: title)
        tl.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        tl.textColor = .labelColor
        tl.lineBreakMode = .byTruncatingTail
        addSubview(tl)
        tl.frame = NSRect(x: 14, y: 5, width: 130, height: 15)

        if let busyText {
            let b = NSTextField(labelWithString: busyText)
            b.font = NSFont.systemFont(ofSize: 12)
            b.textColor = .secondaryLabelColor
            b.sizeToFit()
            addSubview(b)
            rightViews.append(b)
        } else {
            for btn in [stopButton, startButton].compactMap({ $0 }) {
                addSubview(btn)          // 尺寸在 BulkActionButton.init 里按文字算好（自绘视图，不用 sizeToFit）
                rightViews.append(btn)   // 追加顺序即右→左：stop 在最右
                buttons.append(btn)
            }
        }
        relayoutRight()
    }

    // 菜单收起/打开时 App 会调这个清按钮的残留悬停（见 App.clearStaleHover / d.md §33）
    func clearHover() { for b in buttons { b.hovered = false } }

    // 右侧控件按当前宽度贴右
    private func relayoutRight() {
        var x = frame.width - 10
        for v in rightViews {
            v.frame.origin = NSPoint(x: x - v.frame.width, y: v is BulkActionButton ? 1 : 5)
            x -= v.frame.width + 6
        }
    }

    // 菜单总宽定了之后拉齐到菜单宽度（否则整个分组头只有 300px，按钮悬在菜单左 2/3、右边大空洞）
    func stretch(to width: CGFloat) {
        guard width > 0, abs(width - frame.width) > 0.5 else { return }
        frame.size.width = width
        relayoutRight()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: 关于面板（SwiftUI）
struct AboutView: View {
    let version: String
    private var zh: Bool { isZhLocale() }   // 整版按系统语言二选一，不中英混排（用户 2026-10-03 拍板）

    var body: some View {
        VStack(spacing: 12) {
            if let img = NSApp.applicationIconImage {
                Image(nsImage: img)
                    .resizable()
                    .frame(width: 92, height: 92)
            }
            Text(zh ? "看门牛" : "MooKeeper")
                .font(.system(size: 20, weight: .semibold))
            Text(zh ? "一只住在菜单栏里、帮你看着 Mac 的小牛。" : "A little cow keeping an eye on your Mac.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Text(zh ? "版本 \(version)" : "Version \(version)")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Link(zh ? "关于我 ↗" : "About ↗", destination: URL(string: githubRepoURL)!)
                .font(.system(size: 13))
                .padding(.top, 2)
        }
        .padding(24)
        .frame(width: 320)
    }
}

// MARK: 菜单顶部「看门牛」头图（左：信息文字 / 右：logo，随系统外观切图）
func menuLogoUsesDark() -> Bool {
    NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
}

func menuLogoImage() -> NSImage? {
    let name = menuLogoUsesDark() ? "MenuLogo-Dark" : "MenuLogo-Light"
    if let p = Bundle.main.path(forResource: name, ofType: "png"), let img = NSImage(contentsOfFile: p) {
        return img
    }
    // 兜底：<可执行文件>/../../Resources/<name>.png（直接跑二进制时 Bundle 可能拿不到资源）
    let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "")
    let p = exe.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/\(name).png").path
    return NSImage(contentsOfFile: p)
}

// 头图专用字体：13pt 等宽（值文本用它；图标单独放大，见 MenuHeaderView.iconFont）
let headerFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
let headerFontB = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)   // 产品标题加粗档（同字宽，栅格不受影响）
func headerMonoWidth(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: [.font: headerFont]).width }

/// 头图栅格里的一行：可选 emoji 图标 + 带颜色的值段
struct HeaderRow {
    let icon: String?                       // 该行图标；nil = 本行无图标（值缩进到值列）
    let segs: [(String, NSColor)]
}
/// 头图栅格里的一张卡：若干行（每行可带自己的图标，用于「风扇+功率」合并一格）
struct HeaderCard {
    let rows: [HeaderRow]
}

/// 围栏计时器：一条 2px 圆角细线，从左到右填——可视化「距下次 5s 数据刷新还差多久」。
/// 满格 = refresh 触发 = 归零重来。比例由 App 用 `lastRefreshAt` 派生（与主 Timer 同源），本视图只负责画。
final class FenceProgressView: NSView {
    static let barWidth: CGFloat = 128
    static let barHeight: CGFloat = 2
    /// 草场绿：牧场/草原感，比 status 用的 systemGreen 更沉稳、不抢「正常/下降」语义。
    /// 想换「干草」土黄：NSColor(srgbRed: 0.78, green: 0.62, blue: 0.30, alpha: 1)。
    static let pastureGreen = NSColor(srgbRed: 0.36, green: 0.70, blue: 0.39, alpha: 1)

    var progress: CGFloat = 0 { didSet { if progress != oldValue { needsDisplay = true } } }
    var barColor: NSColor = FenceProgressView.pastureGreen { didSet { needsDisplay = true } }
    var trackColor: NSColor = .separatorColor { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let r = bounds
        guard r.width > 0, r.height > 0 else { return }

        // 轨道：整段圆角细线（护栏）
        let track = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        trackColor.setFill()
        track.fill()

        // 填充：左→右，裁剪进轨道路径，前端保持直角、两端保持圆角
        let fillW = r.width * max(0, min(1, progress))
        guard fillW > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        track.addClip()
        let fillRect = NSRect(x: r.minX, y: r.minY, width: fillW, height: r.height)
        barColor.setFill()
        fillRect.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

final class MenuHeaderView: NSView {
    static let defaultWidth: CGFloat = 460
    static let extraW: CGFloat = 60             // 内容宽之外统一放宽：条目指标串（PID+内存+CPU）要完整放下
    static let logoSize: CGFloat = 59            // 品牌牛 logo：约 70%，只是识别标识、不参与数据排版
    static let iconFont = NSFont.systemFont(ofSize: 18, weight: .regular)   // 图标基准字号（归一化前的参照）
    /// 同一字号下各 emoji 的**墨迹**天生不一样大（实测 label 管线 18pt：📡/⚡️/🕸️/🐝 21.0pt、☀️ 20.5、
    /// 🐎 20.0、🐏/🚜 19.5、🚚 18.0），同字号排版就会「网络图标显大」（2026-10-04 用户反馈）。
    /// 归一化：逐个 emoji 实测墨迹、微调字号把墨迹钉到 iconInkTarget，墨迹中心再钉回 iconInkCenter。
    /// ⚠ emoji 位图按像素格量化——字号→墨迹是 0.5pt 一阶的阶梯（实测曲线钉死），单轮线性换算
    ///   最多差一阶，所以这里做**反馈收敛**（测→调→再测，≤3 轮；🚚 这类要放大的字形两轮不够、三轮才咬住）；
    ///   结果按字串缓存，只在首建付一次（每字形 ~5ms×≤4 次测量）。
    static let iconInkTarget: CGFloat = 20
    static let iconInkCenter: CGFloat = 10.5     // 墨迹中心距行顶（pt）＝现状多数图标的中心
    private struct IconLayout { let font: NSFont; let dy: CGFloat }
    private static var iconLayoutCache: [String: IconLayout] = [:]

    /// 用与渲染**完全相同**的管线（NSTextField label + cacheDisplay）量 emoji 在指定字号下的墨迹（高、顶距）。
    /// 画进 96pt 大框：行框只有 ~21pt，📡 这类满格字形贴着边，小框会把墨迹裁短、量出假值。
    /// ⚠ 别改用 NSAttributedString.draw 直画——那条路径 emoji 缩放不同（实测小 ~3pt），量出来是错的模型。
    private static func iconInk(_ s: String, size: CGFloat) -> (h: CGFloat, top: CGFloat) {
        let attr = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: .regular)])
        let label = NSTextField(labelWithAttributedString: attr)
        label.frame = NSRect(x: 0, y: 0, width: 96, height: 96)
        guard let rep = label.bitmapImageRepForCachingDisplay(in: label.bounds) else { return (21, 0) }
        label.cacheDisplay(in: label.bounds, to: rep)
        var minY = 9999, maxY = -1
        for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
            if let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.05 {
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }}
        guard maxY >= 0 else { return (21, 0) }
        return (CGFloat(maxY - minY + 1) / 2, CGFloat(minY) / 2)   // rep 2x backing → /2 回 pt
    }

    /// 图标排版（字号 + 垂直位移）：反馈收敛到墨迹 = iconInkTarget（±最近像素阶），主线程首建时算一次。
    private static func iconLayout(_ emoji: String) -> IconLayout {
        if let c = iconLayoutCache[emoji] { return c }
        var size = iconFont.pointSize
        var m = iconInk(emoji, size: size)
        for _ in 0..<3 {
            guard abs(m.h - iconInkTarget) >= 0.4 else { break }
            size *= iconInkTarget / max(m.h, 1)
            m = iconInk(emoji, size: size)
        }
        let r = IconLayout(font: NSFont.systemFont(ofSize: size, weight: .regular),
                           dy: m.top + m.h / 2 - iconInkCenter)   // >0＝墨迹偏低，place() 把 label 上移
        iconLayoutCache[emoji] = r
        return r
    }

    static let subtitleFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)   // 「已值守」副标题（按分钟跳字）

    private var titleSegs: [(String, NSColor)]
    private var subtitleSegs: [(String, NSColor)]?
    private var warningSegs: [(String, NSColor)]?
    private var left: [HeaderCard]
    private var right: [HeaderCard]
    private let logoView = NSImageView()
    private let fenceView = FenceProgressView()

    private var titleLabel: NSTextField!
    private var warningLabel: NSTextField?
    private var subtitleLabel: NSTextField?
    private struct RowViews {
        let icon: NSTextField?
        let iconDy: CGFloat      // 图标墨迹垂直归一化位移（>0 上移，见 iconLayout）
        let label: NSTextField
    }
    private struct CardViews {
        let rows: [RowViews]
    }
    private var leftCV: [CardViews] = []
    private var rightCV: [CardViews] = []

    init(title: [(String, NSColor)],
         subtitle: [(String, NSColor)]?,
         warning: [(String, NSColor)]?,
         left: [HeaderCard],
         right: [HeaderCard],
         logo: NSImage?) {
        self.titleSegs = title
        self.subtitleSegs = subtitle
        self.warningSegs = warning
        self.left = left
        self.right = right
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 80))

        if let logo {
            logoView.wantsLayer = true        // blink 用 CAKeyframeAnimation 纵向 squash，需 layer-backed
            logoView.image = logo
            logoView.imageScaling = .scaleProportionallyUpOrDown
            let click = NSClickGestureRecognizer(target: self, action: #selector(logoClicked))
            logoView.addGestureRecognizer(click)
            addSubview(logoView)
        }
        addSubview(fenceView)

        rebuild()
    }

    /// 就地刷新头图（菜单展开时调用）：保留 logoView，重建其余子视图并重排。
    func update(title: [(String, NSColor)],
                subtitle: [(String, NSColor)]?,
                warning: [(String, NSColor)]?,
                left: [HeaderCard],
                right: [HeaderCard]) {
        self.titleSegs = title
        self.subtitleSegs = subtitle
        self.warningSegs = warning
        self.left = left
        self.right = right
        rebuild()
    }

    private func rebuild() {
        for v in subviews where v !== logoView && v !== fenceView { v.removeFromSuperview() }
        titleLabel = nil
        warningLabel = nil
        subtitleLabel = nil
        leftCV = []
        rightCV = []

        titleLabel = makeLabel(titleSegs, font: headerFontB, alignment: .center)
        if let w = warningSegs { warningLabel = makeLabel(w, font: headerFont) }
        if let s = subtitleSegs { subtitleLabel = makeLabel(s, font: MenuHeaderView.subtitleFont, alignment: .right) }

        leftCV = left.map { makeCardViews($0) }
        rightCV = right.map { makeCardViews($0) }

        applyLayout()
    }

    /// 富文本 label 注意：labelWithAttributedString 不认 l.alignment，对齐必须写进段落样式（实测：只设 l.alignment 仍贴左）。
    static func attributed(_ segs: [(String, NSColor)], font: NSFont, alignment: NSTextAlignment = .left) -> NSAttributedString {
        let a = NSMutableAttributedString()
        for (s, c) in segs {
            a.append(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: c]))
        }
        if alignment != .left {
            let p = NSMutableParagraphStyle()
            p.alignment = alignment
            a.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: a.length))
        }
        return a
    }

    private func makeLabel(_ segs: [(String, NSColor)], font: NSFont, alignment: NSTextAlignment = .left) -> NSTextField {
        let l = NSTextField(labelWithAttributedString: MenuHeaderView.attributed(segs, font: font, alignment: alignment))
        l.alignment = alignment
        l.maximumNumberOfLines = 1
        l.lineBreakMode = .byClipping
        l.drawsBackground = false
        l.isBordered = false
        l.isEditable = false
        l.isSelectable = false
        addSubview(l)
        return l
    }

    private func makeCardViews(_ card: HeaderCard) -> CardViews {
        CardViews(rows: card.rows.map { row in
            RowViews(icon: row.icon.map { makeLabel([($0, .labelColor)], font: MenuHeaderView.iconLayout($0).font) },
                     iconDy: row.icon.map { MenuHeaderView.iconLayout($0).dy } ?? 0,
                     label: makeLabel(row.segs, font: headerFont))
        })
    }

    @objc private func logoClicked() {
        playMooSound()
    }

    /// 围栏线进度（0…1）：App 的 5s 倒数把它从 0 推到 1；到 1 的瞬间 refresh 归零。
    func setFenceProgress(_ p: CGFloat) {
        fenceView.progress = max(0, min(1, p))
    }

    /// 就地刷新「已值守」文案（每分钟跳一次）：只改副标题文字，不重建其余子视图、也不动围栏线。
    func setUptime(_ segs: [(String, NSColor)]) {
        subtitleSegs = segs
        guard let sl = subtitleLabel else { return }
        sl.attributedStringValue = MenuHeaderView.attributed(segs, font: MenuHeaderView.subtitleFont, alignment: .right)
    }

    /// 就地切换 logo 明暗图（系统外观变化时、随 5s 刷新换图，不重建菜单）
    func setLogo(_ image: NSImage?) {
        if image != nil && logoView.gestureRecognizers.isEmpty {
            logoView.wantsLayer = true
            logoView.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(logoClicked)))
        }
        logoView.image = image
        logoView.imageScaling = .scaleProportionallyUpOrDown
    }

    /// 小牛眨眼：refresh 归零的瞬间，logo 纵向快速一压——一眼即「眨眼」，不换图、不新增资源。
    func blink() {
        guard logoView.image != nil, let layer = logoView.layer else { return }
        let a = CAKeyframeAnimation(keyPath: "transform.scale.y")
        a.values = [1.0, 0.82, 1.0, 0.92, 1.0]           // 闭-开-微闭-开，一次眨眼
        a.keyTimes = [0, 0.35, 0.6, 0.8, 1.0]
        a.duration = 0.16
        a.timingFunctions = [
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
        ]
        a.isRemovedOnCompletion = true
        layer.add(a, forKey: "blink")
    }

    /// 自洽排布：视图宽度 = 内容自然宽 + 右侧 logo 列（不依赖 menu.size.width，那是菜单测量值、不可靠）。
    /// 标题水平居中；logo 独占右侧一列、垂直居中，横向与内容隔开，绝不压住 CPU/GPU。
    func applyLayout() {
        let padX: CGFloat = 12
        let padTop: CGFloat = 12
        let padBottom: CGFloat = 12
        let iconW: CGFloat = 34          // 图标列预留宽（18pt emoji ≈ 26px，余下作图标与值的间距）
        let colGap: CGFloat = 36         // 左右两列间距
        let rowGap: CGFloat = 14         // 卡组之间纵距
        let titleGap: CGFloat = 10       // 标题 → 栅格间距
        let logoGap: CGFloat = 20        // logo 与内容列之间的横向间距（标签 fittingSize 比等宽测宽多几像素，预留足）
        let lineH = max(ceil(("Ag" as NSString).size(withAttributes: [.font: headerFont]).height), 16)

        func cardValueW(_ card: HeaderCard) -> CGFloat {
            card.rows.map { r in r.segs.reduce(0) { $0 + headerMonoWidth($1.0) } }.max() ?? 0
        }
        let col0W = left.map(cardValueW).max() ?? 0
        let col1W = right.map(cardValueW).max() ?? 0

        // 视图宽 = 内容自然宽 + 右侧 logo 列（logo + 间距）；上限 620 防异常数据撑爆。
        // 内容宽之外再放宽 60px（2026-10-03 拍板）：条目行「PID+内存+CPU」指标串要完整放下，
        // 右缘纪律线相应挪到 Trunc.menuRightPx（=540−30）
        let contentInnerW = iconW + col0W + colGap + iconW + col1W
        let logoReserve = logoView.image == nil ? 0 : (MenuHeaderView.logoSize + logoGap)
        let width = min(ceil(padX * 2 + contentInnerW + logoReserve) + MenuHeaderView.extraW, 620)

        let rowCount = max(left.count, right.count)
        var rowHeights: [CGFloat] = []
        for i in 0..<rowCount {
            let lc = i < left.count ? left[i].rows.count : 0
            let rc = i < right.count ? right[i].rows.count : 0
            rowHeights.append(CGFloat(max(lc, rc)) * lineH)
        }
        let gridH = rowHeights.reduce(0, +) + CGFloat(max(0, rowCount - 1)) * rowGap

        var yTopDown = padTop
        if warningLabel != nil { yTopDown += lineH + 4 }
        yTopDown += lineH + titleGap
        let totalH = yTopDown + gridH + padBottom
        let h = max(totalH, MenuHeaderView.logoSize + padTop + padBottom)
        frame.size = NSSize(width: width, height: h)

        // 顶部：warning / 标题（水平居中于全宽）
        yTopDown = padTop
        if let wl = warningLabel {
            wl.frame = NSRect(x: padX, y: h - yTopDown - lineH, width: width - padX * 2, height: lineH)
            yTopDown += lineH + 4
        }
        titleLabel.frame = NSRect(x: padX, y: h - yTopDown - lineH, width: width - padX * 2, height: lineH)
        if let sl = subtitleLabel {
            // 副标题与标题同行：占同一行、右对齐（标题仍居中于全宽）
            sl.frame = NSRect(x: padX, y: h - yTopDown - lineH, width: width - padX * 2, height: lineH)
        }
        // 围栏计时器：右对齐、落在「已值守」与 logo 之间的标题行正下方（满格 = 下次刷新）
        let fenceSubGap: CGFloat = 5
        fenceView.frame = NSRect(x: width - padX - FenceProgressView.barWidth,
                                 y: h - (yTopDown + lineH) - fenceSubGap - FenceProgressView.barHeight,
                                 width: FenceProgressView.barWidth,
                                 height: FenceProgressView.barHeight)
        yTopDown += lineH + titleGap

        // logo：右侧独占一列、垂直居中，横向与内容隔开 logoGap
        if logoView.image != nil {
            logoView.frame = NSRect(x: width - padX - MenuHeaderView.logoSize,
                                    y: (h - MenuHeaderView.logoSize) / 2,
                                    width: MenuHeaderView.logoSize, height: MenuHeaderView.logoSize)
        }

        // 栅格：逐行放置左右卡。每行可自带图标；标签宽度用 fittingSize（含 cell 内边距），避免末端单位/数值被裁。
        func place(_ cv: CardViews, x: CGFloat, top: CGFloat) {
            for (j, rv) in cv.rows.enumerated() {
                let rowTop = top + CGFloat(j) * lineH
                if let ic = rv.icon {
                    let fit = ic.fittingSize
                    // +iconDy：墨迹中心钉回 iconInkCenter（归一化字号后各字形在行框里的起始高度不同）
                    ic.frame = NSRect(x: x, y: h - rowTop - ceil(fit.height) + rv.iconDy, width: ceil(fit.width) + 4, height: ceil(fit.height))
                }
                let fit = rv.label.fittingSize
                let lh = ceil(fit.height)
                rv.label.frame = NSRect(x: x + iconW, y: h - rowTop - lh, width: ceil(fit.width) + 2, height: lh)
            }
        }

        let col0X = padX
        let col1X = padX + iconW + col0W + colGap
        var rowTop = yTopDown
        for i in 0..<rowCount {
            if i < leftCV.count { place(leftCV[i], x: col0X, top: rowTop) }
            if i < rightCV.count { place(rightCV[i], x: col1X, top: rowTop) }
            rowTop += rowHeights[i] + rowGap
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}