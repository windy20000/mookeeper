import SwiftUI
import AppKit
import Foundation

// ============ 可爱牛 Logo（逐像素实测的矢量版）============
// 1254×1254 设计坐标系，坐标与配色均取自参考图逐像素测量（手绘 SOP）。
// 绘制规则：自由轮廓（角/斑/耳）=关键点列 → Catmull-Rom 闭合样条（C1 连续、无手拼折角）；
// 规则轮廓 = 超椭圆（头/嘴）/椭圆（眼·内耳·鼻孔）/圆弧描边（微笑）。
// 图层自下而上：耳 → 头 → 斑 → 角（压斑）→ 嘴 → 鼻孔 → 眼 → 微笑。

public struct CowPalette {
    public static let face = Color(red: 252 / 255, green: 250 / 255, blue: 247 / 255)
    public static let pink = Color(red: 252 / 255, green: 186 / 255, blue: 184 / 255)
    public static let darkPink = Color(red: 206 / 255, green: 107 / 255, blue: 109 / 255)
    public static let horn = Color(red: 193 / 255, green: 135 / 255, blue: 100 / 255)
    public static let dark = Color(red: 41 / 255, green: 36 / 255, blue: 44 / 255)
}

/// 1254 设计坐标系里的全部几何数据（参考图实测值）
enum CowGeometry {
    static let canvas: CGFloat = 1254
    /// 左右镜像轴：x' = mirrorX - x
    static let mirrorX: CGFloat = 1246

    // 头：超椭圆（n>2 顶部比正圆扁，贴合参考轮廓）
    static let head = (cx: CGFloat(623), cy: CGFloat(670), ax: CGFloat(339), ay: CGFloat(315), n: CGFloat(2.3))
    // 嘴：更方的超椭圆
    static let muzzle = (cx: CGFloat(622), cy: CGFloat(849), ax: CGFloat(312), ay: CGFloat(130), n: CGFloat(2.6))

    /// 头部超椭圆右缘上纵坐标 y 对应的 x（斑的外缘沿此弧回卷）
    static func headEdgeX(y: CGFloat) -> CGFloat {
        let u = abs(y - head.cy) / head.ay
        guard u < 1 else { return head.cx }
        return head.cx + head.ax * pow(1 - pow(u, head.n), 1 / head.n)
    }

    // 左角闭合轮廓：内缘自基部上行 → 尖端 → 外缘下行回基部。
    // 弯锥形：宽度集中在基部（y≈375 最宽 134px）、上半尖细，内缘最鼓点切线竖直。
    static let hornOutline: [(CGFloat, CGFloat)] = [
        (383, 447), (391, 437), (398, 424), (409, 415), (421, 408),
        (440, 398), (458, 388), (470, 381), (488, 370),
        (473, 363), (464, 353), (455, 345), (447, 338), (440, 330),
        (433, 321), (428, 311), (424, 300), (422, 288), (418, 277), (410, 268), (402, 264),
        (393, 267), (383, 274), (371, 285), (361, 299), (354, 315), (349, 333),
        (347, 352), (347, 372), (349, 392), (354, 411), (362, 427), (372, 439),
    ]

    // 深灰斑：内缘 S 曲线自头顶中线扫到右眼下方（下段点列）
    static let patchInnerEdge: [(CGFloat, CGFloat)] = [
        (664, 360), (657, 392), (656, 425), (660, 458), (668, 490), (679, 518),
        (694, 543), (713, 562), (736, 576), (762, 585), (789, 592), (813, 603),
        (832, 621), (845, 643), (854, 664), (866, 682), (884, 694), (908, 700),
        (934, 702), (958, 702),
    ]

    /// 斑闭合轮廓 = 内缘点列 + 头缘弧采样点（外缘贴头部轮廓）
    static func patchOutline() -> [(CGFloat, CGFloat)] {
        var pts = patchInnerEdge
        var y: CGFloat = 692
        while y >= 362 {
            pts.append((headEdgeX(y: y), y))
            y -= 4
        }
        return pts
    }

    // 左耳闭合轮廓（非纯椭圆：上缘鼓、下缘向内收；内缘大半没入头后）
    static let earOutline: [(CGFloat, CGFloat)] = [
        (230, 416), (299, 430), (339, 445), (368, 462), (358, 510), (330, 560),
        (310, 581), (275, 597), (215, 589), (165, 555), (140, 515), (129, 475),
        (140, 447), (180, 428),
    ]

    // 眼（椭圆）+ 高光（小圆，偏面中侧上方）
    static let eyeL = (cx: CGFloat(470), cy: CGFloat(655), ax: CGFloat(40.5), ay: CGFloat(48))
    static let eyeR = (cx: CGFloat(778), cy: CGFloat(654), ax: CGFloat(40.5), ay: CGFloat(48))
    static let highlightR: CGFloat = CGFloat(11.5)
    static let highlightL = (cx: CGFloat(482), cy: CGFloat(634), r: highlightR)
    static let highlightROff = (cx: CGFloat(767), cy: CGFloat(633), r: highlightR)
    // 第二颗小高光（双眼高光 → 更精神的「眼神光」）
    static let highlight2R: CGFloat = CGFloat(6.5)
    static let highlight2L = (cx: CGFloat(494), cy: CGFloat(647), r: highlight2R)
    static let highlight2ROff = (cx: CGFloat(756), cy: CGFloat(646), r: highlight2R)

    // 鼻孔（椭圆，微微外倾）
    static let nostrilL = (cx: CGFloat(490), cy: CGFloat(820), ax: CGFloat(27), ay: CGFloat(35), deg: CGFloat(-8))
    static let nostrilR = (cx: CGFloat(759), cy: CGFloat(819), ax: CGFloat(27), ay: CGFloat(35), deg: CGFloat(8))
    static let innerEarL = (cx: CGFloat(257), cy: CGFloat(517), ax: CGFloat(78.5), ay: CGFloat(52.5))
    static let innerEarR = (cx: CGFloat(989), cy: CGFloat(517), ax: CGFloat(78.5), ay: CGFloat(52.5))

    // 微笑：圆弧描边（下弧段）
    static let smile = (cx: CGFloat(624), cy: CGFloat(827), r: CGFloat(73),
                        a0: CGFloat(39.5), a1: CGFloat(140.5), width: CGFloat(32))
}

public enum CowPartKind: Sendable {
    case hornL, hornR
    case earL, earR, innerEarL, innerEarR
    case head, patch, muzzle
    case nostrilL, nostrilR
    case eyeL, eyeR, highlightL, highlightR, highlightL2, highlightR2
    case smile
}

public struct CowPart: Shape {
    let kind: CowPartKind
    var eyeScale: CGFloat = 1

    public init(_ kind: CowPartKind, eyeScale: CGFloat = 1) {
        self.kind = kind
        self.eyeScale = eyeScale
    }

    public func path(in rect: CGRect) -> Path {
        let painter = Painter(rect: rect)
        switch kind {
        case .hornL: return painter.spline(CowGeometry.hornOutline)
        case .hornR: return painter.spline(CowGeometry.hornOutline, mirror: true)
        case .earL: return painter.spline(CowGeometry.earOutline)
        case .earR: return painter.spline(CowGeometry.earOutline, mirror: true)
        case .head: return painter.superellipse(CowGeometry.head)
        case .patch: return painter.spline(CowGeometry.patchOutline())
        case .muzzle: return painter.superellipse(CowGeometry.muzzle)
        case .innerEarL: return painter.ellipse(CowGeometry.innerEarL)
        case .innerEarR: return painter.ellipse(CowGeometry.innerEarR)
        case .nostrilL: return painter.ellipse(CowGeometry.nostrilL.cx, CowGeometry.nostrilL.cy,
                                               CowGeometry.nostrilL.ax, CowGeometry.nostrilL.ay,
                                               degrees: CowGeometry.nostrilL.deg)
        case .nostrilR: return painter.ellipse(CowGeometry.nostrilR.cx, CowGeometry.nostrilR.cy,
                                               CowGeometry.nostrilR.ax, CowGeometry.nostrilR.ay,
                                               degrees: CowGeometry.nostrilR.deg)
        case .eyeL:
            let k = eyeScale
            return painter.ellipse(CowGeometry.eyeL.cx, CowGeometry.eyeL.cy,
                                   CowGeometry.eyeL.ax * k, CowGeometry.eyeL.ay * k)
        case .eyeR:
            let k = eyeScale
            return painter.ellipse(CowGeometry.eyeR.cx, CowGeometry.eyeR.cy,
                                   CowGeometry.eyeR.ax * k, CowGeometry.eyeR.ay * k)
        case .highlightL:
            let k = eyeScale
            let dx = CowGeometry.highlightL.cx - CowGeometry.eyeL.cx
            let dy = CowGeometry.highlightL.cy - CowGeometry.eyeL.cy
            return painter.circle(CowGeometry.eyeL.cx + dx * k, CowGeometry.eyeL.cy + dy * k,
                                  CowGeometry.highlightL.r * k)
        case .highlightR:
            let k = eyeScale
            let dx = CowGeometry.highlightROff.cx - CowGeometry.eyeR.cx
            let dy = CowGeometry.highlightROff.cy - CowGeometry.eyeR.cy
            return painter.circle(CowGeometry.eyeR.cx + dx * k, CowGeometry.eyeR.cy + dy * k,
                                  CowGeometry.highlightROff.r * k)
        case .highlightL2:
            let k = eyeScale
            let dx = CowGeometry.highlight2L.cx - CowGeometry.eyeL.cx
            let dy = CowGeometry.highlight2L.cy - CowGeometry.eyeL.cy
            return painter.circle(CowGeometry.eyeL.cx + dx * k, CowGeometry.eyeL.cy + dy * k,
                                  CowGeometry.highlight2L.r * k)
        case .highlightR2:
            let k = eyeScale
            let dx = CowGeometry.highlight2ROff.cx - CowGeometry.eyeR.cx
            let dy = CowGeometry.highlight2ROff.cy - CowGeometry.eyeR.cy
            return painter.circle(CowGeometry.eyeR.cx + dx * k, CowGeometry.eyeR.cy + dy * k,
                                  CowGeometry.highlight2ROff.r * k)
        case .smile: return painter.arc(CowGeometry.smile.cx, CowGeometry.smile.cy, CowGeometry.smile.r,
                                        from: CowGeometry.smile.a0, to: CowGeometry.smile.a1)
        }
    }

    /// 设计坐标 → 画布坐标的统一换算与路径构建
    struct Painter {
        let rect: CGRect
        var s: CGFloat { min(rect.width, rect.height) / CowGeometry.canvas }

        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * s, y: rect.minY + y * s)
        }

        /// Catmull-Rom 闭合样条：过全部点列，切线由相邻点差分决定（C1 连续）
        func spline(_ pts: [(CGFloat, CGFloat)], mirror: Bool = false) -> Path {
            let P = pts.map { pt(mirror ? CowGeometry.mirrorX - $0.0 : $0.0, $0.1) }
            var p = Path()
            let n = P.count
            guard n > 2 else { return p }
            p.move(to: P[0])
            for i in 0..<n {
                let p0 = P[(i - 1 + n) % n], p1 = P[i], p2 = P[(i + 1) % n], p3 = P[(i + 2) % n]
                let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
                let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
                p.addCurve(to: p2, control1: c1, control2: c2)
            }
            p.closeSubpath()
            return p
        }

        func superellipse(_ e: (cx: CGFloat, cy: CGFloat, ax: CGFloat, ay: CGFloat, n: CGFloat)) -> Path {
            var p = Path()
            let steps = 160
            for i in 0...steps {
                let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
                let c = cos(t), sn = sin(t)
                let x = e.cx + e.ax * (c < 0 ? -1 : 1) * pow(abs(c), 2 / e.n)
                let y = e.cy + e.ay * (sn < 0 ? -1 : 1) * pow(abs(sn), 2 / e.n)
                if i == 0 { p.move(to: pt(x, y)) } else { p.addLine(to: pt(x, y)) }
            }
            p.closeSubpath()
            return p
        }

        func ellipse(_ e: (cx: CGFloat, cy: CGFloat, ax: CGFloat, ay: CGFloat)) -> Path {
            ellipse(e.cx, e.cy, e.ax, e.ay)
        }

        func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ ax: CGFloat, _ ay: CGFloat, degrees: CGFloat = 0) -> Path {
            var e = Path()
            e.addEllipse(in: CGRect(x: -ax * s, y: -ay * s, width: ax * 2 * s, height: ay * 2 * s))
            if degrees != 0 {
                e = e.applying(CGAffineTransform(rotationAngle: degrees * .pi / 180))
            }
            e = e.applying(CGAffineTransform(translationX: rect.minX + cx * s, y: rect.minY + cy * s))
            return e
        }

        func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> Path {
            ellipse(cx, cy, r, r)
        }

        func arc(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, from: CGFloat, to: CGFloat) -> Path {
            var p = Path()
            let c = pt(cx, cy)
            p.move(to: CGPoint(x: c.x + r * s * cos(from * .pi / 180),
                               y: c.y + r * s * sin(from * .pi / 180)))
            p.addArc(center: c, radius: r * s,
                     startAngle: .degrees(from), endAngle: .degrees(to), clockwise: false)
            return p
        }
    }
}

/// 牛的整套配色 + 可选外圈描边（rim），用于便捷地做「白天/晚上/暗夜」等多个变体。
public struct CowStyle {
    public var face: Color
    public var dark: Color
    public var pink: Color
    public var darkPink: Color
    public var horn: Color
    public var highlight: Color
    public var rim: Bool
    public var rimColor: Color
    public var rimWidth: CGFloat   // 相对 size 的比例，lineWidth = size * rimWidth
    public var eyeScale: CGFloat       // 眼睛放大系数（>1 更精神）
    public var doubleHighlight: Bool   // 双眼高光（眼神光更足）

    public init(face: Color, dark: Color, pink: Color, darkPink: Color, horn: Color,
                highlight: Color, rim: Bool = false, rimColor: Color = .black,
                rimWidth: CGFloat = 0.014, eyeScale: CGFloat = 1.0, doubleHighlight: Bool = false) {
        self.face = face; self.dark = dark; self.pink = pink; self.darkPink = darkPink
        self.horn = horn; self.highlight = highlight; self.rim = rim
        self.rimColor = rimColor; self.rimWidth = rimWidth
        self.eyeScale = eyeScale; self.doubleHighlight = doubleHighlight
    }

    public static let standard = CowStyle(
        face: CowPalette.face, dark: CowPalette.dark, pink: CowPalette.pink,
        darkPink: CowPalette.darkPink, horn: CowPalette.horn, highlight: .white)

    public static let lightFix = CowStyle(
        face: Color(red: 244 / 255, green: 236 / 255, blue: 225 / 255),   // 奶油脸 #F4ECE1
        dark: CowPalette.dark, pink: CowPalette.pink, darkPink: CowPalette.darkPink, horn: CowPalette.horn,
        highlight: .white, rim: true, rimColor: CowPalette.dark, rimWidth: 0.014)

    public static let darkNight = CowStyle(
        face: Color(red: 236 / 255, green: 242 / 255, blue: 249 / 255),   // 月白脸 #ECF2F9
        dark: Color(red: 56 / 255, green: 50 / 255, blue: 64 / 255),      // 提亮的炭 #383240
        pink: CowPalette.pink, darkPink: CowPalette.darkPink, horn: CowPalette.horn,
        highlight: .white, rim: true, rimColor: .white, rimWidth: 0.016)

    public static let naiveSwap = CowStyle(
        face: CowPalette.dark, dark: CowPalette.face,                     // 纯黑白对调 + 原眼（对照）
        pink: CowPalette.pink, darkPink: CowPalette.darkPink, horn: CowPalette.horn,
        highlight: CowPalette.dark, rim: false)

    public static let nightSwapAwake = CowStyle(
        face: CowPalette.dark, dark: CowPalette.face,                     // 纯黑白对调 + 精神眼
        pink: CowPalette.pink, darkPink: CowPalette.darkPink, horn: CowPalette.horn,
        highlight: CowPalette.dark, rim: false, eyeScale: 1.18, doubleHighlight: true)

    public static let nightSwapAwakeBig = CowStyle(
        face: CowPalette.dark, dark: CowPalette.face,                     // 纯黑白对调 + 更大眼
        pink: CowPalette.pink, darkPink: CowPalette.darkPink, horn: CowPalette.horn,
        highlight: CowPalette.dark, rim: false, eyeScale: 1.32, doubleHighlight: true)
}

public struct CowLogo: View {
    public var size: CGFloat = 100
    public var style: CowStyle = .standard

    public init(size: CGFloat = 100, style: CowStyle = .standard) {
        self.size = size
        self.style = style
    }

    private var rimWidth: CGFloat { size * style.rimWidth }

    public var body: some View {
        ZStack {
            // 描边先画在耳/头填充之下，填充会盖掉描边内侧一半，只留外缘 → 干净 rim
            if style.rim {
                CowPart(.earL).stroke(style.rimColor, style: StrokeStyle(lineWidth: rimWidth, lineJoin: .round))
                CowPart(.earR).stroke(style.rimColor, style: StrokeStyle(lineWidth: rimWidth, lineJoin: .round))
                CowPart(.head).stroke(style.rimColor, style: StrokeStyle(lineWidth: rimWidth, lineJoin: .round))
            }
            CowPart(.earL).fill(style.dark)
            CowPart(.earR).fill(style.dark)
            CowPart(.innerEarL).fill(style.pink)
            CowPart(.innerEarR).fill(style.pink)
            CowPart(.head).fill(style.face)
            CowPart(.patch).fill(style.dark)
            // 角压在斑块之上（参考图右角基部盖住深斑），角身插进头顶
            CowPart(.hornL).fill(style.horn)
            CowPart(.hornR).fill(style.horn)
            CowPart(.muzzle).fill(style.pink)
            CowPart(.nostrilL).fill(style.darkPink)
            CowPart(.nostrilR).fill(style.darkPink)
            CowPart(.eyeL, eyeScale: style.eyeScale).fill(style.dark)
            CowPart(.eyeR, eyeScale: style.eyeScale).fill(style.dark)
            CowPart(.highlightL, eyeScale: style.eyeScale).fill(style.highlight)
            CowPart(.highlightR, eyeScale: style.eyeScale).fill(style.highlight)
            if style.doubleHighlight {
                CowPart(.highlightL2, eyeScale: style.eyeScale).fill(style.highlight)
                CowPart(.highlightR2, eyeScale: style.eyeScale).fill(style.highlight)
            }
            CowPart(.smile)
                .stroke(style.dark,
                        style: StrokeStyle(lineWidth: size * CowGeometry.smile.width / CowGeometry.canvas,
                                           lineCap: .round))
        }
        .frame(width: size, height: size)
    }
}

/// 单只牛 + 底色的徽章（预览用）
struct CowBadge: View {
    let tile: Color
    let style: CowStyle
    let size: CGFloat
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 58 / 256, style: .continuous)
                .fill(tile)
            CowLogo(size: size, style: style)
        }
        .frame(width: size, height: size)
    }
}

/// 对比预览图：现状两版 + 建议两版 + 纯黑白对调（反面例子）
struct PreviewSheet: View {
    let size: CGFloat
    var body: some View {
        let light = Color(red: 0.988, green: 0.988, blue: 0.988)
        let dark = Color(red: 0.165, green: 0.161, blue: 0.208)
        VStack(spacing: 44) {
            HStack(alignment: .top, spacing: 40) {
                cell("现在 · 白天\n（脸 ≈ 底，轮廓糊）", CowBadge(tile: light, style: .standard, size: size))
                cell("现在 · 晚上\n（其实已经清晰）", CowBadge(tile: dark, style: .standard, size: size))
            }
            HStack(alignment: .top, spacing: 40) {
                cell("建议 · 白天\n奶油脸 + 深描边", CowBadge(tile: light, style: .lightFix, size: size))
                cell("建议 · 晚上\n月白脸 + 浅 rim 光", CowBadge(tile: dark, style: .darkNight, size: size))
                cell("❌ 纯黑白对调\n脸融进深底", CowBadge(tile: dark, style: .naiveSwap, size: size))
            }
        }
        .padding(56)
        .background(Color(red: 0.14, green: 0.14, blue: 0.18))
    }

    @ViewBuilder
    private func cell(_ t: String, _ b: CowBadge) -> some View {
        VStack(spacing: 14) {
            b
            Text(t)
                .font(.system(size: 20, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundColor(Color(red: 0.86, green: 0.86, blue: 0.90))
        }
        .frame(width: size)
    }
}

/// 夜间版定向对比：纯黑白对调（已确认方向）+ 眼神光改进选项
struct NightSheet: View {
    let size: CGFloat
    var body: some View {
        let dark = Color(red: 0.165, green: 0.161, blue: 0.208)
        HStack(alignment: .top, spacing: 40) {
            cell("纯黑白对调 · 原眼\n（有点呆 / 困）", CowBadge(tile: dark, style: .naiveSwap, size: size))
            cell("黑白对调 · 大眼 + 双高光", CowBadge(tile: dark, style: .nightSwapAwake, size: size))
            cell("黑白对调 · 更大眼 + 双高光", CowBadge(tile: dark, style: .nightSwapAwakeBig, size: size))
        }
        .padding(56)
        .background(Color(red: 0.14, green: 0.14, blue: 0.18))
    }

    @ViewBuilder
    private func cell(_ t: String, _ b: CowBadge) -> some View {
        VStack(spacing: 14) {
            b
            Text(t)
                .font(.system(size: 20, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundColor(Color(red: 0.86, green: 0.86, blue: 0.90))
        }
        .frame(width: size)
    }
}

// ============ 渲染 PNG ============
// 用法: make_icon <out.png> [plain|dark|light|menu-light|menu-dark]
//   plain(默认) = 透明底贴纸（定稿，App 主图标）；
//   dark = 深炭 tile 变体（设计稿 Dark，#2A2935）；
//   light = 白 tile 变体（设计稿 macOS Dock 示例，#FCFCFC）。
//   tile 均为 Apple 标准格 824×824 r185；
//   menu-light / menu-dark = 菜单里的「看门牛」小徽章（256×256），跟随系统白天/晚上切换。
// 2026-10-04 改：① menu-* 不再画圆角底色（透明底，只剩牛）；② 各处牛都放大到「墨迹正好
// 填满画布宽」——菜单/贴纸填 PNG 画布宽，tile 变体填 824 tile 宽（填 1024 外框会溢出圆角格）。

/// 牛墨迹在设计坐标里的水平宽度（左右最外缘＝耳尖；头/嘴/角一并纳入，几何改动也不会漏算）
let cowInkWidth: CGFloat = {
    let mirror = CowGeometry.mirrorX
    var xs: [CGFloat] = []
    func add(_ x: CGFloat) { xs.append(x); xs.append(mirror - x) }
    for (x, _) in CowGeometry.earOutline { add(x) }
    for (x, _) in CowGeometry.hornOutline { add(x) }
    xs.append(CowGeometry.head.cx - CowGeometry.head.ax)
    xs.append(CowGeometry.muzzle.cx - CowGeometry.muzzle.ax)
    return (xs.max() ?? CowGeometry.canvas) - (xs.min() ?? 0)
}()

/// 「牛墨迹正好填满 canvas 宽」对应的 CowLogo 尺寸：把设计画布自带的左右白边一并放大抵消
/// （设计画布 1254 里耳尖只占 988，故 size = canvas × 1254/988 ≈ 1.269×canvas）。不裁牛。
func cowFillSize(_ canvas: CGFloat) -> CGFloat { canvas * CowGeometry.canvas / cowInkWidth }

let args = CommandLine.arguments
let outPath = args.count > 1 ? args[1] : "build/AppIcon-1024.png"
let variant = args.count > 2 ? args[2] : "plain"

@MainActor
func render(_ content: some View, to path: String) {
    let renderer = ImageRenderer(content: content)
    renderer.scale = 1.0

    guard let cg = renderer.cgImage else { fatalError("render failed") }
    let rep = NSBitmapImageRep(cgImage: cg)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("png encode failed")
    }
    try! png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

MainActor.assumeIsolated {
    switch variant {
    case "dark":
        render(ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(Color(red: 0.165, green: 0.161, blue: 0.208))   // #2A2935
                .frame(width: 824, height: 824)
            CowLogo(size: cowFillSize(824))          // 填满 824 tile 宽
        }
        .frame(width: 1024, height: 1024), to: outPath)
    case "light":
        render(ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(Color(red: 0.988, green: 0.988, blue: 0.988))   // #FCFCFC
                .frame(width: 824, height: 824)
            CowLogo(size: cowFillSize(824))          // 填满 824 tile 宽
        }
        .frame(width: 1024, height: 1024), to: outPath)
    case "menu-light":
        // 透明底（2026-10-04）：不再画圆角贴纸，只剩牛；牛墨迹正好填满 256 画布宽
        render(ZStack { CowLogo(size: cowFillSize(256)) }
        .frame(width: 256, height: 256), to: outPath)
    case "menu-dark":
        // 透明底 + 黑白对调（脸深、斑/角/眼亮）——配色与几何保持不变
        render(ZStack { CowLogo(size: cowFillSize(256), style: .naiveSwap) }
        .frame(width: 256, height: 256), to: outPath)
    case "menu-light-fix":
        render(ZStack {
            RoundedRectangle(cornerRadius: 58, style: .continuous)
                .fill(Color(red: 0.988, green: 0.988, blue: 0.988))
                .frame(width: 256, height: 256)
            CowLogo(size: 256, style: .lightFix)
        }
        .frame(width: 256, height: 256), to: outPath)
    case "menu-dark-night":
        render(ZStack {
            RoundedRectangle(cornerRadius: 58, style: .continuous)
                .fill(Color(red: 0.165, green: 0.161, blue: 0.208))
                .frame(width: 256, height: 256)
            CowLogo(size: 256, style: .darkNight)
        }
        .frame(width: 256, height: 256), to: outPath)
    case "menu-dark-swap":
        render(ZStack {
            RoundedRectangle(cornerRadius: 58, style: .continuous)
                .fill(Color(red: 0.165, green: 0.161, blue: 0.208))
                .frame(width: 256, height: 256)
            CowLogo(size: 256, style: .naiveSwap)
        }
        .frame(width: 256, height: 256), to: outPath)
    case "menu-dark-swap-awake":
        render(ZStack {
            RoundedRectangle(cornerRadius: 58, style: .continuous)
                .fill(Color(red: 0.165, green: 0.161, blue: 0.208))
                .frame(width: 256, height: 256)
            CowLogo(size: 256, style: .nightSwapAwake)
        }
        .frame(width: 256, height: 256), to: outPath)
    case "menu-dark-swap-awakebig":
        render(ZStack {
            RoundedRectangle(cornerRadius: 58, style: .continuous)
                .fill(Color(red: 0.165, green: 0.161, blue: 0.208))
                .frame(width: 256, height: 256)
            CowLogo(size: 256, style: .nightSwapAwakeBig)
        }
        .frame(width: 256, height: 256), to: outPath)
    case "preview-night":
        render(NightSheet(size: 300), to: outPath)
    case "preview":
        render(PreviewSheet(size: 300), to: outPath)
    default:   // plain：透明底贴纸（App 主图标）；CowLogo 比画布大会溢出，靠 .frame 裁回 1024 画布
        render(ZStack { CowLogo(size: cowFillSize(1024)) }
        .frame(width: 1024, height: 1024), to: outPath)
    }
}