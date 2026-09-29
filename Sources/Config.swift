import Foundation

// MooKeeper 配置模块。
// 配置文件：优先 $MOOKEEPER_CONFIG，否则 ~/.config/mookeeper/config.json。
// 没有配置文件时把内置示例（按系统语言中/英选版）落成 config.json 再加载；
// 读取失败/坏 JSON 才回退内置默认值（高亮阈值 85/85/4500-橙，空分组/空底部动作）。

// MARK: - 命令：字符串走 /bin/sh -c，数组走 argv（无 shell）
struct Cmd {
    let shell: String?      // 非空 → /bin/sh -c 执行该字符串
    let argv: [String]      // shell 为空 → 直接用 argv 执行
    init(shell: String) { self.shell = shell; self.argv = [] }
    init(argv: [String]) { self.shell = nil; self.argv = argv }
    var isEmpty: Bool { shell == nil && argv.isEmpty }
    static func fromJSON(_ v: Any?) -> Cmd? {
        if let s = v as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : Cmd(shell: t)
        }
        if let a = v as? [String] {
            let args = a.filter { !$0.isEmpty }.map(expandPath)
            return args.isEmpty ? nil : Cmd(argv: args)
        }
        return nil
    }
}

// MARK: - 状态探测方式
enum Probe: String {
    case port = "port"         // 监听端口（默认，向后兼容）
    case process = "process"   // pgrep -f 匹配进程命令行
    case pidFile = "pidFile"   // PID 文件 + kill -0 判存活
    case check = "check"       // 自定义命令 exit 0 = 运行
    case none = "none"         // 不跟踪（纯按钮，点一下执行）
}

// MARK: - 分组/条目
struct GroupItem {
    let key: String
    let label: String
    let labelOff: String        // 未运行时状态文案（服务「未运行」/ 模型「已卸载」）
    let probe: Probe            // 探测方式（默认 port）
    let port: Int               // probe == .port 时有效
    let process: String?        // probe == .process 时的 pgrep 匹配
    let pidFile: String?        // probe == .pidFile 时的 PID 文件路径
    let checkCmd: Cmd?          // probe == .check 时的检测命令
    let start: Cmd?             // 启动/装载脚本
    let stop: Cmd?              // 停止/卸载脚本
    let precheck: Cmd?          // 启动前门禁（非 0 拒绝启动）
    let requireFreeGB: Double?  // 内置内存门槛：剩余可用不足则拒启（nil = 不设）
    let confirmStop: Bool       // 停止是否二次确认
    let loadable: Bool          // 是否可启动/装载
    let gpuEngine: Bool         // GPU 引擎：llama-server 等按进程统计不到 GPU，负载看整机活跃度
    let url: String?            // 运行中显示「↗ 打开网页」的完整 URL（如 http://localhost:8028），nil = 无
    let soundOnStart: Bool      // 启动命令成功后通知带哞声（启动慢的服务：点完走人，听见哞 = 起好了）
    let startTimeout: TimeInterval
    let stopTimeout: TimeInterval
}

struct Group {
    let title: String
    let items: [GroupItem]
    let exclusive: Bool         // 组内一次只跑一个（启动新条目前自动停旧的；此时不提供「全部启动」）
    let allowStartAll: Bool     // 显示「全部启动」
    let allowStopAll: Bool      // 显示「全部停止」
}

struct FooterAction {
    let label: String
    let cmd: Cmd
    let showWhenAnyRunning: Bool
    let timeout: TimeInterval
}

// MARK: - 高亮阈值
struct Highlights {
    var cpuPercent: Double
    var gpuPercent: Double
    var fanRPM: Int
    var diskWarnPercent: Int   // 磁盘占用 ≥ 此值为「资源不足」橙
    var diskCritPercent: Int   // 磁盘占用 ≥ 此值为「资源告急」红
    var color: String          // orange | red | yellow | blue | purple | green
}

// MARK: - 负载分级阈值（服务实占 CPU%/GPU%/IO KB/s）
struct LoadThresholds {
    var connMod: Int; var connHeavy: Int
    var cpuMod: Double; var cpuHeavy: Double
    var gpuMod: Double; var gpuHeavy: Double
    var ioModKBs: Double; var ioHeavyKBs: Double
}

// MARK: - 应用配置
struct AppConfig {
    var highlights: Highlights
    var topN: Int
    var confirmWindow: TimeInterval
    var groups: [Group]                   // 空 → 菜单显示「尚未配置」提示
    var footer: [FooterAction]
    var load: LoadThresholds
}

func expandPath(_ s: String) -> String { (s as NSString).expandingTildeInPath }

func configCandidates() -> [String] {
    var cs: [String] = []
    if let e = ProcessInfo.processInfo.environment["MOOKEEPER_CONFIG"], !e.isEmpty { cs.append(expandPath(e)) }
    cs.append(expandPath("~/.config/mookeeper/config.json"))
    return cs
}

// 配置写入目标路径（读用 candidates，写用这个）
func configPath() -> String {
    if let e = ProcessInfo.processInfo.environment["MOOKEEPER_CONFIG"], !e.isEmpty { return expandPath(e) }
    return expandPath("~/.config/mookeeper/config.json")
}

// 内置示例选版：中文系统用 config.example.zh.json，其余（含找不到 zh 资源时）用英文基准版
func exampleConfigURL() -> URL? {
    if isZhLocale(), let u = Bundle.main.url(forResource: "config.example.zh", withExtension: "json") { return u }
    return Bundle.main.url(forResource: "config.example", withExtension: "json")
}

// 首次运行 bootstrap：config.json 不存在时，把内置示例（按系统语言选版）落成 config.json 再照常加载——
// 新装开箱即有一个可玩的演示栈，⌘, 的整体覆盖保存也有真实文件可改。
// 已有配置（哪怕是坏 JSON）一律不动，绝不覆盖。
func bootstrapConfigIfNeeded() {
    let path = configPath()
    guard !FileManager.default.fileExists(atPath: path) else { return }
    guard let url = exampleConfigURL(), let data = try? Data(contentsOf: url) else { return }
    let dir = (path as NSString).deletingLastPathComponent
    guard (try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)) != nil else { return }
    guard (try? data.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil else { return }
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)  // 内含命令，收紧权限
}

// MARK: - 硬编参数（2026-10-02 拍板：专家向旋钮不再开放配置，功能照常工作）
// 负载分级阈值、条目/底部动作超时、二次确认窗口——普通用户从不调这些，删配置改常量
enum Hardwired {
    static let startTimeout: TimeInterval = 660
    static let stopTimeout: TimeInterval = 330
    static let footerTimeout: TimeInterval = 960
    static let confirmWindow: TimeInterval = 20
    // 菜单重新展开时 menuNeedsUpdate 的节流窗口：0.5s 内连续开关不重复 rebuild
    // （rebuild 要走一遍全量采样，快速连开只重建第一下；>0.5s 重开就能看到最新状态）
    static let menuRebuildThrottle: TimeInterval = 0.5
    // 「上次动作失败」提醒行的自动消失窗口（2026-10-04 用户拍板 5min→2min）：超时后下一拍重建菜单即消失；
    // 点行手动关闭、或下一次动作成功即时清除，照旧。注意：菜单展开期间不重建条目（坑 17/18），
    // 一直开着菜单超过 TTL 时该行留到关掉重开才消失。
    static let lastErrorTTL: TimeInterval = 120
    // 内存大户 TOP 条数上界（guide §4 对外口径 1~50；加载时默默收顶，不占警告通道）
    static let topNMax = 50
    static let load = LoadThresholds(connMod: 1, connHeavy: 10, cpuMod: 15, cpuHeavy: 70,
                                     gpuMod: 10, gpuHeavy: 50, ioModKBs: 1024, ioHeavyKBs: 10240)
}

func defaultConfig() -> AppConfig {
    return AppConfig(
        highlights: Highlights(cpuPercent: 85, gpuPercent: 85, fanRPM: 4500, diskWarnPercent: 70, diskCritPercent: 90, color: "orange"),
        topN: 6,
        confirmWindow: Hardwired.confirmWindow,
        groups: [],
        footer: [],
        load: Hardwired.load
    )
}

var configLoadWarning: String?

func loadConfig() -> AppConfig {
    var cfg = defaultConfig()
    configLoadWarning = nil
    bootstrapConfigIfNeeded()
    for path in configCandidates() {
        guard FileManager.default.fileExists(atPath: path) else { continue }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            configLoadWarning = moo("配置文件 \(path) 读取失败，已用默认配置",
                                   "can't read config file \(path) — using default config"); continue
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            configLoadWarning = moo("配置文件 \(path) 解析失败（可能 JSON 有误），已用默认配置",
                                    "config file \(path) failed to parse (check the JSON) — using default config"); continue
        }
        let issues = applyConfig(obj, to: &cfg)
        // 加载路径的问题（手写/ AI 生成的 JSON 不经 ⌘, 的 validate()）进 footer 头部 ⚠ 橙字通道。
        // 只报第一条：⚠ 行一行装得下一条（实测 620pt 宽约一条半，多条 joined 会把第二条截半）——
        // 报全不如报准；修完这条重启自然看到下一条。坏条目仍照常加载，不因一处坏弃整份。
        configLoadWarning = issues.first
        break       // 第一个合法文件生效
    }
    return cfg
}

func applyConfig(_ obj: [String: Any], to cfg: inout AppConfig) -> [String] {
    // topN 加载时收顶（guide §4 对外口径 1~50）；越界无害，默默纠正不占警告通道
    if let v = obj["topN"] as? Int, v > 0 { cfg.topN = min(v, Hardwired.topNMax) }

    if let h = obj["highlight"] as? [String: Any] {
        if let v = h["cpuPercent"] as? Double, v >= 0 { cfg.highlights.cpuPercent = v }
        if let v = h["gpuPercent"] as? Double, v >= 0 { cfg.highlights.gpuPercent = v }
        if let v = h["fanRPM"] as? Int, v >= 0 { cfg.highlights.fanRPM = v }
        if let v = h["diskWarnPercent"] as? Int, v >= 0 { cfg.highlights.diskWarnPercent = v }
        if let v = h["diskCritPercent"] as? Int, v >= 0 { cfg.highlights.diskCritPercent = v }
        if let v = h["color"] as? String, !v.isEmpty { cfg.highlights.color = v }
    }
    // load 分级阈值与 confirmWindowSeconds 已硬编（Hardwired），配置里的旧字段直接忽略
    if let gs = obj["groups"] as? [[String: Any]] {
        cfg.groups = gs.compactMap(parseGroup)
    }
    if let fs = obj["footer"] as? [[String: Any]] {
        cfg.footer = fs.compactMap { f -> FooterAction? in
            guard let label = f["label"] as? String, let cmd = Cmd.fromJSON(f["command"]) else { return nil }
            return FooterAction(label: label, cmd: cmd,
                                showWhenAnyRunning: f["showWhenAnyRunning"] as? Bool ?? false,
                                timeout: Hardwired.footerTimeout)
        }
    }
    return validationIssues(for: cfg)
}

/// 加载路径的条目校验。⌘, 保存有 validate() 拦（SettingsUI），但**手写 / AI 生成**的 config.json
/// 绕过表单——port 是重灾区：probe=port 缺 port、或 port 越界，条目永远 ○ 且**没有任何提示可查**。
/// 文案与 SettingsUI.validate 的端口拦**逐字一致**（i18n 词表同一词条，不造新句）。
func validationIssues(for cfg: AppConfig) -> [String] {
    var issues: [String] = []
    for g in cfg.groups {
        for it in g.items where it.probe == .port && !(1...65535).contains(it.port) {
            issues.append(moo("「\(g.title)」里的「\(it.key)」是端口探测，端口要填 1~65535",
                              "\"\(it.key)\" in \"\(g.title)\" uses port probe — set port 1~65535"))
        }
    }
    return issues
}

func parseGroup(_ g: [String: Any]) -> Group? {
    guard let title = g["title"] as? String, !title.isEmpty else { return nil }
    let items = (g["items"] as? [[String: Any]] ?? []).compactMap { it -> GroupItem? in
        guard let key = it["key"] as? String,
              let label = it["label"] as? String else { return nil }
        var probe = Probe.port
        if let p = it["probe"] as? String { probe = Probe(rawValue: p) ?? .port }
        else if it["process"] != nil { probe = .process }
        else if it["pidFile"] != nil { probe = .pidFile }
        else if it["check"] != nil { probe = .check }
        return GroupItem(
            key: key,
            label: label,
            labelOff: it["labelOff"] as? String ?? moo("未运行", "Not Running"),
            probe: probe,
            port: it["port"] as? Int ?? 0,
            process: it["process"] as? String,
            pidFile: it["pidFile"] as? String,
            checkCmd: Cmd.fromJSON(it["check"]),
            start: Cmd.fromJSON(it["start"]),
            stop: Cmd.fromJSON(it["stop"]),
            precheck: Cmd.fromJSON(it["precheck"]),
            requireFreeGB: it["requireFreeGB"] as? Double,
            confirmStop: it["confirmStop"] as? Bool ?? false,
            loadable: it["loadable"] as? Bool ?? true,
            gpuEngine: it["gpuEngine"] as? Bool ?? false,
            url: it["url"] as? String,
            soundOnStart: it["soundOnStart"] as? Bool ?? false,
            startTimeout: Hardwired.startTimeout,
            stopTimeout: Hardwired.stopTimeout
        )
    }
    return Group(
        title: title,
        items: items,
        exclusive: g["exclusive"] as? Bool ?? false,
        allowStartAll: g["allowStartAll"] as? Bool ?? true,
        allowStopAll: g["allowStopAll"] as? Bool ?? true
    )
}