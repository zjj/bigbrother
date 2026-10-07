import AppKit

/// 菜单栏眼睛图标的生成。
///
/// 为什么不用 `NSStatusBarButton.contentTintColor`:
/// 那个属性作用在**模板图(template image)**上时,菜单栏会用自己的明暗主题
/// 覆盖 tint,结果是颜色根本不生效。可靠的做法是自己合成一张
/// **非模板**的彩色位图交给状态栏。
enum IconFactory {

    /// 威胁等级 → 颜色。返回 nil 表示不染色(跟随菜单栏明暗主题)。
    static func nsColor(for level: Int) -> NSColor? { nsColor(forLevel: Double(level)) }

    /// 连续等级 → 插值颜色,用于淡出。
    ///
    ///   2.0 灰 → 3.0 黄 → 4.0 橙 → 5.0 红
    ///
    /// ≤ 2.0 返回 nil(模板图,跟随菜单栏主题)。
    static func nsColor(forLevel level: Double) -> NSColor? {
        guard level > 2.0 else { return nil }
        let stops: [(Double, Double, Double, Double)] = [
            (2.0, 0.55, 0.55, 0.55),   // 灰
            (3.0, 1.00, 0.83, 0.00),   // 黄
            (4.0, 1.00, 0.62, 0.20),   // 橙
            (5.0, 1.00, 0.32, 0.30),   // 红
        ]
        let l = min(max(level, 2.0), 5.0)
        for i in 0..<(stops.count - 1) {
            let a = stops[i], b = stops[i + 1]
            if l <= b.0 {
                let t = (l - a.0) / (b.0 - a.0)
                return NSColor(srgbRed: a.1 + (b.1 - a.1) * t,
                               green:   a.2 + (b.2 - a.2) * t,
                               blue:    a.3 + (b.3 - a.3) * t,
                               alpha:   1)
            }
        }
        return NSColor(srgbRed: 1, green: 0.32, blue: 0.30, alpha: 1)
    }

    static func colorName(for level: Int) -> String {
        switch level {
        case 5: return "红色 · 严重"
        case 4: return "橙色 · 高"
        case 3: return "黄色 · 中"
        case 2: return "常色 · 低"
        default: return "常色"
        }
    }

    /// 生成菜单栏图标。
    ///
    /// - Parameters:
    ///   - stopped: 采集已中断 → `eye.slash`,固定红色
    ///   - level: 当前威胁等级(Int 或 Double);≤2 时不染色
    static func eye(stopped: Bool, level: Int, pointSize: CGFloat = 13.5) -> NSImage? {
        eye(stopped: stopped, level: Double(level), pointSize: pointSize)
    }

    static func eye(stopped: Bool, level: Double, pointSize: CGFloat = 13.5) -> NSImage? {
        let symbolName = stopped ? "eye.slash" : "eye"
        guard let base = NSImage(systemSymbolName: symbolName,
                                 accessibilityDescription: "BigBrother") else { return nil }

        let tint: NSColor? = stopped ? .systemRed : nsColor(forLevel: level)

        // 无威胁:保持模板图,自动适配菜单栏明暗主题
        guard let tint else {
            base.isTemplate = true
            return base
        }

        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        guard let sym = base.withSymbolConfiguration(cfg) else {
            base.isTemplate = true
            return base
        }

        let size = sym.size
        let out = NSImage(size: size, flipped: false) { rect in
            sym.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceAtop)      // 只在字形像素上着色,保留抗锯齿边缘
            return true
        }
        out.isTemplate = false                 // 关键:非模板,菜单栏才不会再覆盖颜色
        out.accessibilityDescription = "BigBrother — \(colorName(for: Int(level.rounded())))"
        return out
    }

    // MARK: - 自检用

    /// 取图像中「最不透明且最饱和」的像素,用于验证颜色确实被写进去了。
    ///
    /// 直接取中心点不可靠 —— SF Symbol 的字形不一定正好落在几何中心。
    static func dominantPixel(_ image: NSImage) -> (r: Int, g: Int, b: Int, a: Int)? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return nil }

        var best: (r: Int, g: Int, b: Int, a: Int) = (0, 0, 0, 0)
        var bestScore = -1
        let step = max(1, rep.pixelsWide / 48)
        for y in stride(from: 0, to: rep.pixelsHigh, by: step) {
            for x in stride(from: 0, to: rep.pixelsWide, by: step) {
                guard let raw = rep.colorAt(x: x, y: y) else { continue }
                // 目录色需要先转色彩空间才能读分量
                let c = raw.usingColorSpace(.sRGB) ?? raw
                let a = Int(c.alphaComponent * 255)
                let r = Int(c.redComponent * 255)
                let g = Int(c.greenComponent * 255)
                let b = Int(c.blueComponent * 255)
                let maxC = max(r, max(g, b)), minC = min(r, min(g, b))
                let sat = maxC == 0 ? 0 : (maxC - minC) * 255 / maxC
                let score = a * 2 + sat          // 既要实心,也要有彩度
                if score > bestScore { bestScore = score; best = (r, g, b, a) }
            }
        }
        return bestScore < 0 ? nil : best
    }
}
