import SwiftUI
import AppKit
import Combine

// 配置窗口（⌘,）。SwiftUI：左侧目录侧栏（通用/通知权限/分组→条目/底部动作，⌘F 搜索、⌘B 开关侧栏），
// 右侧按选中渲染详情页。命令字段以「shell 字符串」编辑；数组（argv）形态的命令显示为语义等价的
// 引号转义串，未编辑就保存则原样写回数组——参数边界（空格/引号/$/;）不丢失。

// 配置窗口宽度连带（契约 §7）：英文标签比中文长，固定列宽按语言档切换；中文保持已定稿原值
private var formLabelWideW: CGFloat { isZhLocale() ? 150 : 212 }   // NumField / 高亮颜色 / 状态
private var formLabelTinyW: CGFloat { isZhLocale() ? 44 : 92 }     // 条目表单左列（启动/停止/网页/前置/内存门槛…）
private var formLabelMedW: CGFloat { isZhLocale() ? 74 : 124 }     // 「未运行文案」列

// MARK: - 可编辑草稿
final class ItemDraft: ObservableObject, Identifiable {
    let id = UUID()
    @Published var key = ""
    @Published var label = ""
    @Published var labelOff = moo("未运行", "Not Running")
    @Published var port = ""
    @Published var probe = "port"
    @Published var process = ""
    @Published var pidFile = ""
    @Published var check = ""
    @Published var start = ""
    @Published var stop = ""
    @Published var precheck = ""
    @Published var requireFreeGB = ""
    @Published var confirmStop = false
    @Published var loadable = true
    @Published var gpuEngine = false
    @Published var url = ""
    @Published var soundOnStart = false
    // 命令字段的原始 argv 形态（配置里是数组时记录）：编辑字符串未被改动时保存写回数组，
    // 避免降级成 shell 字符串后参数边界丢失（["echo","a b"] → "echo a b" 的语义漂移）
    var origCheck: [String]?
    var origStart: [String]?
    var origStop: [String]?
    var origPrecheck: [String]?
}

final class GroupDraft: ObservableObject, Identifiable {
    let id = UUID()
    @Published var title = ""
    /// 「互斥（一次只跑一个）」与「允许全部启动」互斥：配置界面里只能勾一个（2026-10-04 用户定；
    /// 运行时 `exclusive` 本来就会压掉「全部启动」按钮，见 App.swift 的 `allowStartAll && !exclusive`）。
    /// 两个都不勾＝不互斥、也不显示「▶ 全部启动」——保留原来的第三种配置，故不是强制单选。
    /// didSet 互清不会递归：被置 false 的那一方 didSet 判定为假，不再改动对方。
    @Published var exclusive = false {
        didSet { if exclusive && allowStartAll { allowStartAll = false } }
    }
    @Published var allowStartAll = true {
        didSet { if allowStartAll && exclusive { exclusive = false } }
    }
    @Published var allowStopAll = true
    @Published var items: [ItemDraft] = []
    @Published var pasteCmd = ""
}

final class FooterDraft: ObservableObject, Identifiable {
    let id = UUID()
    @Published var label = ""
    @Published var command = ""
    @Published var showWhenAnyRunning = false
    var origCommand: [String]?   // 原始 argv 形态（同 ItemDraft.origStart 的保真逻辑）
}

// MARK: - 粘贴命令 → 自动生成条目
func slug(_ s: String) -> String {
    var out = ""
    var lastHyphen = false
    for ch in s.lowercased().unicodeScalars {
        if CharacterSet.alphanumerics.contains(ch) {
            out.unicodeScalars.append(ch); lastHyphen = false
        } else if !lastHyphen {
            out.append("-"); lastHyphen = true
        }
    }
    let t = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return t.isEmpty ? "item" : t
}

func detectPort(_ s: String) -> Int? {
    let patterns = [#"--port[= ]+(\d{2,5})"#, #"-p[= ]+(\d{2,5})"#, #":(\d{2,5})\b"#, #"http\.server[= ](\d{2,5})"#]
    for pat in patterns {
        guard let re = try? NSRegularExpression(pattern: pat),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s),
              let p = Int(s[r]), (1...65535).contains(p) else { continue }
        return p
    }
    return nil
}

// 单引号强引用（生成 shell 字符串防注入）：' → '\''
func shQ(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

// argv → 语义等价的 shell 显示串：为空或含 shell 特殊字符（空格/引号/$/;/`/~ 等）的元素用
// shQ 单引号包裹，其余裸拼。既是编辑期的显示形态，也是「未被编辑」的比对基准。
// 注意 ~ 必须包进引号：argv 里不展开，shell 字符串里裸写会变成家目录展开
func joinArgv(_ a: [String]) -> String {
    a.map { s -> String in
        let plain = !s.isEmpty && !s.contains { " \t\"'`$;&|<>\\*?[](){}#~".contains($0) }
        return plain ? s : shQ(s)
    }.joined(separator: " ")
}
// AppleScript 双引号字符串转义（用于 osascript -e 内的 "..."）
func asQ(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }

func makeItemDraft(fromCommand cmd: String) -> ItemDraft? {
    let s = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !s.isEmpty else { return nil }
    let d = ItemDraft()
    d.start = s
    let tokens = s.split(separator: " ").map(String.init)
    guard let first = tokens.first else { return d }
    let base = (first as NSString).lastPathComponent
    let interpreters: Set<String> = ["python3", "python", "python2", "node", "npm", "npx", "deno", "bun", "ruby", "bash", "sh", "zsh", "fish"]

    // 打开 App：纯按钮，不跟踪状态
    if first == "open" {
        if let i = tokens.firstIndex(where: { $0 == "-a" || $0 == "-A" || $0 == "-b" }), i + 1 < tokens.count {
            let name = tokens[i + 1]
            d.label = name
            d.key = slug(name)
            d.probe = "none"
            d.stop = "osascript -e " + shQ("quit app " + asQ(name))
        } else {
            d.label = tokens.count > 1 ? tokens.dropFirst().joined(separator: " ") : moo("打开", "Open")
            d.key = "open"
            d.probe = "none"
        }
        return d
    }

    // 端口
    if let port = detectPort(s) {
        var name = base
        if let mi = tokens.firstIndex(of: "-m"), mi + 1 < tokens.count {
            name = (tokens[mi + 1] as NSString).lastPathComponent
        }
        d.probe = "port"
        d.port = String(port)
        d.label = "\(name) :\(port)"
        d.key = slug("\(name)-\(port)")
        if name == "http.server" { d.stop = "pkill -f " + shQ(s) }
        return d
    }

    // 进程名
    var proc = base
    if interpreters.contains(first),
       let sc = tokens.dropFirst().first(where: { !$0.hasPrefix("-") }) {
        proc = (sc as NSString).lastPathComponent
    }
    d.probe = "process"
    d.process = proc
    d.key = slug(proc)
    d.label = proc
    if s.hasSuffix(" start") { d.stop = String(s.dropLast(" start".count)) + " stop" }
    else if s.hasSuffix(" up") { d.stop = String(s.dropLast(" up".count)) + " down" }
    return d
}

final class SettingsModel: ObservableObject {
    @Published var cpuPercent = "85"
    @Published var gpuPercent = "85"
    @Published var fanRPM = "4500"
    @Published var diskWarnPercent = "70"
    @Published var diskCritPercent = "90"
    @Published var color = "orange"
    @Published var topN = "6"
    @Published var groups: [GroupDraft] = []
    @Published var footer: [FooterDraft] = []
    @Published var savedNote: String?
    @Published var notifStatus = moo("未知", "Unknown")
    @Published var notifDenied = false
    // 视图本地状态放模型里：CLT-only 构建没有 SwiftUIMacros 插件，@State/@FocusState 用不了（见 AGENTS.md 已知坑 10）
    @Published var selection: SettingsPane? = .general
    // scrollspy 静默窗：程序化滚动（点击导航/新建跳转/载入草稿）期间高亮不跟随，防沿路闪；
    // 非 UI 状态，不 @Published
    var spySuppressUntil = Date.distantPast
    func suppressSpy() { spySuppressUntil = Date().addingTimeInterval(0.45) }
    // scrollspy 缓存：各锚点区块的间谍 NSView（weak，随视图生死）+ 所在 NSScrollView；
    // 滚动帧里用 AppKit convert 现算视口坐标，不缓存任何坐标值
    var spyMarkers: [SettingsPane: WeakView] = [:]
    weak var spyScrollView: NSScrollView?
    var spyLastOffsetY: CGFloat = 0   // 最近一次 NSScrollView 下滚位移（调试用）
    @Published var showSidebar = true
    @Published var sidebarFilter = ""
    // 注：macOS 上 SwiftUI 的 dynamicTypeSize 不影响文字大小（Apple 文档明说），⌘+/− 缩放走
    // uiZoom（倍数注入根环境字体 + controlSize），UserDefaults 记住偏好。
    @Published var uiZoom: Double = {
        let v = UserDefaults.standard.object(forKey: "uiZoom") as? Double ?? 1.0
        return min(max(v, 0.8), 1.6)
    }() { didSet { UserDefaults.standard.set(uiZoom, forKey: "uiZoom") } }
    func uiZoomStep(_ delta: Double) { uiZoom = min(max(((uiZoom + 0.1 * delta) * 10).rounded() / 10, 0.8), 1.6) }
    func uiZoomReset() { uiZoom = 1.0 }

    func load(_ obj: [String: Any]) {
        let h = obj["highlight"] as? [String: Any] ?? [:]
        cpuPercent = numStr(h["cpuPercent"]) ?? "85"
        gpuPercent = numStr(h["gpuPercent"]) ?? "85"
        fanRPM = numStr(h["fanRPM"]) ?? "4500"
        diskWarnPercent = numStr(h["diskWarnPercent"]) ?? "70"
        diskCritPercent = numStr(h["diskCritPercent"]) ?? "90"
        color = h["color"] as? String ?? "orange"
        topN = numStr(obj["topN"]) ?? "6"
        // load 分级阈值 / confirmWindowSeconds / 超时旋钮已硬编（Hardwired），旧配置里的字段直接忽略
        groups = (obj["groups"] as? [[String: Any]] ?? []).map { g in
            let d = GroupDraft()
            d.title = g["title"] as? String ?? ""
            d.exclusive = g["exclusive"] as? Bool ?? false
            // 两者互斥（见 GroupDraft 注释）：存量配置可能是旧的「两个都为真」，以 exclusive 为准——
            // 否则一打开配置界面就是"两个都勾上"的非法态。非互斥组照旧尊重 allowStartAll=false。
            d.allowStartAll = d.exclusive ? false : (g["allowStartAll"] as? Bool ?? true)
            d.allowStopAll = g["allowStopAll"] as? Bool ?? true
            d.items = (g["items"] as? [[String: Any]] ?? []).map { it in
                let dd = ItemDraft()
                dd.key = it["key"] as? String ?? ""
                dd.label = it["label"] as? String ?? ""
                dd.labelOff = it["labelOff"] as? String ?? moo("未运行", "Not Running")
                dd.port = numStr(it["port"]) ?? ""
                if let p = it["probe"] as? String { dd.probe = p }
                else if it["process"] != nil { dd.probe = "process" }
                else if it["pidFile"] != nil { dd.probe = "pidFile" }
                else if it["check"] != nil { dd.probe = "check" }
                else { dd.probe = "port" }
                dd.process = cmdString(it["process"])
                dd.pidFile = it["pidFile"] as? String ?? ""
                (dd.check, dd.origCheck) = cmdEdit(it["check"])
                (dd.start, dd.origStart) = cmdEdit(it["start"])
                (dd.stop, dd.origStop) = cmdEdit(it["stop"])
                (dd.precheck, dd.origPrecheck) = cmdEdit(it["precheck"])
                dd.requireFreeGB = numStr(it["requireFreeGB"]) ?? ""
                dd.confirmStop = it["confirmStop"] as? Bool ?? false
                dd.loadable = it["loadable"] as? Bool ?? true
                dd.gpuEngine = it["gpuEngine"] as? Bool ?? false
                dd.url = it["url"] as? String ?? ""
                dd.soundOnStart = it["soundOnStart"] as? Bool ?? false
                return dd
            }
            return d
        }
        footer = (obj["footer"] as? [[String: Any]] ?? []).map { f in
            let d = FooterDraft()
            d.label = f["label"] as? String ?? ""
            (d.command, d.origCommand) = cmdEdit(f["command"])
            d.showWhenAnyRunning = f["showWhenAnyRunning"] as? Bool ?? false
            return d
        }
        // 草稿全换（UUID 变）：选中/搜索一并重置
        selection = .general
        suppressSpy()
        sidebarFilter = ""
    }

    func toJSON() -> [String: Any] {
        let cpu = dbl(cpuPercent) ?? 85.0
        let gpu = dbl(gpuPercent) ?? 85.0
        let top = max(1, int(topN))
        let fan = int(fanRPM)
        let diskW = int(diskWarnPercent)
        let diskC = int(diskCritPercent)
        var root: [String: Any] = [:]
        root["highlight"] = [
            "cpuPercent": cpu, "gpuPercent": gpu, "fanRPM": fan > 0 ? fan : 4500,
            "diskWarnPercent": diskW > 0 ? diskW : 70, "diskCritPercent": diskC > 0 ? diskC : 90,
            "color": color
        ]
        root["topN"] = top
        // load 分级 / confirmWindowSeconds / 超时已硬编（Hardwired），不再写配置
        root["groups"] = groups.map { g -> [String: Any] in
            var gd: [String: Any] = ["title": g.title, "items": g.items.map(itemToJSON)]
            if g.exclusive { gd["exclusive"] = true }               // 只写非默认：false 省略
            if !g.allowStartAll { gd["allowStartAll"] = false }     // 默认 true，省略
            if !g.allowStopAll { gd["allowStopAll"] = false }
            return gd
        }
        root["footer"] = footer.map { f -> [String: Any] in
            var d: [String: Any] = ["label": f.label]
            if let v = cmdOut(f.origCommand, f.command) { d["command"] = v }
            if f.showWhenAnyRunning { d["showWhenAnyRunning"] = true }
            return d
        }
        return root
    }

    // 条目 → JSON：只写非默认值，与 load() 的 ?? 回落一一对应——⌘, 存出的文件不再有
    // "port":0 / "confirmStop":false / "labelOff":"未运行" 这类默认值噪音
    private func itemToJSON(_ it: ItemDraft) -> [String: Any] {
        var d: [String: Any] = ["key": it.key, "label": it.label]
        if !it.labelOff.isEmpty && it.labelOff != moo("未运行", "Not Running") { d["labelOff"] = it.labelOff }
        if it.probe != "port" { d["probe"] = it.probe }             // port 是默认探测，省略
        if it.probe == "port", let p = Int(it.port.trimmingCharacters(in: .whitespaces)), p > 0 { d["port"] = p }
        if it.confirmStop { d["confirmStop"] = true }
        if !it.loadable { d["loadable"] = false }
        if it.gpuEngine { d["gpuEngine"] = true }
        if !it.process.isEmpty { d["process"] = it.process }
        if !it.pidFile.isEmpty { d["pidFile"] = it.pidFile }
        if let v = cmdOut(it.origCheck, it.check) { d["check"] = v }
        if let v = cmdOut(it.origStart, it.start) { d["start"] = v }
        if let v = cmdOut(it.origStop, it.stop) { d["stop"] = v }
        if let v = cmdOut(it.origPrecheck, it.precheck) { d["precheck"] = v }
        if !it.url.isEmpty { d["url"] = it.url }
        if it.soundOnStart { d["soundOnStart"] = true }
        if let v = dbl(it.requireFreeGB), v > 0 { d["requireFreeGB"] = v }
        return d
    }

    private func numStr(_ v: Any?) -> String? {
        if let n = v as? NSNumber { return n.stringValue }
        if let s = v as? String { return s }
        return nil
    }
    private func cmdString(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let a = v as? [String] { return a.joined(separator: " ") }
        return ""
    }
    // 命令字段读取：字符串 → (原样, nil)；数组 → (语义等价显示串, 原数组)。
    // 显示串对特殊字符加引号，未编辑时保存可原样写回数组（argv 无 shell 的属性不丢）
    private func cmdEdit(_ v: Any?) -> (String, [String]?) {
        if let s = v as? String { return (s, nil) }
        if let a = v as? [String] { return (joinArgv(a), a) }
        return ("", nil)
    }
    // 命令字段写回：编辑串与原始数组的 joinArgv 一致（未被编辑）→ 写回数组保真；否则写 shell 字符串
    private func cmdOut(_ orig: [String]?, _ edited: String) -> Any? {
        if let a = orig, joinArgv(a) == edited { return a.isEmpty ? nil : a }
        return edited.isEmpty ? nil : edited
    }
    private func dbl(_ s: String) -> Double? { Double(s.trimmingCharacters(in: .whitespaces)) }
    private func int(_ s: String) -> Int { Int(s.trimmingCharacters(in: .whitespaces)) ?? 0 }

    // 保存前校验：空标题/key/label 或重复 key 会静默丢条目/互串，这里拦下来
    func validate() -> String? {
        var seen = Set<String>()
        for g in groups {
            if g.title.trimmingCharacters(in: .whitespaces).isEmpty { return moo("有分组标题为空，请补全再保存", "a group title is empty — fill it in before saving") }
            for it in g.items {
                let k = it.key.trimmingCharacters(in: .whitespaces)
                let l = it.label.trimmingCharacters(in: .whitespaces)
                if k.isEmpty { return moo("「\(g.title)」里有条目 key 为空", "\"\(g.title)\" has an item with an empty key") }
                if l.isEmpty { return moo("「\(g.title)」里的 key「\(k)」名称(label)为空", "key \"\(k)\" in \"\(g.title)\" has an empty name (label)") }
                if !seen.insert(k).inserted { return moo("key「\(k)」重复，保存后会互相覆盖，请改成唯一", "duplicate key \"\(k)\" — entries would overwrite each other, make it unique") }
                // 端口探测条目必须有合法端口，否则是永远探不活的死条目
                if it.probe == "port" {
                    let p = Int(it.port.trimmingCharacters(in: .whitespaces)) ?? 0
                    if !(1...65535).contains(p) { return moo("「\(g.title)」里的「\(k)」是端口探测，端口要填 1~65535", "\"\(k)\" in \"\(g.title)\" uses port probe — set port 1~65535") }
                }
            }
        }
        // 底部动作缺名称/命令不会被拦下，但重新加载时会整条消失——现在就拦
        for f in footer {
            if f.label.trimmingCharacters(in: .whitespaces).isEmpty { return moo("底部动作有空名称，请补全或删掉该行", "a footer action has an empty name — fill it in or delete the row") }
            if f.command.trimmingCharacters(in: .whitespaces).isEmpty { return moo("底部动作「\(f.label)」缺命令，保存后会消失", "footer action \"\(f.label)\" has no command — it would vanish after saving") }
        }
        // 数值次序：磁盘预警 > 告急会让「资源不足」永远不显示（相等=只看告急，是合法配置，不拦）
        if let w = dbl(diskWarnPercent), let c = dbl(diskCritPercent), w > c {
            return moo("磁盘预警（\(w)%）应 ≤ 告急（\(c)%），否则预警档永远显示不出来",
                       "disk warn threshold (\(w)%) must be ≤ critical (\(c)%) — otherwise the warn tier never shows")
        }
        return nil
    }

    // 「清空配置」：表单回到全新安装的默认态（空分组/空底部动作/内置默认阈值），等「保存并生效」才落盘。
    // load([:]) 的每个字段都会走 ?? 默认回落，正好就是 defaultConfig() 的表单形态
    func loadDefault() { load([:]) }

    func refreshNotifStatus() {
        notifAuthStatus { [weak self] text, denied in
            DispatchQueue.main.async {
                self?.notifStatus = text
                self?.notifDenied = denied
                self?.savedNote = nil   // 查询动作：清掉底部残留的旧提示（如陈旧的“未授权”）
            }
        }
    }
    func requestNotif() {
        requestNotifAuth { [weak self] _ in
            DispatchQueue.main.async {
                // 授权结果以「状态」行为准：requestAuthorization 在已被拒后不再弹窗、恒返回 false，
                // 不能当结论；真值由 getNotificationSettings 读出（refreshNotifStatus）。
                self?.refreshNotifStatus()
            }
        }
    }
    func openNotifSettings() { openNotifSystemSettings() }
}

// MARK: - 视图
private struct NumField: View {
    let title: String
    @Binding var text: String
    var isInt = true                       // 整数：只吃 0-9；浮点：额外允许一个小数点
    var range: ClosedRange<Double>? = nil  // 防呆范围：越界（含负号/粘贴）当场钳回

    var body: some View {
        HStack {
            Text(title).frame(width: formLabelWideW, alignment: .trailing)
            TextField("", text: Binding(
                get: { text },
                set: { text = Self.sanitize($0, isInt: isInt, range: range) }
            ))
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
        }
    }

    // 防呆：只留数字（浮点再留一个小数点）→ 负号/字母/多余小数点直接吞掉 → 越界拉回上下限
    static func sanitize(_ raw: String, isInt: Bool, range: ClosedRange<Double>?) -> String {
        var out = ""
        var seenDot = false
        for ch in raw {
            if ch >= "0" && ch <= "9" { out.append(ch) }
            else if !isInt && ch == "." && !seenDot { seenDot = true; out.append(ch) }
        }
        if let r = range, let v = Double(out) {
            if v < r.lowerBound { return fmt(r.lowerBound, isInt: isInt) }
            if v > r.upperBound { return fmt(r.upperBound, isInt: isInt) }
        }
        return out
    }

    static func fmt(_ v: Double, isInt: Bool) -> String {
        if isInt { return String(Int(v.rounded())) }
        if v.rounded() == v { return String(Int(v)) }
        return String(format: "%.1f", v)
    }
}

// 给 NumField 之外的散装数值输入用：同一套防呆，不动布局
private func numBinding(_ source: Binding<String>, isInt: Bool, range: ClosedRange<Double>) -> Binding<String> {
    Binding(get: { source.wrappedValue },
            set: { source.wrappedValue = NumField.sanitize($0, isInt: isInt, range: range) })
}

// 侧栏导航的锚点：固定节点 + 分组 + 单条目（UUID 对应 GroupDraft/ItemDraft.id）
enum SettingsPane: Hashable {
    case general, footers
    case group(UUID)
    case item(UUID)
}

// scrollspy 的坐标源：每个锚点区块的背景里放一个间谍 NSView 标记，滚动发生时用 AppKit 的
// convert 当场换算视口坐标——不做任何坐标缓存/记账（preference 方案在手滚下拿不到布局帧，
// 「布局时刻 + 位移」换算又会被错位帧污染，见 d.md §18.3）
struct WeakView { weak var v: NSView?; init(_ v: NSView) { self.v = v } }

// 锚点标记：挂在区块背景上的空 NSView，注册进 model.spyMarkers 供滚动帧现算位置
private struct SpyMarker: NSViewRepresentable {
    var register: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        register(v)
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// 唯一感知真实手滚的探测器：macOS 的 NSScrollView 手滚是硬件加速图层面位移，不触发
// SwiftUI 布局，GeometryReader/preference 一根手指都动不了——只能直接盯其 bounds 通知
private struct ScrollOffsetReader: NSViewRepresentable {
    var onScroll: (CGFloat, CGFloat, CGFloat) -> Void   // (下滚位移, 视口高, 文档总高)
    var onScrollView: (NSScrollView) -> Void            // 把 NSScrollView 交回 model 供坐标换算

    func makeNSView(context: Context) -> NSView {
        context.coordinator.setup()
        return context.coordinator.view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onScroll = onScroll
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onScroll: onScroll, onScrollView: onScrollView)
    }

    final class Coordinator: NSObject {
        var onScroll: (CGFloat, CGFloat, CGFloat) -> Void
        let onScrollView: (NSScrollView) -> Void
        let view = NSView()
        private weak var scrollView: NSScrollView?

        init(onScroll: @escaping (CGFloat, CGFloat, CGFloat) -> Void,
             onScrollView: @escaping (NSScrollView) -> Void) {
            self.onScroll = onScroll
            self.onScrollView = onScrollView
        }

        func setup() {
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let sv = self.view.enclosingScrollView else { return }
                self.scrollView = sv
                self.onScrollView(sv)
                NotificationCenter.default.addObserver(
                    self, selector: #selector(self.scrolled),
                    name: NSView.boundsDidChangeNotification, object: sv.contentView)
                self.scrolled()   // 报一次初始状态
            }
        }

        @objc private func scrolled() {
            guard let sv = scrollView, let doc = sv.documentView else { return }
            let rect = sv.documentVisibleRect
            // SwiftUI 的滚动内容是 flipped 坐标系：origin.y=0 在顶部，正是「往下滚了多少」
            onScroll(max(rect.origin.y, 0), rect.height, doc.frame.height)
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}

private var spyDebugPrinted = false   // MOO_SPY_DEBUG=1 时打首帧汇总（管道自检用），只打一次

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    var onSave: () -> Void
    var onReveal: () -> Void
    var onLoadExample: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    if model.showSidebar {
                        // 侧栏只做目录定位：点击滚到对应区块，右侧始终是全量配置
                        SidebarView(model: model) { pane in
                            model.selection = pane
                            model.suppressSpy()
                            DispatchQueue.main.async { withAnimation { proxy.scrollTo(pane, anchor: .top) } }
                        }
                        .frame(width: Trunc.settingsSidebarPx)
                        Divider()
                    }
                    ScrollView {
                        fullLayout(proxy)
                    }
                }
                Divider()
                bottomBar
            }
            .frame(minWidth: 920, minHeight: 560)
            // ⌘+/− 全局缩放：macOS 的 dynamicTypeSize 是摆设，这里按倍数注入根字体环境，
            // 控件尺寸用 controlSize 跟随；字全部是继承字体，个别显式 caption 已换成倍数字号
            .environment(\.font, .system(size: 13 * model.uiZoom))
            .controlSize(model.uiZoom >= 1.15 ? .large : .regular)
            // 隐藏按钮只当快捷键载体：⌘B 开关侧栏（VSCode 同款）、⌘+/−/0 界面缩放
            .background(
                HStack(spacing: 0) {
                    Button("") { model.showSidebar.toggle() }.keyboardShortcut("b", modifiers: .command)
                    Button("") { model.uiZoomStep(1) }.keyboardShortcut("=", modifiers: .command)
                    Button("") { model.uiZoomStep(1) }.keyboardShortcut("+", modifiers: .command)
                    Button("") { model.uiZoomStep(-1) }.keyboardShortcut("-", modifiers: .command)
                    Button("") { model.uiZoomReset() }.keyboardShortcut("0", modifiers: .command)
                }
                .buttonStyle(.plain)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            )
        }
    }

    private var bottomBar: some View {
        HStack {
            if let note = model.savedNote { Text(note).foregroundColor(.green) }
            Spacer()
            Button(moo("清空配置", "Clear Config")) {
                model.loadDefault()
                model.savedNote = moo("已清空为默认（尚未保存）——点「保存并生效」生效，点「取消」反悔",
                                      "Reset to defaults (not saved yet) — hit \"Save & Apply\" to keep, \"Cancel\" to revert")
            }
            Button(moo("载入示例", "Load Example")) { onLoadExample() }
            Button(moo("打开 config.json", "Open config.json")) { onReveal() }
            Button(moo("取消", "Cancel")) { NSApp.keyWindow?.close() }
            Button(moo("保存并生效", "Save & Apply")) { onSave() }.keyboardShortcut(.defaultAction)
        }.padding(12)
    }

    // 全量配置：阈值/通知/全部分组/底部动作一页滚到底，侧栏锚点跳转（.id 对应 SettingsPane）
    private func fullLayout(_ proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // 唯一感知真实手滚的探测器：零尺寸不占布局，位移回调直接推导高亮
            ScrollOffsetReader(
                onScroll: { spyScroll($0, $1, $2) },
                onScrollView: { model.spyScrollView = $0 })
                .frame(width: 0, height: 0)
            HStack(alignment: .top, spacing: 14) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        NumField(title: moo("CPU 超过 (%) 高亮", "Highlight if CPU above (%)"), text: $model.cpuPercent, isInt: false, range: 1...100)
                        NumField(title: moo("GPU 超过 (%) 高亮", "Highlight if GPU above (%)"), text: $model.gpuPercent, isInt: false, range: 1...100)
                        NumField(title: moo("风扇超过 (RPM) 高亮", "Highlight if fan above (RPM)"), text: $model.fanRPM, range: 1...20000)
                        NumField(title: moo("磁盘占用 预警 (%)", "Disk usage warn (%)"), text: $model.diskWarnPercent, range: 1...100)
                        NumField(title: moo("磁盘占用 告急 (%)", "Disk usage critical (%)"), text: $model.diskCritPercent, range: 1...100)
                        HStack {
                            Text(moo("高亮颜色", "Highlight color")).frame(width: formLabelWideW, alignment: .trailing)
                            Picker("", selection: $model.color) {
                                ForEach(["orange", "red", "yellow", "blue", "purple", "green"], id: \.self) { Text($0).tag($0) }
                            }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(6)
                } label: { Text(moo("高亮阈值", "Highlight Thresholds")) }

                // 右列：通用 + 通知权限，填掉左列 6 行下面的大空档
                VStack(alignment: .leading, spacing: 14) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            NumField(title: moo("内存大户 TOP 条数", "Memory Hogs TOP count"), text: $model.topN, range: 1...50)
                        }.padding(6)
                    } label: { Text(moo("通用", "General")) }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(moo("状态", "Status")).frame(width: formLabelWideW, alignment: .trailing)
                                Text(model.notifStatus)
                                    .foregroundColor(model.notifDenied ? .orange : .green)
                            }
                            HStack {
                                Spacer()
                                Button(moo("重新检测", "Re-check")) { model.refreshNotifStatus() }
                                if model.notifDenied {
                                    Button(moo("去系统设置开启", "Open System Settings")) { model.openNotifSettings() }
                                } else {
                                    Button(moo("请求开启通知", "Request Access")) { model.requestNotif() }
                                }
                                Spacer()
                            }
                            Text(moo("动作完成/失败会弹系统横幅提醒。", "Banner alerts on action success/failure."))
                                .font(.system(size: 11 * model.uiZoom)).foregroundColor(.secondary)
                                .frame(maxWidth: .infinity)
                                .multilineTextAlignment(.center)
                        }.padding(6)
                    } label: { Text(moo("通知权限", "Notifications")) }
                }
            }
            .background(SpyMarker { model.spyMarkers[.general] = WeakView($0) })
            .id(SettingsPane.general)

            ForEach(model.groups) { g in
                GroupBox {
                    GroupEditor(
                        group: g,
                        onJumpItem: { it in
                            model.selection = .item(it.id)
                            model.suppressSpy()
                            DispatchQueue.main.async { withAnimation { proxy.scrollTo(SettingsPane.item(it.id), anchor: .top) } }
                        },
                        onDeleteGroup: {
                            model.groups.removeAll { $0.id == g.id }
                            model.selection = .general
                        },
                        markerSink: { pane, v in model.spyMarkers[pane] = WeakView(v) }
                    )
                } label: { Text(moo("分组：\(g.title.isEmpty ? "未命名" : g.title)",
                                    "Group: \(g.title.isEmpty ? "Untitled" : g.title)")) }
                .background(SpyMarker { model.spyMarkers[.group(g.id)] = WeakView($0) })
                .id(SettingsPane.group(g.id))
            }

            HStack {
                Button(moo("＋ 添加分组", "＋ Add Group")) {
                    let g = GroupDraft()
                    model.groups.append(g)
                    model.selection = .group(g.id)
                    model.suppressSpy()
                    DispatchQueue.main.async { withAnimation { proxy.scrollTo(SettingsPane.group(g.id), anchor: .top) } }
                }
                Spacer()
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.footer) { f in
                        FooterRow(footer: f) { model.footer.removeAll { $0.id == f.id } }
                    }
                    Button(moo("＋ 添加底部动作", "＋ Add Footer Action")) { model.footer.append(FooterDraft()) }
                }.padding(6)
            } label: { Text(moo("底部动作", "Footer Actions")) }
            .background(SpyMarker { model.spyMarkers[.footers] = WeakView($0) })
            .id(SettingsPane.footers)
        }
        .padding(16)
    }

    // 滚动跟随推导（手滚/程序化滚动同一路径，NSScrollView bounds 通知驱动）。
    // 锚点视口坐标用间谍 NSView + convert 当场算；当前区块 = 视口上 35% 分界线的落点，
    // 条目也挂锚点——落在条目卡内就亮条目，落在组头/组间空隙就亮分组，最深层锚点优先；
    // 只有推导结果和 selection 不同才写状态（同一区块内滚动零刷新）
    private func spyScroll(_ offsetY: CGFloat, _ visibleH: CGFloat, _ docH: CGFloat) {
        model.spyLastOffsetY = offsetY
        guard let sv = model.spyScrollView, let docView = sv.documentView,
              Date() >= model.spySuppressUntil else { return }
        var valid: Set<SettingsPane> = [.general, .footers]
        for g in model.groups {
            valid.insert(.group(g.id))
            for it in g.items { valid.insert(.item(it.id)) }
        }
        var positions: [SettingsPane: CGFloat] = [:]
        for (pane, box) in model.spyMarkers {
            guard valid.contains(pane), let v = box.v else { continue }
            // 实测：SwiftUI 的 macOS 滚动平移的是 documentView（clipView.bounds 不动），
            // convert 到 documentView 得到恒定文档坐标——文档Y − 位移 = 视口Y
            let r = v.convert(v.bounds, to: docView)
            positions[pane] = (docView.isFlipped ? r.minY : r.maxY) - offsetY
        }
        guard positions.count == valid.count else { return }   // 标记未齐（还在布局/刚删组）
        let threshold = visibleH * 0.35
        var pane = positions.filter { $0.value <= threshold }.max(by: { $0.value < $1.value })?.key
            ?? positions.min(by: { $0.value < $1.value })?.key ?? .general
        // 已滚到最底（文档高于视口且底边已进视口）→ 强制最底部锚点，
        // 否则「底部动作」在页尾永远够不到分界线、点不亮
        if docH > visibleH + 2, docH - (offsetY + visibleH) <= 2,
           let last = positions.max(by: { $0.value < $1.value })?.key {
            pane = last
        }
        // 点过侧栏后滚动手感：点击跳转是程序化滚动（静默窗内），结束即停、不再有通知帧，
        // 所以点哪项就一直亮哪项；真正手滚起来才由这里接管切到当前卡。无需额外保留规则
        if ProcessInfo.processInfo.environment["MOO_SPY_DEBUG"] == "1",
           !spyDebugPrinted || pane != model.selection {
            spyDebugPrinted = true
            // stderr 无缓冲：被 SIGTERM 杀掉也不丢行（print 走 stdout 块缓冲，重定向到文件会整块丢）
            fputs("spy: 位移=\(Int(offsetY)) 视口=\(Int(visibleH)) 文档=\(Int(docH)) 锚点=\(positions.count) 推导=\(pane) 原=\(String(describing: model.selection))\n", stderr)
        }
        if model.selection != pane { model.selection = pane }
    }
}

// MARK: - 侧栏（目录：点击滚动定位，右侧始终全量配置；顶部搜索过滤）
private struct SidebarView: View {
    @ObservedObject var model: SettingsModel
    var onNavigate: (SettingsPane) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                TextField(moo("搜索：名称 / key / 端口", "Search: name / key / port"), text: $model.sidebarFilter)
                    .textFieldStyle(.roundedBorder)
                if !model.sidebarFilter.isEmpty {
                    Button { model.sidebarFilter = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                        .buttonStyle(.plain)
                }
            }.padding(8)
            List {
                paneRow(.general, moo("通用", "General"), "gearshape")
                let f = model.sidebarFilter.trimmingCharacters(in: .whitespaces).lowercased()
                ForEach(model.groups) { g in
                    let titleMatch = !f.isEmpty && g.title.lowercased().contains(f)
                    let its = f.isEmpty ? g.items : (titleMatch ? g.items : g.items.filter { itemMatches($0, f) })
                    if f.isEmpty || titleMatch || !its.isEmpty {
                        groupRow(g)
                        ForEach(its) { it in
                            itemRow(it)
                        }
                    }
                }
                paneRow(.footers, moo("底部动作", "Footer Actions"), "terminal")
            }
            .listStyle(.sidebar)
            HStack {
                Spacer()
                Button(moo("＋ 添加分组", "＋ Add Group")) {
                    let g = GroupDraft()
                    model.groups.append(g)
                    onNavigate(.group(g.id))
                }
                Spacer()
            }.padding(8)
        }
    }

    // 整行可点的关键：contentShape 必须挂在 label 内部（frame 撑满之后）——
    // 挂在 Button 外面只改渲染不改命中，点行内空白没反应（2026-10-03 实测踩过）
    private func paneRow(_ pane: SettingsPane, _ title: String, _ icon: String) -> some View {
        Button { onNavigate(pane) } label: {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(pane == model.selection ? Color.accentColor.opacity(0.25) : Color.clear)
    }

    // 分组行：一整块可点，点击跳到对应 GroupBox；不做伸缩（右侧本就是全量滚动页），
    // 组内条目永远平铺展示在下一行
    private func groupRow(_ g: GroupDraft) -> some View {
        Button { onNavigate(.group(g.id)) } label: {
            Label(g.title.isEmpty ? moo("未命名", "Untitled") : g.title, systemImage: "folder")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(model.selection == .group(g.id) ? Color.accentColor.opacity(0.25) : Color.clear)
    }

    private func itemRow(_ it: ItemDraft) -> some View {
        Button { onNavigate(.item(it.id)) } label: {
            HStack {
                Text(it.label.isEmpty ? it.key : it.label).lineLimit(1)
                Spacer()
                if it.probe == "port", let p = Int(it.port), p > 0 {
                    Text(":" + String(p)).font(.system(size: 11 * model.uiZoom)).foregroundColor(.secondary)   // String() 防 Int 插值的本地化千分位（":8,028"）
                }
            }
            .padding(.leading, 16)              // 缩进画在行内：命中区仍盖满整行
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(model.selection == .item(it.id) ? Color.accentColor.opacity(0.25) : Color.clear)
    }

    // 搜索匹配：名称/未运行文案/key/进程/PID文件/检测命令/端口
    private func itemMatches(_ it: ItemDraft, _ f: String) -> Bool {
        [it.key, it.label, it.labelOff, it.process, it.pidFile, it.check, it.port]
            .contains { $0.lowercased().contains(f) }
    }
}

private struct GroupEditor: View {
    @ObservedObject var group: GroupDraft
    var onJumpItem: (ItemDraft) -> Void = { _ in }   // 新建条目后滚动定位到该条目
    var onDeleteGroup: () -> Void = {}               // 已过确认（有服务的组弹 NSAlert），这里只管删
    var markerSink: (SettingsPane, NSView) -> Void = { _, _ in }   // 条目卡锚点标记（scrollspy 用）

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(moo("标题", "Title")).frame(width: 60, alignment: .trailing)
                TextField(moo("如：服务 / 大模型", "e.g. Services / Models"), text: $group.title).textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 16) {
                // 互斥 与「允许全部启动」互斥：只能勾一个（互清逻辑在 GroupDraft 的 didSet 里，
                // 程序化赋值和界面点击走同一套，避免只在视图层拦一半）
                Toggle(moo("互斥（一次只跑一个）", "Exclusive (one at a time)"), isOn: $group.exclusive)
                Toggle(moo("允许全部启动", "Allow \"Start All\""), isOn: $group.allowStartAll)
                Toggle(moo("允许全部停止", "Allow \"Stop All\""), isOn: $group.allowStopAll)
                Spacer()
                Button(moo("删除分组", "Delete Group")) { confirmAndDelete() }
                    .buttonStyle(.borderless)
                    .foregroundColor(.red)
            }
            Divider()
            ForEach(group.items) { it in
                ItemEditor(item: it, group: group)
                    .padding(.leading, 0)
                    .background(SpyMarker { markerSink(.item(it.id), $0) })
                    .id(SettingsPane.item(it.id))   // 侧栏条目锚点
            }
            HStack(spacing: 6) {
                TextField(moo("粘贴启动命令，自动识别端口/进程/打开", "Paste a start command; port / process / open auto-detected"), text: $group.pasteCmd)
                    .textFieldStyle(.roundedBorder)
                Button(moo("＋ 生成条目", "＋ Create Items")) { generate() }
                    .disabled(group.pasteCmd.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Button(moo("＋ 添加空白条目", "＋ Add Blank Item")) {
                let d = ItemDraft()
                group.items.append(d)
                onJumpItem(d)
            }
        }.padding(8)
    }

    private func generate() {
        guard let d = makeItemDraft(fromCommand: group.pasteCmd) else { return }
        group.items.append(d)
        group.pasteCmd = ""
        onJumpItem(d)
    }

    // 有服务的组删除要二次确认；空组直接删（都只是表单层，真正落盘仍要点「保存并生效」）
    private func confirmAndDelete() {
        if !group.items.isEmpty {
            let alert = NSAlert()
            alert.messageText = moo("删除分组「\(capN(group.title.isEmpty ? "未命名" : group.title, Trunc.alertNameChars))」？（含 \(group.items.count) 个条目）",
                                    "Delete group \"\(capN(group.title.isEmpty ? "Untitled" : group.title, Trunc.alertNameChars))\"? (with \(group.items.count) items)")
            alert.addButton(withTitle: moo("删除", "Delete"))
            alert.addButton(withTitle: moo("取消", "Cancel"))
            alert.icon = cowEmojiIcon()
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        onDeleteGroup()
    }

    // 🐮 画成 NSImage 当确认框图标（品牌小牛）
    private func cowEmojiIcon(size: CGFloat = 48) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        ("🐮" as NSString).draw(
            in: NSRect(x: 0, y: 0, width: size, height: size),
            withAttributes: [.font: NSFont.systemFont(ofSize: size * 0.75), .paragraphStyle: style]
        )
        img.unlockFocus()
        return img
    }
}

private struct ItemEditor: View {
    @ObservedObject var item: ItemDraft
    @ObservedObject var group: GroupDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("key", text: $item.key).frame(width: 110).textFieldStyle(.roundedBorder)
                TextField(moo("名称 label", "Name (label)"), text: $item.label).textFieldStyle(.roundedBorder)
                Toggle(moo("可启动", "Startable"), isOn: $item.loadable)
                Toggle(moo("二次确认", "Confirm Before Stop"), isOn: $item.confirmStop)
                Spacer()
                Button(moo("删除", "Delete")) { group.items.removeAll { $0.id == item.id } }
                    .buttonStyle(.borderless)
                    .foregroundColor(.red)
            }
            HStack {
                Text(moo("状态", "Status")).frame(width: formLabelTinyW, alignment: .trailing)
                Picker("", selection: $item.probe) {
                    Text(moo("端口", "Port")).tag("port")
                    Text(moo("进程名", "Process")).tag("process")
                    Text(moo("PID 文件", "PID File")).tag("pidFile")
                    Text(moo("检测命令", "Check Command")).tag("check")
                    Text(moo("不跟踪", "Not Tracked")).tag("none")
                }.labelsHidden().frame(width: 130)
                switch item.probe {
                case "process":
                    TextField(moo("进程匹配（pgrep -f 正则）", "Match pattern (pgrep -f regex)"), text: $item.process).textFieldStyle(.roundedBorder)
                case "pidFile":
                    TextField(moo("PID 文件路径", "PID file path"), text: $item.pidFile).textFieldStyle(.roundedBorder)
                case "check":
                    TextField(moo("检测命令（exit 0 = 运行）", "Check command (exit 0 = running)"), text: $item.check).textFieldStyle(.roundedBorder)
                case "port":
                    TextField(moo("端口", "Port"), text: numBinding($item.port, isInt: true, range: 1...65535)).frame(width: 64).textFieldStyle(.roundedBorder)
                default:
                    Text(moo("点一下即执行，不显示运行状态", "Runs on click; no running state shown")).foregroundColor(.secondary)
                }
            }
            HStack {
                Text(moo("启动", "Start")).frame(width: formLabelTinyW, alignment: .trailing)
                TextField(moo("命令（字符串或空格分隔数组）", "Command (string or space-separated array)"), text: $item.start).textFieldStyle(.roundedBorder)
                if !item.requireFreeGB.isEmpty, let v = Double(item.requireFreeGB) { Text(moo("需空闲 \(v)G", "Needs \(v)G free")).foregroundColor(.secondary) }
                Toggle(moo("启动完成响哞", "Moo when start completes"), isOn: $item.soundOnStart)
                    .help(moo("启动命令成功跑完后的「启动完成」通知会带哞声；给启动慢的服务/模型用（点完走人，听见哞 = 起好了）",
                              "Notification for \"start completes\" plays the moo sound; for slow-loading services/models (start and walk away — a moo means it's ready)"))
            }
            HStack {
                Text(moo("停止", "Stop")).frame(width: formLabelTinyW, alignment: .trailing)
                TextField(moo("命令", "Command"), text: $item.stop).textFieldStyle(.roundedBorder)
            }
            HStack {
                Text(moo("网页", "Web")).frame(width: formLabelTinyW, alignment: .trailing)
                TextField(moo("运行中可一键打开的完整 URL（空=无）", "Full URL to open while running (empty = none)"), text: $item.url).textFieldStyle(.roundedBorder)
            }
            HStack {
                Text(moo("前置", "Pre-check")).frame(width: formLabelTinyW, alignment: .trailing)
                TextField(moo("检查命令（非 0 拒启）", "Check command (non-zero blocks start)"), text: $item.precheck).textFieldStyle(.roundedBorder)
            }
            HStack {
                Text(moo("内存门槛", "Memory Gate")).frame(width: formLabelTinyW, alignment: .trailing)
                TextField(moo("剩余可用 GB（空=不限）", "Required free GB (empty = any)"), text: numBinding($item.requireFreeGB, isInt: false, range: 0...1024)).frame(width: isZhLocale() ? 150 : 235).textFieldStyle(.roundedBorder)   // 英文 placeholder 更长，防截断（契约 §7）
                Text(moo("未运行文案", "\"Not Running\" text")).frame(width: formLabelMedW, alignment: .trailing)
                TextField(moo("未运行 / 已卸载", "Not Running / Unloaded"), text: $item.labelOff).frame(width: isZhLocale() ? 130 : 185).textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("").frame(width: formLabelTinyW)
                Toggle(moo("GPU 引擎（按进程统计不到，负载看整机）", "GPU engine (no per-process stats; shows whole-GPU load)"), isOn: $item.gpuEngine)
            }
        }
        .padding(.vertical, 6)
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .background(Color.gray.opacity(0.07))
        .cornerRadius(6)
    }
}

private struct FooterRow: View {
    @ObservedObject var footer: FooterDraft
    var onDelete: () -> Void

    var body: some View {
        HStack {
            TextField(moo("名称", "Name"), text: $footer.label).frame(width: 150).textFieldStyle(.roundedBorder)
            TextField(moo("命令", "Command"), text: $footer.command).textFieldStyle(.roundedBorder)
            Toggle(moo("有运行才显示", "Only show while anything runs"), isOn: $footer.showWhenAnyRunning)
            Button { onDelete() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
        }
    }
}

// MARK: - 窗口控制器
final class SettingsWindowController: NSObject {
    private weak var app: App?
    private let model = SettingsModel()
    private var window: NSWindow?
    private var host: NSHostingController<SettingsView>?
    var windowForShot: NSWindow? { window }   // 只读：--settings-shot 离屏渲染用，别的别碰
    var debugZoom: Double { model.uiZoom }    // 诊断：--settings-shot 打印当前缩放
    func debugSetZoom(_ z: Double) { model.uiZoom = z }

    init(app: App) {
        self.app = app
        super.init()
    }

    func show() {
        if window == nil {
            let root = SettingsView(model: model,
                                    onSave: { [weak self] in self?.save() },
                                    onReveal: { [weak self] in self?.reveal() },
                                    onLoadExample: { [weak self] in self?.loadExample() })
            let host = NSHostingController(rootView: root)
            let w = EscClosableWindow(contentViewController: host)
            w.title = moo("MooKeeper 配置", "MooKeeper Settings")
            w.styleMask = [.titled, .closable, .resizable]
            w.setContentSize(NSSize(width: 920, height: 680))   // 与下方 minWidth: 920 对齐，免得开窗后再弹宽
            w.center()
            self.host = host
            self.window = w
        }
        load()   // 每次打开都重读磁盘：避免用上次会话的旧表单覆盖手工改过的 config
        model.refreshNotifStatus()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func load() {
        let path = configPath()
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            model.load(obj)
        }
    }

    private func save() {
        if let err = model.validate() { model.savedNote = err; return }
        let path = configPath()
        var obj = model.toJSON()
        // 保留表单未管理的顶层字段（如 customField、未来自定义），避免整体覆盖丢数据
        if let cur = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let existing = (try? JSONSerialization.jsonObject(with: cur)) as? [String: Any] {
            for (k, v) in existing where obj[k] == nil { obj[k] = v }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: path) {          // 覆盖前备份上一版
            try? FileManager.default.copyItem(atPath: path, toPath: path + ".bak")
        }
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)  // 内含命令，收紧权限
            model.savedNote = moo("已保存并生效 ✓", "Saved & applied ✓")
            app?.reloadConfig()
        } catch {
            model.savedNote = moo("保存失败：\(error.localizedDescription)", "Save failed: \(error.localizedDescription)")
        }
    }

    private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: configPath())])
    }

    private func loadExample() {
        guard let url = exampleConfigURL(),          // 按系统语言选版：中文系统给中文示例，其余给英文
              let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            model.savedNote = moo("未找到内置示例配置", "Bundled example config not found")
            return
        }
        model.load(obj)
        model.savedNote = moo("已载入示例（点「保存并生效」即可试用）", "Example loaded — hit \"Save & Apply\" to try it")
    }
}