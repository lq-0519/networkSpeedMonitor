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

/// 单个菜单栏按钮的组合图像，按 CPU、内存、网速、电池固定顺序拼接勾选的内容。
enum StatusItemImage {
    /// 网速两行共用固定字体和字形布局；文字颜色由绘制时的按钮外观决定。
    struct NetworkTextLayout {
        /// 带单位的下载文本，用于判断缓存是否仍匹配当前显示内容。
        let download: String
        /// 带单位的上传文本，用于判断缓存是否仍匹配当前显示内容。
        let upload: String
        /// 上传、下载依次排列；测量和两种像素密度的绘制共用这些行与边界。
        fileprivate let rows: [(line: CTLine, bounds: CGRect)]
        /// 两行的共同左侧字形边界，用于将网速文字左对齐。
        fileprivate let left: CGFloat
        /// 当前内容所需的列宽，已包含固定的最小网速缓冲。
        let width: CGFloat

        /// 仅在格式化网速文字变化时生成 CoreText 行，并一次测量两行字形边界。
        init(download: String, upload: String) {
            self.download = download
            self.upload = upload
            let attributes: [NSAttributedString.Key: Any] = [
                .font: StatusItemImage.networkFont,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
            ]
            let rows = ["↑ \(upload)", "↓ \(download)"].map { text in
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
                return (line: line, bounds: CTLineGetBoundsWithOptions(line, .useGlyphPathBounds))
            }
            self.rows = rows
            let left = rows.map { $0.bounds.minX }.min() ?? 0
            self.left = left
            let right = rows.map { $0.bounds.maxX }.max() ?? 0
            width = max(StatusItemImage.compactNetworkWidth, ceil(right - left))
        }
    }

    /// 系统符号只解析一次；最终颜色在每张位图的独立透明层内合成，不保留延迟绘图回调。
    private static let lightningSymbol: NSImage? = {
        let image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)
        image?.isTemplate = false
        return image
    }()

    /// 测量参考宽度与格式化网速时共用同一份字体。
    private static let networkFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)

    /// 以两位数 KB/s 为基准，把旧版固定列宽超出的缓冲压至三分之一；字体、文字本身不缩放。
    private static let compactNetworkWidth: CGFloat = {
        /// 按同一字体计算参考文本的真实字形宽度，避免用字符数量估算像素。
        func measured(_ samples: [String]) -> CGFloat {
            samples.map { CTLineGetBoundsWithOptions(line($0, font: networkFont, color: .black), .useGlyphPathBounds).width }
                .max() ?? 0
        }
        let baseline = measured(["↑ 99 KB/s", "↓ 99 KB/s"])
        let previous = max(60, ceil(measured(["↑ 1000.0 MB/s", "↓ 1000.0 MB/s", "↑ 1000.0 GB/s", "↓ 1000.0 GB/s"])))
        return ceil(baseline + (previous - baseline) / 3)
    }()

    /// 返回当前双行网速需要的列宽，供已有单次测量调用使用。
    static func networkWidth(download: String, upload: String) -> CGFloat {
        NetworkTextLayout(download: download, upload: upload).width
    }

    /// 为传入一次性文字的调用准备网速布局；隐藏网速时跳过排版。
    static func make(download: String, upload: String, cpuPercent: Double?, memoryPercent: Int? = nil,
                     components: Set<MenuBarComponent>, battery: BatteryStatus?, minimumNetworkWidth: CGFloat = 0) -> NSImage {
        let network = components.contains(.network) ? NetworkTextLayout(download: download, upload: upload) : nil
        return make(network: network, cpuPercent: cpuPercent, memoryPercent: memoryPercent,
                    components: components, battery: battery, minimumNetworkWidth: minimumNetworkWidth)
    }

    /// 使用已测量的网速布局生成普通与 Retina 位图，按当前按钮外观绘制文字。
    /// 主应用保留已使用的最大网速列宽，显示内容变短时电池的位置不会回缩。
    static func make(network: NetworkTextLayout?, cpuPercent: Double?, memoryPercent: Int?,
                     components: Set<MenuBarComponent>, battery: BatteryStatus?, minimumNetworkWidth: CGFloat) -> NSImage {
        let cpuColor = components.contains(.cpu) ? StatusItemColorScale.cpu(percent: cpuPercent) : nil
        let memoryValue = memoryPercent.flatMap { (0...100).contains($0) ? Double($0) : nil }
        let memoryColor: NSColor? = components.contains(.memory) && memoryValue != nil ? .systemOrange : nil
        let batteryColor = components.contains(.battery) ? StatusItemColorScale.battery(percent: battery?.percent) : nil
        let isTemplate = cpuColor == nil && memoryColor == nil && batteryColor == nil
        // 有彩色内容时也解析同一个按钮外观下的原生文字色，避免另一层视图独立变亮、偏色或拒绝淡化。
        let foreground = isTemplate ? NSColor.black : NSColor.controlTextColor.usingColorSpace(.sRGB) ?? .controlTextColor
        let textAreaWidth = network.map { max(minimumNetworkWidth, $0.width) } ?? 0
        var width: CGFloat = components.contains(.cpu) ? 14 : 0
        // 每个饼图连同描边占 14pt，CPU 与内存的可见边缘只留 2pt，单独显示时不保留空位。
        if components.contains(.memory), width > 0 { width += 2 }
        let memoryOrigin = width
        if components.contains(.memory) { width += 14 }
        if components.contains(.network), width > 0 { width += 6 }
        let networkOrigin = width
        if components.contains(.network) { width += textAreaWidth }
        // 原有 6pt 最小分隔同步缩至三分之一，冗余空白仍留在电池前方供长数字占用。
        if components.contains(.battery), width > 0 { width += 2 }
        let batteryOrigin = width
        let batteryText = components.contains(.battery) ? BatteryTextLayout(
            battery, color: batteryColor ?? foreground, foreground: foreground) : nil
        width += batteryText?.width ?? 0
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
            if components.contains(.cpu) {
                drawPie(cpuColor == nil ? nil : cpuPercent, origin: 0, color: cpuColor ?? foreground, in: context)
            }
            if components.contains(.memory) {
                drawPie(memoryColor == nil ? nil : memoryValue, origin: memoryOrigin,
                        color: memoryColor ?? foreground, in: context)
            }
            context.textMatrix = .identity
            if let network, components.contains(.network) {
                context.setFillColor(foreground.cgColor)
                for (index, row) in network.rows.enumerated() {
                    let ink = row.bounds
                    let rowBottom = rect.minY + CGFloat(1 - index) * 11
                    context.textPosition = CGPoint(x: networkOrigin - network.left,
                                                   y: rowBottom + (11 - ink.height) / 2 - ink.minY)
                    CTLineDraw(row.line, context)
                }
            }
            if let batteryText {
                draw(batteryText.secondary, bounds: batteryText.secondaryBounds, origin: batteryOrigin,
                     width: batteryText.width, row: 0, in: context)
                draw(batteryText.percentage, bounds: batteryText.percentageBounds, origin: batteryOrigin,
                     width: batteryText.width - (batteryText.lightning ? 9 : 0), row: 1, in: context)
                if batteryText.lightning {
                    let bolt = NSRect(x: batteryOrigin + (batteryText.width - batteryText.upperWidth) / 2
                                      + batteryText.percentageBounds.width + 2,
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

    /// 仅在显示电池时测量两行文字和充电符号占用的宽度，两种位图共享同一份测量结果。
    private struct BatteryTextLayout {
        /// 上行的电量百分比文字。
        let percentage: CTLine
        /// 上行字形边界，供文字居中与闪电定位使用。
        let percentageBounds: CGRect
        /// 下行的充电或续航状态文字。
        let secondary: CTLine
        /// 下行字形边界，供文字居中使用。
        let secondaryBounds: CGRect
        /// 仅在系统报告实际充电时显示闪电。
        let lightning: Bool
        /// 上行文字和充电符号的合计宽度。
        let upperWidth: CGFloat
        /// 两行内容所需的最大宽度。
        let width: CGFloat

        /// 保留电池原有字号、颜色和紧凑列宽，测量时预留充电符号的位置。
        init(_ status: BatteryStatus?, color: NSColor, foreground: NSColor) {
            percentage = StatusItemImage.line(status?.percentageText ?? "—",
                font: .monospacedDigitSystemFont(ofSize: 13, weight: .medium), color: color)
            percentageBounds = CTLineGetBoundsWithOptions(percentage, .useGlyphPathBounds)
            secondary = StatusItemImage.line(status?.secondaryText ?? "—",
                font: .monospacedDigitSystemFont(ofSize: 9, weight: .medium), color: foreground)
            secondaryBounds = CTLineGetBoundsWithOptions(secondary, .useGlyphPathBounds)
            lightning = status?.showsLightning == true
            upperWidth = percentageBounds.width + (lightning ? 9 : 0)
            width = ceil(max(upperWidth, secondaryBounds.width))
        }
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

    /// CPU 和内存共用原有 13pt 饼图的扇区、描边和透明度，origin 只决定水平位置，不增加视图或动画。
    /// 有效百分比从顶部顺时针填充；未知值保留中性短横线，与真实零占用区分。
    private static func drawPie(_ percent: Double?, origin: CGFloat, color: NSColor, in context: CGContext) {
        let circle = CGRect(x: origin + 0.5, y: 4.5, width: 13, height: 13)
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
