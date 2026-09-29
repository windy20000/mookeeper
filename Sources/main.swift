import AppKit

// --moo：试听品牌提示音（诊断用：确认 moo.aiff 能被找到并出声）
if CommandLine.arguments.contains("--moo") {
    if playMooSound() {
        print("moo: playing \(mooSoundURL()?.path ?? "?")")
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))  // 留够播放时间
    } else {
        print(moo("moo: 找不到 moo.aiff（bundle 资源缺失，会回落系统默认声）",
                  "moo: moo.aiff not found (bundle resource missing; falls back to system default sound)"))
    }
    exit(0)
}

// --gen <命令>：诊断「粘贴命令→生成条目」的解析结果
if let idx = CommandLine.arguments.firstIndex(of: "--gen") {
    let cmd = CommandLine.arguments.dropFirst(idx + 1).joined(separator: " ")
    if let d = makeItemDraft(fromCommand: cmd) {
        print("key=\(d.key) label=\(d.label) probe=\(d.probe) port=\(d.port) process=\(d.process) start=\(d.start) stop=\(d.stop)")
    } else {
        print(moo("无法识别", "Unrecognized"))
    }
    exit(0)
}

// MooKeeper 原生版 · 入口（其余逻辑已按模块拆分到 Sources/*.swift）
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// --menu-shot <png> [light|dark]：出图前强制明暗外观（GitHub README 需要明/暗两版；
// 必须在 widget.start()/refresh() 之前设——菜单头图 logo 的明暗变体在建菜单时就按
// effectiveAppearance 选好了，晚设会图文两版打架）
if let msi = CommandLine.arguments.firstIndex(of: "--menu-shot"), msi + 2 < CommandLine.arguments.count {
    switch CommandLine.arguments[msi + 2] {
    case "light": NSApp.appearance = NSAppearance(named: .aqua)
    case "dark":  NSApp.appearance = NSAppearance(named: .darkAqua)
    default: break   // 不识别的值＝跟随系统（原行为）
    }
}
let widget = App()
widget.start()

if CommandLine.arguments.contains("--notif") { dumpNotifState(); exit(0) }

// --netkind [接口名]：打印网络卡头图 icon 的判型结果（📡 Wi-Fi / ⚡️ 雷雳 / 🕸️ 有线 / 🚚 未知）。
// 带接口名则强制判该接口（如 --netkind en6 验雷雳、--netkind utun1 验未知兜底），免拔线覆盖各分支；
// 不带则走真实路径（每拍直读，无缓存），并附 20× 均耗时——refresh 每拍的实际成本就按这个口径看。
if let idx = CommandLine.arguments.firstIndex(of: "--netkind") {
    let next = idx + 1 < CommandLine.arguments.count ? CommandLine.arguments[idx + 1] : ""
    let forced = !next.isEmpty && !next.hasPrefix("--") ? next : nil
    if let n = forced {
        let k = netEgressClassify(name: n)
        print("netkind: forced \(n) → \(k.icon) \(k.label)")
    } else {
        let r = netEgressKind()
        print("netkind: primary=\(r.iface.isEmpty ? "<no egress>" : r.iface) → \(r.kind.icon) \(r.kind.label)")
        let t0 = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<20 { _ = netEgressKind() }
        let us = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000.0 / 20.0   // ns→µs
        print(moo("netkind: 每拍直读 ≈\(String(format: "%.1f", us))µs（20× 均值，含 Store 读 + IOKit 定向匹配）",
                  "netkind: per-tick direct read ≈\(String(format: "%.1f", us))µs (20× avg, Store read + IOKit targeted match)"))
    }
    exit(0)
}

// 普通模式：先刷一次再判是否导出
widget.refresh()
let dumpLater = CommandLine.arguments.contains("--dump-later")

if CommandLine.arguments.contains("--dump") || dumpLater {
    if dumpLater {
        // 冷启动那一拍 check 条目走 async 回填（坑：probeCache 空→先显示未运行），
        // 排水主队列约 10s 再 dump，看回填后的稳定态（pgrep 类 check ≪6s）
        RunLoop.current.run(until: Date().addingTimeInterval(10))
        widget.refresh()
    }
    for mi in widget.menu.items {
        if mi.view is RefreshRowView { print(moo("| 刷新 ⌘R（自绘行：点击不收菜单）", "| Refresh ⌘R (self-drawn row: click keeps menu open)")); continue }
        if mi.view is ErrorNoteRowView { print(moo("| ⚠ 上次动作失败（自绘行：整行可点关闭）", "| ⚠ Last action failed (self-drawn row: click anywhere to dismiss)")); continue }
        print("| \(mi.attributedTitle?.string ?? mi.title)")
    }
    exit(0)
}

// --menu-geo：程序化弹出真菜单并量真实几何。
// ⚠ 2026-10-04 订正：跟踪期 **DispatchQueue.main.async 的 block 不排水**，下面那个「后台线程 sleep → hop
// 主队列」只会在菜单自己关掉之后才跑到（早期注释写的「跟踪期实测活」是误判——非激活 App 的菜单弹起约 2s
// 就自己关了，hop 其实是在关掉之后跑的）。真·跟踪期几何看 MOO_MENU_GEO=1 的 willOpen 那条（menuWillOpen
// 同步触发，不依赖任何定时器）。
if CommandLine.arguments.contains("--menu-geo") {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
        DispatchQueue.global().async {
            Thread.sleep(forTimeInterval: 1.6)   // 等 popUp 进入跟踪
            DispatchQueue.main.async {
                for w in NSApp.windows {
                    let cls = String(describing: type(of: w))
                    guard cls.lowercased().contains("menu") else { continue }
                    fputs("menu-geo: WINDOW \(cls) frame=\(w.frame)\n", stderr)
                }
                let rows = widget.menu.items.compactMap { mi -> String? in
                    guard let v = mi.view else { return nil }
                    let tag = v is MenuHeaderView ? "header" : (v is GroupHeaderView ? "group" : (v is RefreshRowView ? "refresh" : (v is ErrorNoteRowView ? "errnote" : "view")))
                    return "\(tag)=\(Int(v.frame.width))"
                }.joined(separator: " ")
                fputs("menu-geo: rows \(rows)\n", stderr)
                exit(0)
            }
        }
        widget.menu.popUp(positioning: nil, at: NSPoint(x: 2, y: 2), in: widget.item.button)   // 同步跟踪，直到 exit(0)
    }
}

// --menu-keytest <r|,|click|bulk|openrefresh>：诊断「菜单展开（跟踪）期的触发」。
//   r   = 投一条合成 ⌘R 进应用事件队列（⚠ 合成键会被菜单跟踪循环吞掉，故 r 只作脚手架；
//         真 ⌘R 由 App.installKeyMonitor 的本地事件监视器接，需人工按一下就知）
//   ,   = 对照组：普通条目（配置…）的 ⌘, 合成键能触发 → 证明投递机制本身有效
//   click = 直接给 RefreshRowView 发 mouseDown，核「刷新后 5s 计时器是否重置」（fireIn≈5）
//   bulk  = 给分组头的「▶ 全部启动」按钮发 performBulkClick（与真实点击同一条回调），
//           核「点完菜单收起 + 后台照跑」
//           （跑的是配置里的真命令，务必配 MOOKEEPER_CONFIG 指向无害的临时配置，如 start: /usr/bin/true）
//   openrefresh = 验 d.md §33：连开三次菜单——①收起时清掉悬停残留；②0.5s 内重开走节流不重建；
//                 ③超过 0.5s 重开必须在**打开前**由 menuNeedsUpdate 重建（此时 5s Timer 那拍被
//                 每次 refresh 重置还没到，实例变化只能来自 menuNeedsUpdate）。
//                 同样务必配无害临时配置。
// ⚠ 跟踪期**只有 NSEventTrackingRunLoopMode（.eventTracking）里的定时器会排水**：
//   DispatchQueue.main.async 的 block 要等菜单关掉才排到（2026-10-04 实测；早期这里写的「后台线程
//   sleep→hop 主队列」其实是等菜单自己关掉才跑，等于没测到跟踪期）。所以统一用 eventTracking 定时器，
//   并且先 activate——非激活 App 的菜单弹起约 2s 会自己关掉，根本留不住跟踪态。
if let idx = CommandLine.arguments.firstIndex(of: "--menu-keytest") {
    let mode = (idx + 1 < CommandLine.arguments.count) ? CommandLine.arguments[idx + 1] : "r"
    let fireIn = { widget.refreshTimer?.fireDate.timeIntervalSinceNow ?? -1 }
    // 跟踪期 + 跟踪结束都能跑：两个模式各挂一份，谁先到谁跑（收菜单后 eventTracking 那份就废了）
    func once(_ delay: TimeInterval, _ body: @escaping () -> Void) {
        var done = false
        let fire = { if !done { done = true; body() } }
        for m in [RunLoop.Mode.eventTracking, .default] {
            let t = Timer(timeInterval: delay, repeats: false) { _ in fire() }
            RunLoop.main.add(t, forMode: m)
        }
    }
    // openrefresh（d.md §33）：三段连续开关，验证「A 悬停残留清除」+「B menuNeedsUpdate 节流 rebuild」。
    if mode == "openrefresh" {
        func ids() -> [Int] { widget.menu.items.compactMap { $0.view as? GroupHeaderView }
            .map { ObjectIdentifier($0).hashValue } }
        func hovers() -> Int { widget.menu.items.compactMap { $0.view as? GroupHeaderView }
            .flatMap { $0.buttons }.filter { $0.hovered }.count }
        func touch() { widget.menu.items.compactMap { $0.view as? GroupHeaderView }
            .flatMap { $0.buttons }.forEach { $0.hovered = true } }
        // popUp 会同步跑完整个跟踪循环；during/cancel 两个 eventTracking 定时器在它内部排水（坑 17）
        func stage(_ tag: String, during: TimeInterval, hold: TimeInterval, _ body: @escaping () -> Void) {
            once(during) { body() }
            once(hold) { widget.menu.cancelTracking() }
            widget.menu.popUp(positioning: nil, at: NSPoint(x: 2, y: 2), in: widget.item.button)
        }
        let sinceLast = { widget.lastRefreshAt.map { Date().timeIntervalSince($0) } ?? 99.0 }
        func btnCount() -> Int { widget.menu.items.compactMap { $0.view as? GroupHeaderView }
            .flatMap { $0.buttons }.count }
        var ids0: [Int] = [], aClearOnClose = false, skipOk = false, rebuilt = false
        var sinceAt2 = -1.0, sinceAt3 = -1.0, fireInL = -1.0
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            NSApp.activate(ignoringOtherApps: true)
            // #1：记录实例、跟踪期点亮悬停（模拟 mouseEntered）→ 程序收起（与批量按钮同一条路）。
            // 整段压到 0.25+0.05 内：#2 才能落进 0.5s 节流窗口（上一版开 0.53s 才重开，直接越窗，
            // 看起来像「没跳过」，其实是计时没踩中）
            stage("#1", during: 0.2, hold: 0.25) { ids0 = ids(); touch() }
            aClearOnClose = hovers() == 0 && btnCount() > 0
            fputs(moo("openrefresh: #1 收起后 hover=\(hovers())/按钮\(btnCount())（\(aClearOnClose ? "didClose 已清" : "仍有残留或无按钮")）实例=\(ids0.count)组 距上次刷新\(String(format: "%.2f", sinceLast()))s\n",
                      "openrefresh: #1 after close hover=\(hovers())/buttons=\(btnCount()) (\(aClearOnClose ? "cleared by didClose" : "stale or no buttons")) instances=\(ids0.count) since-last-refresh=\(String(format: "%.2f", sinceLast()))s\n"), stderr)

            // #2：距 T0 <0.5s 重开 → menuNeedsUpdate 应跳过 rebuild（复用旧实例）
            stage("#2", during: 0.15, hold: 0.25) {
                skipOk = ids() == ids0
                sinceAt2 = sinceLast()
                fputs(moo("openrefresh: #2(<0.5s内重开) 复用旧实例=\(skipOk) hover=\(hovers()) 距上次刷新\(String(format: "%.2f", sinceAt2))s\n",
                          "openrefresh: #2 (reopened <0.5s) reused old views=\(skipOk) hover=\(hovers()) since-last-refresh=\(String(format: "%.2f", sinceAt2))s\n"), stderr)
            }
            // #3：先 asyncAfter 把时间推出节流窗口（>0.5s、且仍 <5s Timer），重开必须在**打开前**重建
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                stage("#3", during: 0.15, hold: 0.25) {
                    rebuilt = !ids().isEmpty && ids() != ids0
                    sinceAt3 = sinceLast()
                    fireInL = widget.refreshTimer?.fireDate.timeIntervalSinceNow ?? -1
                    fputs(moo("openrefresh: #3(>0.5s重开) 实例已重建=\(rebuilt) 距上次刷新\(String(format: "%.2f", sinceAt3))s 5s计时器还剩\(String(format: "%.2f", fireInL))s\n",
                              "openrefresh: #3 (reopened >0.5s) rebuilt=\(rebuilt) since-last-refresh=\(String(format: "%.2f", sinceAt3))s 5s timer remaining=\(String(format: "%.2f", fireInL))s\n"), stderr)
                }
                // rebuild 的直接证据是「打开瞬间刚刷过」（#1/#2 那拍距刷新都 >0.4s，#3 ≈0）；
                // ObjectIdentifier 只当旁证——removeAllItems 后旧 view 释放，新 view 可能复用同一地址
                let okA = aClearOnClose && !ids0.isEmpty && hovers() == 0
                let okB = skipOk && sinceAt2 > 0.3 && sinceAt3 < 0.3 && fireInL > 3
                fputs(moo("openrefresh: 结论 A(收起清悬停残留, didClose+willOpen)=\(okA ? "PASS" : "FAIL") B(<0.5s跳过#2 距刷\(String(format: "%.2f", sinceAt2))s + >0.5s即时rebuild#3 距刷\(String(format: "%.2f", sinceAt3))s)=\(okB ? "PASS" : "FAIL")\n",
                          "openrefresh: verdict A(stale hover cleared on close, didClose+willOpen)=\(okA ? "PASS" : "FAIL") B(<0.5s skipped #2 at \(String(format: "%.2f", sinceAt2))s + >0.5s rebuild-before-open #3 at \(String(format: "%.2f", sinceAt3))s)=\(okB ? "PASS" : "FAIL")\n"), stderr)
                exit(okA && okB ? 0 : 1)
            }
        }
    } else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            NSApp.activate(ignoringOtherApps: true)
            once(2.0) {
                fputs(moo("menu-keytest: 跟踪中 menuOpen=\(widget.menuOpen) active=\(NSApp.isActive)\n",
                          "menu-keytest: during tracking menuOpen=\(widget.menuOpen) active=\(NSApp.isActive)\n"), stderr)
                if mode == "click" {
                    fputs("menu-keytest: before-click fireIn=\(String(format: "%.2f", fireIn()))\n", stderr)
                if let row = widget.menu.items.first(where: { $0.view is RefreshRowView })?.view as? RefreshRowView,
                   let ev = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    row.mouseDown(with: ev)
                }
                fputs("menu-keytest: after-click fireIn=\(String(format: "%.2f", fireIn())) userRefreshAt=\(widget.lastUserRefreshAt != nil)\n", stderr)
            } else if mode == "bulk" {
                // 核「点分组按钮 → 菜单收起，且批量照跑」：拿真按钮走真回调（自绘视图，非 NSButton）。
                // 只验证 action 的副作用（cancelTracking/后台排队），不验证鼠标路由（那条路本来就走得通）。
                let btns = widget.menu.items.compactMap { $0.view as? GroupHeaderView }.flatMap { $0.buttons }
                let names = btns.map { "\($0.title)\($0.isStart ? "(start)" : "(stop)")" }.joined(separator: " ")
                fputs("menu-keytest: bulk buttons=[\(names)]\n", stderr)
                if let b = btns.first(where: { $0.isStart }) {
                    b.performBulkClick()   // 自绘按钮：走与真实点击同一条回调
                    fputs("menu-keytest: clicked \"\(b.title)\" busy=[\(widget.busy.keys.sorted().joined(separator: ","))]\n", stderr)
                } else {
                    fputs(moo("menu-keytest: 没有可点的「全部启动」按钮（组内没空闲条目/没配 allowStartAll）\n",
                              "menu-keytest: no clickable \"Start All\" button (no idle items / allowStartAll off)\n"), stderr)
                }
            } else if let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                                context: nil, characters: mode, charactersIgnoringModifiers: mode,
                                                isARepeat: false, keyCode: 0) {
                NSApp.postEvent(ev, atStart: true)
                fputs("menu-keytest: posted key=\(mode)\n", stderr)
            }
        }
        once(3.2) {
            if mode == "," {
                fputs("menu-keytest: key=, fired=\(widget.settingsWC != nil)\n", stderr)
            } else if mode == "bulk" {
                // 核心断言：菜单已收起（menuOpen=false ⇒ menuDidClose 跑过）且批量已跑完（busy 清空）。
                // 对照组（去掉 cancelTracking）里这两项会一直是 true / 非空——菜单不收，批量的收尾
                // 也卡在主队列上排不到，直到人工关菜单。
                fputs(moo("menu-keytest: after menuOpen=\(widget.menuOpen) busy=[\(widget.busy.keys.sorted().joined(separator: ","))]（空=整批已跑完）\n",
                          "menu-keytest: after menuOpen=\(widget.menuOpen) busy=[\(widget.busy.keys.sorted().joined(separator: ","))] (empty = batch finished)\n"), stderr)
            } else if mode != "click" {
                fputs("menu-keytest: key=\(mode) firedBySyntheticKey=\(widget.lastUserRefreshAt != nil)\n", stderr)
            }
            exit(0)
        }
        widget.menu.popUp(positioning: nil, at: NSPoint(x: 2, y: 2), in: widget.item.button)   // 同步跟踪，直到 exit(0)
    }
    }
}

// --errtest：验「⚠ 上次动作失败」自绘行的完整生命周期（断言失败原因可区分，exit 码非 0 即 FAIL）：
//   A1 新失败（0s）→ 行在位；A2 过期（TTL+1s）→ 行消失；A3 边界（TTL−5s）→ 行仍在（防比较符写反）；
//   B  弹真菜单 → 给行发 mouseDown（与 --menu-keytest click 同款合成，走真回调）→ 核「菜单收起 +
//      lastError 已清 + 重建成品里行消失」；
//   PNG：明/暗 × 常态/悬停 四张离屏渲染（err-light.png / err-dark.png / err-*-hover.png），
//      肉眼核对浅色底上正文可读性（--dump 看不到自绘视图，颜色必须出图）。
// ⚠ 跟踪期只有 .eventTracking 定时器排水（坑 17），沿用 once() 双模式挂载 + popUp 前 activate。
if CommandLine.arguments.contains("--errtest") {
    func errRow() -> ErrorNoteRowView? { widget.menu.items.first { $0.view is ErrorNoteRowView }?.view as? ErrorNoteRowView }
    func once(_ delay: TimeInterval, _ body: @escaping () -> Void) {
        var done = false
        let fire = { if !done { done = true; body() } }
        for m in [RunLoop.Mode.eventTracking, .default] {
            let t = Timer(timeInterval: delay, repeats: false) { _ in fire() }
            RunLoop.main.add(t, forMode: m)
        }
    }
    func shot(_ v: NSView, _ path: String) {
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { fputs(moo("errtest: \(path) 出图失败 no rep\n", "errtest: \(path) render failed — no rep\n"), stderr); return }
        v.cacheDisplay(in: v.bounds, to: rep)
        // 垫一层菜单底色再合成导出：视图本身透明，不垫的话深色模式白字落在查看器白底上＝「看不见字」假象。
        // ⚠ 用 --menu-shot 同款显式 NSGraphicsContext 路子，别用 NSImage.lockFocus——裸二进制无窗口时
        // lockFocus 的绘制不落进位图（实测像素 alpha=0，底色整层丢失）
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(v.bounds.width), pixelsHigh: Int(v.bounds.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: out) else { fputs(moo("errtest: \(path) 出图失败 no ctx\n", "errtest: \(path) render failed — no ctx\n"), stderr); return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        v.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(rect: NSRect(origin: .zero, size: v.bounds.size)).fill()
            // ⚠ 必须显式 .sourceOver：cacheDisplay 出来的位图 rep 用裸 draw(in:) 会把目标区**整块替换**
            // （探针实测：底色 fill 后像素不透明，rep.draw 后又全透明）——透明像素连底色一起擦光。
            // 早期两次归因（NSImage.lockFocus、NSRect.fill）都被这个真凶掩盖，d.md §39 有案底。
            rep.draw(in: NSRect(origin: .zero, size: v.bounds.size), from: .zero,
                     operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = out.representation(using: .png, properties: [:]) else { fputs(moo("errtest: \(path) 出图失败 no png\n", "errtest: \(path) render failed — no png\n"), stderr); return }
        do { try data.write(to: URL(fileURLWithPath: path)); fputs(moo("errtest: 已写 \(path)（\(Int(v.bounds.width))x\(Int(v.bounds.height))）\n", "errtest: wrote \(path) (\(Int(v.bounds.width))x\(Int(v.bounds.height)))\n"), stderr) }
        catch { fputs(moo("errtest: \(path) 写入失败 \(error)\n", "errtest: \(path) write failed \(error)\n"), stderr) }
    }
    var okFresh = false, okExpired = false, okNear = false, okCleared = false, okClosed = false, okGone = false
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
        // A1：刚失败 → 行必须在
        widget.lastError = (Date(), moo("示例失败：命令已执行但进程仍在（返回码 1）",
                                        "sample failure: command ran but the process is still there (rc 1)"))
        widget.refresh()
        okFresh = errRow() != nil
        fputs(moo("errtest: A1 新失败(0s) 行在位=\(okFresh)\(okFresh ? "" : " ← lastError 已设却没画出行＝渲染条件断")\n",
                  "errtest: A1 fresh error (0s) row present=\(okFresh)\(okFresh ? "" : " ← lastError set but no row = render condition broken")\n"), stderr)
        // A2：TTL+1s → 行必须没（旧版这里是 300s 窗口，现在收进 Hardwired.lastErrorTTL）
        widget.lastError = (Date().addingTimeInterval(-Hardwired.lastErrorTTL - 1), moo("过期样本", "expired sample"))
        widget.refresh()
        okExpired = errRow() == nil
        fputs(moo("errtest: A2 过期(\(Int(Hardwired.lastErrorTTL) + 1)s) 行消失=\(okExpired)\(okExpired ? "" : " ← TTL 比较失效")\n",
                  "errtest: A2 expired (\(Int(Hardwired.lastErrorTTL) + 1)s) row gone=\(okExpired)\(okExpired ? "" : " ← TTL comparison broken")\n"), stderr)
        // A3：TTL−5s → 仍在（防把窗口写成 12s 之类的小数字）
        widget.lastError = (Date().addingTimeInterval(-(Hardwired.lastErrorTTL - 5)), moo("边界样本", "boundary sample"))
        widget.refresh()
        okNear = errRow() != nil
        fputs(moo("errtest: A3 边界(TTL−5s) 行在位=\(okNear)\n",
                  "errtest: A3 boundary (TTL−5s) row present=\(okNear)\n"), stderr)
        // PNG 四张（明暗 × 常态/悬停）
        widget.lastError = (Date(), moo("示例失败：命令已执行但进程仍在（返回码 1）",
                                       "sample failure: command ran but the process is still there (rc 1)"))
        widget.refresh()
        if let r = errRow() {
            r.stretch(to: 680)
            for (tag, ap) in [("light", NSAppearance(named: .aqua)), ("dark", NSAppearance(named: .darkAqua))] {
                r.appearance = ap
                r.hovered = false; shot(r, "err-\(tag).png")
                r.hovered = true;  shot(r, "err-\(tag)-hover.png")
                r.hovered = false
            }
        } else {
            fputs(moo("errtest: PNG 跳过——行不在位\n", "errtest: PNG skipped — row not present\n"), stderr)
        }
        // B：弹真菜单，跟踪期给行发 mouseDown（真回调），核点击收尾三件事
        NSApp.activate(ignoringOtherApps: true)
        once(1.6) {
            guard let r = errRow(),
                  let ev = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                              context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
                fputs(moo("errtest: B 跳过——跟踪期没找到行\n", "errtest: B skipped — row not found during tracking\n"), stderr); return
            }
            r.mouseDown(with: ev)
        }
        once(3.0) {
            okCleared = widget.lastError == nil
            okClosed = !widget.menuOpen
            okGone = errRow() == nil
            let ok = okFresh && okExpired && okNear && okCleared && okClosed && okGone
            fputs(moo("errtest: B 点行后 lastError已清=\(okCleared) 菜单已收=\(okClosed) 行已消失=\(okGone)\n",
                      "errtest: B after click: cleared=\(okCleared) menu closed=\(okClosed) row gone=\(okGone)\n"), stderr)
            fputs(moo("errtest: 结论 A1在=\(okFresh) A2没=\(okExpired) A3在=\(okNear) B[清=\(okCleared) 收=\(okClosed) 没=\(okGone)] → \(ok ? "PASS" : "FAIL")\n",
                      "errtest: verdict A1=\(okFresh) A2=\(okExpired) A3=\(okNear) B[cleared=\(okCleared) closed=\(okClosed) gone=\(okGone)] → \(ok ? "PASS" : "FAIL")\n"), stderr)
            exit(ok ? 0 : 1)
        }
        widget.menu.popUp(positioning: nil, at: NSPoint(x: 2, y: 2), in: widget.item.button)   // 同步跟踪，直到 exit
    }
}

requestNotifications()

if CommandLine.arguments.contains("--settings") {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { widget.openSettings() }
}

// --test-notify：走一遍真实「系统通知 + 品牌音」链路（须用 open --args 以 bundle 身份启动；
// 裸二进制无 bundleID，会走 osascript 回落路径，测不到 UN 这条路）
if CommandLine.arguments.contains("--test-notify") {
    print("test-notify: systemSoundAvailable=\(systemSoundAvailable()) resolved=\(mooSoundURL()?.path ?? "<nil>")")
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        notify(moo("🐮 哞～ 试音通知", "🐮 Moo~ Sound-check notification"),
               moo("听到「哞」而不是「叮咚」就对了。", "If you hear \"moo\" instead of \"ding\", it works."), sound: true)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { exit(0) }
}

if CommandLine.arguments.contains("--about") {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { widget.openAbout() }
}

// --about-shot <png>：把「关于」窗口内容离屏渲染成 PNG（验证用；screencapture 无录屏权限时不可用）
if let idx = CommandLine.arguments.firstIndex(of: "--about-shot") {
    let path = (idx + 1 < CommandLine.arguments.count) ? CommandLine.arguments[idx + 1] : "about-shot.png"
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        widget.openAbout()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            defer { NSApp.terminate(nil) }
            guard let cv = widget.aboutWC?.window?.contentView else { print("about-shot: no window"); return }
            cv.layoutSubtreeIfNeeded()
            guard let rep = cv.bitmapImageRepForCachingDisplay(in: cv.bounds) else { print("about-shot: no rep"); return }
            cv.cacheDisplay(in: cv.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { print("about-shot: no png"); return }
            do { try data.write(to: URL(fileURLWithPath: path)); print("about-shot: \(path) bounds=\(cv.bounds.size)") }
            catch { print("about-shot: write failed \(error)") }
        }
    }
}

// --settings-shot <png> [--zoom <f>]：把配置窗口内容离屏渲染成 PNG（验证用；screencapture 无录屏权限时不可用）
if let idx = CommandLine.arguments.firstIndex(of: "--settings-shot") {
    let path = (idx + 1 < CommandLine.arguments.count) ? CommandLine.arguments[idx + 1] : "settings-shot.png"
    let zoomIdx = CommandLine.arguments.firstIndex(of: "--zoom")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        widget.openSettings()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            defer { NSApp.terminate(nil) }
            if let zi = zoomIdx, zi + 1 < CommandLine.arguments.count, let z = Double(CommandLine.arguments[zi + 1]) {
                widget.settingsWC?.debugSetZoom(z)   // 诊断：验证缩放渲染
            }
            guard let cv = widget.settingsWC?.windowForShot?.contentView else { print("settings-shot: no window"); return }
            print("settings-shot: zoom=\(widget.settingsWC?.debugZoom ?? -1)")
            cv.layoutSubtreeIfNeeded()
            guard let rep = cv.bitmapImageRepForCachingDisplay(in: cv.bounds) else { print("settings-shot: no rep"); return }
            cv.cacheDisplay(in: cv.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { print("settings-shot: no png"); return }
            do { try data.write(to: URL(fileURLWithPath: path)); print("settings-shot: \(path) bounds=\(cv.bounds.size)") }
            catch { print("settings-shot: write failed \(error)") }
        }
    }
}

// --header-shot <png>：把菜单头图（内存/SWAP/计算卡栅格）离屏渲染成 PNG（验证用；--dump 看不到自绘 NSView）
if let idx = CommandLine.arguments.firstIndex(of: "--header-shot") {
    let path = (idx + 1 < CommandLine.arguments.count) ? CommandLine.arguments[idx + 1] : "header-shot.png"
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        defer { NSApp.terminate(nil) }
        guard let hv = widget.headerView else { print("header-shot: no header view"); return }
        hv.setFenceProgress(0.62)   // 诊断快照：固定一个演示填充，便于肉眼核对围栏线（真实运行由 5s 倒数驱动）
        hv.layoutSubtreeIfNeeded()
        guard let rep = hv.bitmapImageRepForCachingDisplay(in: hv.bounds) else { print("header-shot: no rep"); return }
        hv.cacheDisplay(in: hv.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { print("header-shot: no png"); return }
        do { try data.write(to: URL(fileURLWithPath: path)); print("header-shot: \(path) bounds=\(hv.bounds.size)") }
        catch { print("header-shot: write failed \(error)") }
    }
}

// --menu-shot <png>：把整个菜单（含分组头等自绘 NSView 行）离屏渲染成 PNG（验证用；
// --dump 只有文本，看不到真实列宽/自绘视图）
if let idx = CommandLine.arguments.firstIndex(of: "--menu-shot") {
    let path = (idx + 1 < CommandLine.arguments.count) ? CommandLine.arguments[idx + 1] : "menu-shot.png"
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        defer { NSApp.terminate(nil) }
        let items = widget.menu.items
        let width: CGFloat = 680   // 画布按菜单真实上限（实测窗宽≈670）取，别截掉右缘内容
        var heights: [CGFloat] = []
        for mi in items {
            if mi.isSeparatorItem { heights.append(12) }
            else if let v = mi.view {
                v.layoutSubtreeIfNeeded()
                heights.append(max(v.bounds.height, 24))
            } else {
                let at = mi.attributedTitle ?? NSAttributedString(string: mi.title)
                heights.append(min(max(at.size().height + 10, 22), 80))
            }
        }
        let total = heights.reduce(0, +)
        guard total > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(total),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { print("menu-shot: no rep"); return }
        // 显式钉进目标外观再合成：动态色（windowBackgroundColor/labelColor/分隔线）在绘制那一刻按
        // current appearance 解析——不包这层，--menu-shot x.png light 会出「浅底深影错版」
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: total)).fill()
        var y = total
        for (i, mi) in items.enumerated() {
            let h = heights[i]
            y -= h
            if mi.isSeparatorItem {
                NSColor.separatorColor.setFill()
                NSBezierPath(rect: NSRect(x: 10, y: y + h / 2 - 0.5, width: width - 20, height: 1)).fill()
            } else if let v = mi.view {
                if let vrep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: vrep)
                    // 显式 .sourceOver——裸 draw(in:) 会整块替换目标，把已画的窗口底色擦掉（--errtest 探针实锤，d.md §39）
                    vrep.draw(in: NSRect(x: 0, y: y, width: min(width, v.bounds.width), height: min(h, v.bounds.height)),
                              from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                }
            } else {
                let at = mi.attributedTitle ?? NSAttributedString(string: mi.title)
                at.draw(at: NSPoint(x: 14, y: y + 4))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        }   // performAsCurrentDrawingAppearance（外观钉死块）
        guard let data = rep.representation(using: .png, properties: [:]) else { print("menu-shot: no png"); return }
        do { try data.write(to: URL(fileURLWithPath: path)); print("menu-shot: \(path) size=\(Int(width))x\(Int(total)) rows=\(items.count)") }
        catch { print("menu-shot: write failed \(error)") }
    }
}

app.run()