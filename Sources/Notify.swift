import Foundation
import UserNotifications
import AppKit

// MARK: - 品牌声音（跟随系统语言：中文「哞」/ 英文「Moo」）
func isZhLocale() -> Bool {
    (Locale.preferredLanguages.first ?? "en").hasPrefix("zh")
}
func moo(_ zh: String, _ en: String) -> String {
    isZhLocale() ? zh : en
}

// MARK: - 品牌提示音（全部提示音统一用项目里的 Resources/moo.aiff）
let mooSoundName = "moo.aiff"   // 磁盘上的文件名：bundle Contents/Resources 根 + ~/Library/Sounds
let mooSoundRefName = "moo"     // 交给系统的引用名：**必须不带扩展名**！（带 ".aiff" 时 macOS 必回落默认「叮咚」，实测）
private enum MooSoundKeeper { static var keep: NSSound? }  // 播放期间持有，防止短音被释放

/// 找 moo.aiff：bundle 资源 → 裸二进制（诊断口）按可执行文件相对位置找 app 内资源
func mooSoundURL() -> URL? {
    if let u = Bundle.main.url(forResource: "moo", withExtension: "aiff") { return u }
    let dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    for rel in ["../Resources", "../../Resources", "Resources"] {
        let u = dir.appendingPathComponent(rel).appendingPathComponent(mooSoundName)
        if FileManager.default.fileExists(atPath: u.path) { return u }
    }
    return nil
}

/// 直接用 NSSound 播 moo——**只用于手动试音**（点 logo / `--moo`）与裸二进制回落，
/// 通知提示音不走这里（通知音交给系统播，才跟随「专注模式」）。统一在主线程创建并播放。
@discardableResult
func playMooSound() -> Bool {
    guard let url = mooSoundURL(), let s = NSSound(contentsOf: url, byReference: true) else { return false }
    let start = { MooSoundKeeper.keep = s; s.play() }
    if Thread.isMainThread { start() } else { DispatchQueue.main.async(execute: start) }
    return true
}

/// 系统通知音按名解析的搜索路径里，moo.aiff 是否就位（决定用品牌音还是回落系统默认声）。
func systemSoundAvailable() -> Bool {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let dirs = [home.appendingPathComponent("Library/Sounds"),
                URL(fileURLWithPath: "/Library/Sounds")]
    if dirs.contains(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent(mooSoundName).path) }) {
        return true
    }
    return Bundle.main.url(forResource: "moo", withExtension: "aiff") != nil
}

// MARK: - 通知（原生 UNUserNotificationCenter；裸二进制/被拒时回落 osascript）
func requestNotifications() {
    guard Bundle.main.bundleIdentifier != nil else { return }  // 裸二进制无 bundle，UN 会崩
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
}

func osascriptNotify(_ title: String, _ text: String) {
    // AppleScript 引号字符串用**真转义**：复用现成的 asQ（`\`→`\\`、`"`→`\"`，SettingsUI.swift；
    // 实测 osascript 对 `\\`/`\"`/`\n`/`\r` 均正确解释，见 d.md）。
    // 旧写法是「替换法」（`\`→`/`、`"`→`'`）：靠把内容改成另一个样子来堵逃逸，
    // 任何人改动替换对之一就是 AppleScript 注入面——别退回。真换行转成合法的 \n/\r 转义，脚本源码恒单行。
    let esc: (String) -> String = {
        asQ($0)
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
    let script = "display notification \(esc(text)) with title \(esc(title))"
    DispatchQueue.global(qos: .utility).async {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
}

func notify(_ title: String, _ text: String, sound: Bool = false) {
    // 含名字的长句一律掐长（用户 2026-10-03 拍板：通知也要截断——超长名字不能把横幅撑烂）；
    // 标题 60 / 正文 200 字符封顶，超了「…」。所有调用点经这里统一兜底，无需逐个改
    let t = capN(title, Trunc.notifTitleChars)
    let b = capN(text, Trunc.notifBodyChars)
    guard Bundle.main.bundleIdentifier != nil else {
        if sound { playMooSound() }
        osascriptNotify(t, b)
        return
    }
    let center = UNUserNotificationCenter.current()
    let post = {
        let c = UNMutableNotificationContent()
        c.title = t
        c.body = b
        if sound {
            // 尊重 Apple 的通知模型：声音**交给系统播**（跟随「专注模式」，App 自己不出声）。
            // macOS 找得到自定义音的两个硬条件（实测 + StackOverflow 61977828 证实）：
            //   ① 引用名不带扩展名（mooSoundRefName），带 ".aiff" 必回落默认声；
            //   ② 文件在 bundle 的 Contents/Resources **根目录**（不能放 Resources/Sounds 子目录）。
            // 资源缺失才回落系统默认声。
            c.sound = systemSoundAvailable()
                ? UNNotificationSound(named: UNNotificationSoundName(mooSoundRefName))
                : .default
        }
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
    center.getNotificationSettings { s in
        switch s.authorizationStatus {
        case .authorized, .provisional, .ephemeral, .notDetermined:
            post()
        default:
            // 已拒绝：不再回落 osascript（会显示成「脚本编辑器」）；静默丢弃，
            // 授权引导在 ⌘, 设置界面里提供。
            break
        }
    }
}

// 通知权限助手（⌘, 设置界面用）
func notifAuthStatus(_ cb: @escaping (String, Bool) -> Void) {
    UNUserNotificationCenter.current().getNotificationSettings { s in
        let text: String
        switch s.authorizationStatus {
        case .authorized: text = moo("已开启 ✓", "Enabled ✓")
        case .denied: text = moo("已拒绝", "Denied")
        case .notDetermined: text = moo("尚未请求", "Not Requested")
        case .provisional: text = moo("静默投递（临时授权）", "Silently delivered (provisional)")
        case .ephemeral: text = moo("临时授权", "Provisional")
        @unknown default: text = moo("未知", "Unknown")
        }
        cb(text, s.authorizationStatus == .denied)
    }
}
func requestNotifAuth(_ cb: @escaping (Bool) -> Void) {
    guard Bundle.main.bundleIdentifier != nil else { cb(false); return }
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in cb(granted) }
}
func openNotifSystemSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
        NSWorkspace.shared.open(url)
    }
}

// 诊断：打印 bundle id 与通知授权状态（--notif）
func dumpNotifState() {
    let sem = DispatchSemaphore(value: 0)
    UNUserNotificationCenter.current().getNotificationSettings { s in
        let line = "NOTIF bundleID=\(Bundle.main.bundleIdentifier ?? "<nil>") authRaw=\(s.authorizationStatus.rawValue)"
        print(line)
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 6)
}