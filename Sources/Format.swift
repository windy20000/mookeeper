import AppKit
import Foundation

// MARK: - 格式化
func fmtGB(_ b: UInt64) -> String { String(format: "%.1fG", Double(b) / 1_073_741_824) }
func fmtMem(_ rssKB: Int) -> String {
    let b = Double(rssKB) * 1024
    return b >= 1_073_741_824 ? String(format: "%.2fG", b / 1_073_741_824) : String(format: "%.0fM", b / 1_048_576)
}
func fmtSwap(_ mb: Int) -> String { mb >= 1024 ? String(format: "%.1fG", Double(mb) / 1024) : "\(mb)M" }
func fmtIO(_ kb: Double) -> String { kb >= 1024 ? String(format: "%.1fM/s", kb / 1024) : String(format: "%.0fK/s", kb) }

// 纯 ASCII 定宽（内存大户进程名）
func pad(_ s: String, _ width: Int, right: Bool = false) -> String {
    let n = s.count
    if n >= width { return String(s.prefix(width)) }
    let p = String(repeating: " ", count: width - n)
    return right ? p + s : s + p
}

// 等宽列对齐：按实测像素宽度补空格（中英混排才真正对齐；标记统一 ●/○，因 emoji ✅ 会撑宽）
let monoFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
let monoFontB = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)   // 加粗等宽：与常规同字宽，列对齐不受影响
let monoSpace = (" " as NSString).size(withAttributes: [.font: monoFont]).width
func monoWidth(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: [.font: monoFont]).width }
func padPx(_ s: String, _ target: CGFloat) -> String {
    let n = Int(((target - monoWidth(s)) / monoSpace).rounded())
    return n > 0 ? s + String(repeating: " ", count: n) : s
}
// 超宽截断：按实测像素宽度砍尾加「…」（中英混排用，菜单列宽固定时防长名字把菜单撑爆）
func truncPx(_ s: String, _ maxPx: CGFloat) -> String {
    guard monoWidth(s) > maxPx else { return s }
    let ell = monoWidth("…")
    var res = ""
    for ch in s {
        let next = res + String(ch)
        guard monoWidth(next) + ell <= maxPx else { break }
        res = next
    }
    return res.isEmpty ? "…" : res + "…"
}
// 指定字体版：非等宽行（如菜单忙碌提示）用，同样按实测像素砍尾加「…」
func truncPx(_ s: String, _ maxPx: CGFloat, font: NSFont) -> String {
    func w(_ t: String) -> CGFloat { (t as NSString).size(withAttributes: [.font: font]).width }
    guard w(s) > maxPx else { return s }
    let ell = w("…")
    var res = ""
    for ch in s {
        let next = res + String(ch)
        guard w(next) + ell <= maxPx else { break }
        res = next
    }
    return res.isEmpty ? "…" : res + "…"
}
// 按字符数截断（通知标题/正文、弹窗单行等非等宽文案用）
func capN(_ s: String, _ n: Int) -> String {
    s.count <= n ? s : String(s.prefix(n)) + "…"
}
// —— 全局截断参数：所有带名字显示位的截断旋钮集中在这里，调整只改这一处 ——
// 菜单列用等宽 11pt 实测像素；非列文案（通知正文/菜单信息行/弹窗）用 13pt 菜单字体实测像素；
// 通知标题/正文和弹窗按字符数。各处一律从这里取，不写散落魔法数字
enum Trunc {
    static let nameColPx: CGFloat = 130     // 菜单名称列宽（超长「…」）
    static var probeColPx: CGFloat { isZhLocale() ? 110 : 130 }
    // ↑ 英文探测词（· check command / · on demand 等）比中文长（契约 §7 第 1 条），列宽按语言档；
    //   验收走 --dump/--menu-shot 像素复验列对齐
    static let labelOffPx: CGFloat = 160    // 菜单尾列（「未运行/已卸载」）上限
    static let menuRightPx: CGFloat = 600   // 菜单内容右缘：状态词/数值列右对齐目标（画布 620 − 留白）
    static let nameBriefPx: CGFloat = 150   // 名字嵌非列文案的统一掐宽（13pt 菜单字体）
    static let settingsSidebarPx: CGFloat = 210          // ⌘, 设置侧栏宽（界面最窄结构元素）
    // 底部动作名称预算 = 主界面（菜单）最窄基准宽 480 × 90%（用户 2026-10-03 拍板）：
    // 名字是该行唯一列、不用截太多，超长仍「…」兜底
    static let footerNamePx: CGFloat = 432
    static let notifTitleChars = 60         // 通知标题字符上限
    static let notifBodyChars = 200         // 通知正文字符上限
    static let alertNameChars = 40          // 弹窗（如删除分组确认）里的名字字符上限
}

// 名字嵌入非列文案（通知正文/菜单信息行/弹窗）前统一掐到 Trunc.nameBriefPx
// 用户硬要求：任何带名字的地方，名字本身都要截
func nameBrief(_ s: String) -> String {
    truncPx(s, Trunc.nameBriefPx, font: NSFont.menuFont(ofSize: 13))
}

// 网络速率：KB/s 入参，按量级转 B/KB/MB
func fmtRate(_ kb: Double) -> String {
    if kb >= 1024 { return String(format: "%.1f MB/s", kb / 1024) }
    if kb >= 1 { return String(format: "%.0f KB/s", kb) }
    return String(format: "%.0f B/s", kb * 1024)
}

// 已值守时长：2d 18h / 18h 32m / 32m / <1m —— 不带秒（视觉干净）；「还在干活」由头图围栏进度条表现
func fmtUptime(_ seconds: TimeInterval) -> String {
    let m = max(0, Int(seconds)) / 60
    guard m > 0 else { return "<1m" }
    let d = m / 1440, h = (m % 1440) / 60, mm = m % 60
    var parts: [String] = []
    if d > 0 { parts.append("\(d)d") }
    if h > 0 { parts.append("\(h)h") }
    if mm > 0 || parts.isEmpty { parts.append("\(mm)m") }   // 整点不带 0m（2d 18h / 1h）
    return parts.joined(separator: " ")
}