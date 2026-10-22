import AppKit
import CoreText

/// 菜单栏共用的连续状态色；CPU 占用越高越接近红色，电量越低越接近红色。
enum StatusItemColorScale {
    /// 接受实际整机占用的小数值，避免颜色只能随取整后的百分比逐档变化；未知值不着色。
    static func cpu(percent: Double?) -> NSColor? {
        guard let percent, percent.isFinite, (0...100).contains(percent) else { return nil }
        return color(severity: percent / 100)
    }

    /// 电量使用同一条渐变的反向映射；充电状态不覆盖真实剩余百分比对应的颜色。
    static func battery(percent: Int?) -> NSColor? {
        guard let percent, (0...100).contains(percent) else { return nil }
        return color(severity: Double(100 - percent) / 100)
    }

    /// 在绿、黄、橙、红之间逐值插值；颜色在所有连接点连续，不再跨过阈值突然跳色。
    private static func color(severity: Double) -> NSColor {
        let stops: [(position: Double, color: NSColor)] = [
            (0, .systemGreen), (0.5, .systemYellow), (0.75, .systemOrange), (1, .systemRed)
        ]
        let upper = stops.firstIndex { $0.position >= severity } ?? (stops.count - 1)
        guard upper > 0 else { return stops[0].color.usingColorSpace(.sRGB) ?? stops[0].color }
        let start = stops[upper - 1], end = stops[upper]
        let fraction = CGFloat((severity - start.position) / (end.position - start.position))
        let first = start.color.usingColorSpace(.sRGB) ?? start.color
        let last = end.color.usingColorSpace(.sRGB) ?? end.color
        return NSColor(srgbRed: first.redComponent + (last.redComponent - first.redComponent) * fraction,
                       green: first.greenComponent + (last.greenComponent - first.greenComponent) * fraction,
                       blue: first.blueComponent + (last.blueComponent - first.blueComponent) * fraction, alpha: 1)
    }
}

/// 单个菜单栏按钮的组合图像，按 CPU、网速、电池固定顺序拼接勾选的内容。
enum StatusItemImage {
    /// 系统符号只解析一次；最终颜色在每张位图的独立透明层内合成，不保留延迟绘图回调。
    private static let lightningSymbol: NSImage? = {
        let image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)
        image?.isTemplate = false
        return image
    }()

    /// 以两位数 KB/s 为基准，把旧版固定列宽超出的缓冲压至三分之一；字体、文字本身不缩放。
    private static let compactNetworkWidth: CGFloat = {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        /// 按同一字体计算参考文本的真实字形宽度，避免用字符数量估算像素。
        func measured(_ samples: [String]) -> CGFloat {
            samples.map { CTLineGetBoundsWithOptions(line($0, font: font, color: .black), .useGlyphPathBounds).width }
                .max() ?? 0
        }
        let baseline = measured(["↑ 99 KB/s", "↓ 99 KB/s"])
        let previous = max(60, ceil(measured(["↑ 1000.0 MB/s", "↓ 1000.0 MB/s", "↑ 1000.0 GB/s", "↓ 1000.0 GB/s"])))
        return ceil(baseline + (previous - baseline) / 3)
    }()

    /// 返回当前双行网速需要的列宽，包含缩小后的最低缓冲，供主应用记住本次显示期间的最大值。
    static func networkWidth(download: String, upload: String) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        let bounds = ["↑ \(upload)", "↓ \(download)"].map {
            CTLineGetBoundsWithOptions(line($0, font: font, color: .black), .useGlyphPathBounds)
        }
        let left = bounds.map(\.minX).min() ?? 0
        let right = bounds.map(\.maxX).max() ?? 0
        return max(compactNetworkWidth, ceil(right - left))
    }

    /// 保留现有尺寸和字号，提前生成普通与 Retina 位图；系统快照只复制像素，不重复执行文字和符号绘制。
    /// minimumNetworkWidth 由主应用保留已使用的最大列宽，缩小缓冲后也不会随数字变短而反复回缩。
    static func make(download: String, upload: String, cpuPercent: Double?,
                     components: Set<MenuBarComponent>, battery: BatteryStatus?, minimumNetworkWidth: CGFloat = 0) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        let percentageFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let secondaryFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        let cpuColor = components.contains(.cpu) ? StatusItemColorScale.cpu(percent: cpuPercent) : nil
        let batteryColor = components.contains(.battery) ? StatusItemColorScale.battery(percent: battery?.percent) : nil
        let isTemplate = cpuColor == nil && batteryColor == nil
        // 有彩色内容时也解析同一个按钮外观下的原生文字色，避免另一层视图独立变亮、偏色或拒绝淡化。
        let foreground = isTemplate ? NSColor.black : NSColor.controlTextColor.usingColorSpace(.sRGB) ?? .controlTextColor
        let lines = ["↑ \(upload)", "↓ \(download)"].map { line($0, font: font, color: foreground) }
        let bounds = lines.map { CTLineGetBoundsWithOptions($0, .useGlyphPathBounds) }
        let left = bounds.map(\.minX).min() ?? 0
        let textWidth = (bounds.map(\.maxX).max() ?? 0) - left
        // 保留三分之一的小缓冲；主应用传入已使用的最大宽度，数字回落时不会推动电池来回移动。
        let textAreaWidth = max(compactNetworkWidth, max(minimumNetworkWidth, ceil(textWidth)))
        var width: CGFloat = components.contains(.cpu) ? 14 : 0
        if components.contains(.network), width > 0 { width += 6 }
        let networkOrigin = width
        if components.contains(.network) { width += textAreaWidth }
        // 原有 6pt 最小分隔同步缩至三分之一，冗余空白仍留在电池前方供长数字占用。
        if components.contains(.battery), width > 0 { width += 2 }
        let batteryOrigin = width
        let percentageText = battery?.percentageText ?? "—"
        let percentage = line(percentageText, font: percentageFont, color: batteryColor ?? foreground)
        let percentageBounds = CTLineGetBoundsWithOptions(percentage, .useGlyphPathBounds)
        let secondary = line(battery?.secondaryText ?? "—", font: secondaryFont, color: foreground)
        let secondaryBounds = CTLineGetBoundsWithOptions(secondary, .useGlyphPathBounds)
        let lightning = battery?.showsLightning == true
        let upperWidth = percentageBounds.width + (lightning ? 9 : 0)
        // 电池上下两行仅取实际内容的最大宽度，不预留固定列宽或左右内边距。
        let batteryWidth = ceil(max(upperWidth, secondaryBounds.width))
        if components.contains(.battery) { width += batteryWidth }
        let size = NSSize(width: max(14, width), height: 22)
        let image = NSImage(size: size)
        for scale in [1, 2] {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(ceil(size.width)) * scale, pixelsHigh: Int(size.height) * scale,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { continue }
            bitmap.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            let context = graphics.cgContext
            context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            let rect = NSRect(origin: .zero, size: size)
            context.clear(rect)
            context.saveGState()
            if components.contains(.cpu) { drawCPU(cpuColor == nil ? nil : cpuPercent, color: cpuColor ?? foreground, in: context) }
            context.textMatrix = .identity
            if components.contains(.network) {
                for (index, line) in lines.enumerated() {
                    let ink = bounds[index]
                    let rowBottom = rect.minY + CGFloat(1 - index) * 11
                    context.textPosition = CGPoint(x: networkOrigin - left,
                                                   y: rowBottom + (11 - ink.height) / 2 - ink.minY)
                    CTLineDraw(line, context)
                }
            }
            if components.contains(.battery) {
                draw(secondary, bounds: secondaryBounds, origin: batteryOrigin, width: batteryWidth, row: 0, in: context)
                draw(percentage, bounds: percentageBounds, origin: batteryOrigin,
                     width: batteryWidth - (lightning ? 9 : 0), row: 1, in: context)
                if lightning {
                    let bolt = NSRect(x: batteryOrigin + (batteryWidth - upperWidth) / 2 + percentageBounds.width + 2,
                                      y: 12.5, width: 7, height: 8)
                    context.beginTransparencyLayer(auxiliaryInfo: nil)
                    lightningSymbol?.draw(in: bolt)
                    context.setBlendMode(.sourceIn)
                    context.setFillColor(foreground.cgColor)
                    context.fill(bolt)
                    context.endTransparencyLayer()
                }
            }
            context.restoreGState()
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(bitmap)
        }
        image.isTemplate = isTemplate
        return image
    }

    /// 使用相同字体生成 CoreText 行；模板层始终使用黑色以交由系统转换菜单栏颜色。
    private static func line(_ text: String, font: NSFont, color: NSColor) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color
        ]))
    }

    /// 在原有 11pt 行高内按真实字形居中，row=0 为下行，row=1 为上行。
    private static func draw(_ line: CTLine, bounds: CGRect, origin: CGFloat, width: CGFloat,
                             row: Int, in context: CGContext) {
        context.textPosition = CGPoint(x: origin + (width - bounds.width) / 2 - bounds.minX,
                                       y: CGFloat(row) * 11 + (11 - bounds.height) / 2 - bounds.minY)
        CTLineDraw(line, context)
    }

    /// 沿用原 CPU 饼图坐标、扇区和透明度，仅替换有效占用对应的颜色；未知值保留中性短横线。
    private static func drawCPU(_ percent: Double?, color: NSColor, in context: CGContext) {
        let circle = CGRect(x: 0.5, y: 4.5, width: 13, height: 13)
        context.setFillColor(color.withAlphaComponent(0.12).cgColor)
        context.fillEllipse(in: circle)
        if let percent {
            let fraction = CGFloat(min(100, max(0, percent))) / 100
            context.setFillColor(color.cgColor)
            if fraction >= 1 { context.fillEllipse(in: circle) }
            else if fraction > 0 {
                let center = CGPoint(x: circle.midX, y: circle.midY)
                context.move(to: center)
                context.addArc(center: center, radius: circle.width / 2,
                               startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi * fraction, clockwise: true)
                context.closePath(); context.fillPath()
            }
        } else {
            context.setFillColor(color.withAlphaComponent(0.65).cgColor)
            context.fill(CGRect(x: circle.midX - 2, y: circle.midY - 0.5, width: 4, height: 1))
        }
        context.setStrokeColor(color.withAlphaComponent(0.8).cgColor)
        context.setLineWidth(1); context.strokeEllipse(in: circle)
    }
}
