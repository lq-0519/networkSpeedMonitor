import AppKit
import QuartzCore

/// 流向图专用的显示快照；仅在显示层按一位小数去重，底层采样与历史始终保留原始读数。
private struct PowerFlowValues: Equatable {
    /// 外部电源是否接通，决定左列显示适配器还是放电电池。
    let external: Bool
    /// 实际输入瓦数，缺失时不使用适配器标称能力代替。
    let input: Double?
    /// 整机运行瓦数，与部件合计分开保留，不强制调整数字使图形守恒。
    let system: Double?
    /// 有符号电池瓦数，正值进入电池，负值从电池流向 Mac。
    let battery: Double?
    /// 输入上游的适配器效率损耗估算，独立说明，不从整机余量扣减。
    let adapterLoss: Double?
    /// 实际可读部件及估算余量，缺失部件没有字典条目。
    let parts: [PowerComponent: Double]
    /// 按未舍入功率降序排列的最多六个独立部件，其他固定在最后；未知值仅在有空位时显示。
    let orderedComponents: [PowerComponent]
    /// 说明首次采集、缺失字段或不同采样口径，不向用户暴露私有接口实现。
    let note: String
    /// 悬停说明保留完整未知类别、估算口径与合并项，即使六个独立部件的限制隐藏某项也能查看其状态。
    let details: String

    /// 从同轮读取结果产生展示数据；负余量保持未知，所有原始部件读数不会按总量缩放。
    init(power: PowerSnapshot, components: PowerComponentSnapshot?) {
        external = power.external
        input = Self.rounded(power.inputWatts); system = Self.rounded(power.systemWatts)
        battery = Self.rounded(power.batteryWatts)
        adapterLoss = Self.rounded(power.adapterLossWatts)
        let measured = (components?.watts ?? [:]).filter { $0.key != .other }
        let expected = Set(PowerComponent.coreComponents).union(components?.availableComponents ?? []).union(measured.keys)
        let candidates = PowerComponent.allCases.filter { $0 != .other && expected.contains($0) }
        let sorted = candidates.sorted {
            let left = measured[$0] ?? -1, right = measured[$1] ?? -1
            if left != right { return left > right }
            return (PowerComponent.allCases.firstIndex(of: $0) ?? 0) < (PowerComponent.allCases.firstIndex(of: $1) ?? 0)
        }
        let selected = Array(sorted.prefix(6))
        let folded = sorted.dropFirst(6)
        let unknown = candidates.filter { measured[$0] == nil }
        let foldedWatts = folded.reduce(0) { $0 + (measured[$1] ?? 0) }
        var displayed = measured.filter { selected.contains($0.key) }
        let sum = measured.values.reduce(0, +)
        let mismatch = power.systemWatts.map { sum > $0 } ?? false
        if let total = power.systemWatts, sum <= total {
            displayed[.other] = (total - sum) + foldedWatts
        }
        parts = displayed.mapValues { ($0 * 10).rounded() / 10 }
        orderedComponents = selected + [.other]
        if components?.measuring == true {
            note = "正在采集部件功耗…"
        } else if mismatch {
            note = "部件与整机采样口径不同，保留各自读数"
        } else if measured.keys.allSatisfy({ $0 == .display }) {
            note = "部件功耗暂不可用；— 表示未知"
        } else if !unknown.isEmpty {
            note = "\(unknown.map(\.title).joined(separator: "、"))未知，其他含未测量负载"
        } else {
            note = "前六项按功率排序，其余合并到其他"
        }
        var explanations = [note, "部件功耗来自系统模型估算，屏幕仅表示内置背光；其他包含差值估算和未展开部件。"]
        if power.estimated { explanations.append("整机与电池功率由电压电流或收支推算。") }
        if !unknown.isEmpty { explanations.append("未知项：" + unknown.map(\.title).joined(separator: "、")) }
        if !folded.isEmpty {
            explanations.append("合并项：" + folded.map {
                $0.title + " " + PowerFlowPanelController.watts(measured[$0])
            }.joined(separator: "、"))
        }
        if power.external { explanations.append("适配器损耗是输入上游估算，不计入 Mac 运行耗电。") }
        details = explanations.joined(separator: "\n")
    }

    /// 与界面显示精度一致，跳过不会改变一位小数读数的重复图形重建。
    private static func rounded(_ value: Double?) -> Double? {
        value.map { ($0 * 10).rounded() / 10 }
    }
}

/// 电源详情顶部的原生实时区；消费共享快照，不创建计时器、数据库或额外采集进程。
final class PowerFlowPanelController: NSViewController {
    /// 一级弹窗控制采样生命周期，详情只读取这个共享模型。
    private let monitor: PowerMonitor
    /// 整机瓦数独立于电池充电功率，避免把充电损耗显示为系统运行耗电。
    private let totalLabel = NSTextField(labelWithString: "—")
    /// 当前电量、充放电状态和系统时间估算共用紧凑一行。
    private let stateLabel = NSTextField(labelWithString: "正在采集…")
    /// 自绘功率带和由 Core Animation 执行的少量圆点。
    private let diagram = PowerFlowDiagramView(frame: .zero)
    /// 数据口径和不可用状态只使用一行，避免展开实现细节。
    private let noteLabel = NSTextField(labelWithString: "")
    /// 只有电源二级详情可见时才更新控件与图形。
    private var visible = false

    /// 关联现有采样模型，构造控制器不会加载能耗库或读取硬件。
    init(monitor: PowerMonitor) {
        self.monitor = monitor
        super.init(nibName: nil, bundle: nil)
    }

    /// 顶部实时区完全使用代码创建。
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 固定约二百五十点高度，标题、状态、图形和口径说明不会随读数改变窗口大小。
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 392, height: 252))
        let title = NSTextField(labelWithString: "实时功率")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        totalLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .medium)
        totalLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let header = NSStackView(views: [title, NSView(), totalLabel]); header.alignment = .centerY
        stateLabel.font = .systemFont(ofSize: 11); stateLabel.textColor = .secondaryLabelColor
        stateLabel.lineBreakMode = .byTruncatingTail
        noteLabel.font = .systemFont(ofSize: 10); noteLabel.textColor = .secondaryLabelColor
        noteLabel.lineBreakMode = .byTruncatingTail
        let root = NSStackView(views: [header, stateLabel, diagram, noteLabel])
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 6
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor),
            diagram.heightAnchor.constraint(equalToConstant: 178)
        ])
        for row in root.arrangedSubviews { row.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        totalLabel.toolTip = "整机当前运行耗电，不包含充入电池的功率。"
    }

    /// 呈现时立即同步已经采集的快照，收起或切换资源时立即移除所有运动图层。
    func setVisible(_ value: Bool) {
        visible = value
        if value {
            _ = view
            diagram.setActive(true)
            refresh()
        } else if isViewLoaded {
            diagram.setActive(false)
        }
    }

    /// 仅可见详情消费电源通知；相同字符串不赋值，相同显示快照不重建功率带。
    func refresh() {
        guard visible, isViewLoaded else { return }
        guard let power = monitor.snapshot else {
            update(totalLabel, "—"); update(stateLabel, "电源数据不可用")
            update(noteLabel, "— 表示系统未提供有效功率")
            noteLabel.toolTip = nil; diagram.toolTip = nil
            diagram.update(nil)
            return
        }
        let values = PowerFlowValues(power: power, components: monitor.componentSnapshot)
        update(totalLabel, Self.watts(values.system))
        var status = [power.external
            ? (power.charged ? "已充满" : power.optimized ? "优化充电已暂停" : power.charging ? "充电中" : "已接通电源")
            : "电池供电"]
        if let percent = power.percent { status.append("\(percent)%") }
        if let minutes = power.minutes {
            let time = minutes >= 60 ? "\(minutes / 60)时\(minutes % 60)分" : "\(minutes)分钟"
            status.append((power.external ? "预计充满 " : "预计续航 ") + time)
        }
        update(stateLabel, status.joined(separator: " · "))
        update(noteLabel, values.note)
        if noteLabel.toolTip != values.details { noteLabel.toolTip = values.details }
        if diagram.toolTip != values.details { diagram.toolTip = values.details }
        diagram.update(values)
    }

    /// 不重复设置相同文本，减少自动布局、辅助功能和绘制的无效通知。
    private func update(_ label: NSTextField, _ text: String) {
        if label.stringValue != text { label.stringValue = text }
    }

    /// 瓦数固定一位小数，不添加近似符号；估算口径保留在悬停说明，未知与真实零值分别显示。
    fileprivate static func watts(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f W", abs(value))
    }
}

/// 静态功率带仅在快照或尺寸变化时绘制；圆点最多十六个，由系统合成器以十五帧上限移动。
private final class PowerFlowDiagramView: NSView {
    /// 一根节点条的几何位置和文字；几何高度可容纳不同口径的输入输出，不改写标签读数。
    private struct Node {
        /// 稳定身份用于连接功率带。
        let key: String
        /// 自绘窄条，坐标遵循视图从上往下的方向。
        let rect: CGRect
        /// 部件或供电角色的动态系统色。
        let color: NSColor
        /// 标签保留真实显示读数，缺失时为短横线。
        let text: String
    }

    /// 一条功率带的两个中心和厚度；同一尺度对应瓦数，不按整机总量缩放部件数据。
    private struct Band {
        /// 稳定连接身份，使相近几何可以复用动画图层。
        let key: String
        /// 来源中心点。
        let start: CGPoint
        /// 去向中心点。
        let end: CGPoint
        /// 由真实功率与统一比例决定的垂直厚度。
        let thickness: CGFloat
        /// 来源或对应部件的颜色。
        let color: NSColor
    }

    /// 每条功率带的运动图层及粗粒度几何签名；小幅变化不重启动画。
    private struct Track {
        /// 持有两个圆点，整体移除即可停止动画并释放合成资源。
        let layer: CALayer
        /// 中心坐标以两点精度去重，避免亚像素抖动导致图层频繁创建。
        let signature: [Int]
    }

    /// 只保留最近的显示快照，隐藏详情不接收新的渲染数据。
    private var values: PowerFlowValues?
    /// 当前节点和功率带的有界缓存，绘制时不重新计算布局。
    private var nodes: [Node] = []
    /// 实际功率流向，充电和放电使用不同身份及方向。
    private var bands: [Band] = []
    /// 当前圆点图层，关闭二级详情时全部移除。
    private var tracks: [String: Track] = [:]
    /// 由二级详情显式控制，窗口引用仍存在时也不会继续隐藏动画。
    private var active = false

    /// 创建轻量图层和辅助功能描述，没有刷新计时器或逐帧回调。
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true; layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true); setAccessibilityRole(.image)
        setAccessibilityLabel("实时功率流向")
    }

    /// 自绘视图不支持归档创建。
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 从上往下布置三个功率列，动画和自绘共用相同坐标。
    override var isFlipped: Bool { true }

    /// 同精度快照只检查系统动态效果偏好，不重新布局或使视图失效。
    func update(_ value: PowerFlowValues?) {
        guard values != value else { updateParticles(); return }
        values = value
        rebuild()
    }

    /// 显式启停图层，关闭期间不会因窗口仍被复用而遗留持续动画。
    func setActive(_ value: Bool) {
        active = value
        updateParticles()
    }

    /// 仅实际尺寸改变后重建几何，不随每轮文本更新调整布局。
    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed { rebuild() }
    }

    /// 从宿主移除时同步停止动画，重新进入宿主后只恢复可见详情。
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateParticles()
    }

    /// 外观切换重新解析动态系统色，避免深浅色转换后保留旧圆点配色。
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        clearTracks(); updateParticles(); needsDisplay = true
    }

    /// 映射系统部件色，其他负载使用中性色；标签仍保持系统文字色。
    private func color(for component: PowerComponent) -> NSColor {
        switch component {
        case .cpu: return .systemBlue
        case .gpu: return .systemOrange
        case .memory: return .systemGreen
        case .display: return .systemYellow
        case .ane: return .systemPink
        case .videoEncode: return .systemTeal
        case .videoDecode: return .systemCyan
        case .camera: return .systemIndigo
        case .imageScale: return .systemMint
        case .proRes: return .systemRed
        case .jpeg: return .systemBrown
        case .other: return .secondaryLabelColor
        }
    }

    /// 三列共用瓦数比例，右侧最多七行按本轮排序共用节点、文字和流带中心；零值与缺失值不生成假的流量。
    private func rebuild() {
        nodes.removeAll(keepingCapacity: true); bands.removeAll(keepingCapacity: true)
        guard let values, bounds.width >= 300, bounds.height > 50 else {
            clearTracks(); needsDisplay = true
            setAccessibilityValue("功率数据不可用")
            return
        }
        let charge = max(values.battery ?? 0, 0)
        let discharge = max(-(values.battery ?? 0), 0)
        let adapterToMac = values.external && values.input != nil && values.battery != nil
            ? max(0, (values.input ?? 0) - charge) : 0
        let incoming = adapterToMac + discharge
        let partTotal = values.parts.values.reduce(0, +)
        let macSize = max(values.system ?? 0, max(incoming, partTotal))
        let adapterSize = max(values.input ?? 0, adapterToMac + charge)
        let peak = max(0.1, max(adapterSize + discharge, max(macSize + charge, partTotal)))
        let top: CGFloat = 20, height = bounds.height - 42
        let components = values.orderedComponents
        let partRowHeight = height / CGFloat(components.count)
        let baseScale = max(1, height - 52) / CGFloat(peak)
        // 右侧每个节点在自己的文字行内保留间隔；必要时统一缩小三列几何，不改写功率或各分支比例。
        let largestPart = values.parts.values.max() ?? 0
        let partScale = largestPart > 0 ? max(2, partRowHeight - 4) / CGFloat(largestPart) : baseScale
        let scale = min(baseScale, partScale)
        let sourceX: CGFloat = 66, macX: CGFloat = 166, partX = bounds.width - 120

        /// 来源和 Mac 中间列按真实功率高度居中排列；右侧部件单独使用固定行中心。
        func column(_ entries: [(String, Double, NSColor, String)], at x: CGFloat) {
            let heights = entries.map { max(2, CGFloat($0.1) * scale) }
            let used = heights.reduce(0, +) + CGFloat(max(0, entries.count - 1)) * 8
            var y = top + (height - used) / 2
            for (entry, h) in zip(entries, heights) {
                nodes.append(Node(key: entry.0, rect: CGRect(x: x, y: y, width: 6, height: h),
                                  color: entry.2, text: entry.3))
                y += h + 8
            }
        }
        var sources: [(String, Double, NSColor, String)] = []
        if values.external {
            sources.append(("adapter", adapterSize, .systemGreen,
                            "适配器\n" + PowerFlowPanelController.watts(values.input)))
        }
        if !values.external || discharge > 0 {
            sources.append(("batteryOut", discharge, .systemPurple,
                            "电池放电\n" + PowerFlowPanelController.watts(values.battery)))
        }
        column(sources, at: sourceX)
        var middle: [(String, Double, NSColor, String)] = [
            ("mac", macSize, .labelColor, "Mac " + PowerFlowPanelController.watts(values.system))
        ]
        if values.external && charge > 0 {
            middle.append(("batteryIn", charge, .systemPurple,
                           "电池充电 " + PowerFlowPanelController.watts(charge)))
        }
        column(middle, at: macX)
        // 节点中心也是流带的默认终点和文字中心，三者不会再分别执行文字避让。
        for (index, component) in components.enumerated() {
            let name = component.title
            let nodeHeight = max(2, CGFloat(values.parts[component] ?? 0) * scale)
            let centerY = top + (CGFloat(index) + 0.5) * partRowHeight
            nodes.append(Node(key: component.rawValue,
                              rect: CGRect(x: partX, y: centerY - nodeHeight / 2, width: 6, height: nodeHeight),
                              color: color(for: component),
                              text: name + "\n" + PowerFlowPanelController.watts(values.parts[component])))
        }

        /// 根据已知流量构造真实厚度，太小或未知的功率不创建运动带。
        func connect(_ from: String, _ to: String, watts: Double, startY: CGFloat? = nil, endY: CGFloat? = nil) {
            guard watts > 0, let source = nodes.first(where: { $0.key == from }),
                  let target = nodes.first(where: { $0.key == to }) else { return }
            let thickness = CGFloat(watts) * scale
            guard thickness >= 0.2 else { return }
            bands.append(Band(key: from + ">" + to,
                              start: CGPoint(x: source.rect.maxX, y: startY ?? source.rect.midY),
                              end: CGPoint(x: target.rect.minX, y: endY ?? target.rect.midY),
                              thickness: thickness, color: from == "mac" ? target.color : source.color))
        }
        if let mac = nodes.first(where: { $0.key == "mac" }) {
            let inTop = mac.rect.midY - CGFloat(incoming) * scale / 2
            if let adapter = nodes.first(where: { $0.key == "adapter" }) {
                let sourceTop = adapter.rect.midY - CGFloat(adapterToMac + charge) * scale / 2
                connect("adapter", "mac", watts: adapterToMac,
                        startY: sourceTop + CGFloat(adapterToMac) * scale / 2,
                        endY: inTop + CGFloat(adapterToMac) * scale / 2)
                connect("adapter", "batteryIn", watts: charge,
                        startY: sourceTop + CGFloat(adapterToMac + charge / 2) * scale)
            }
            connect("batteryOut", "mac", watts: discharge,
                    endY: inTop + CGFloat(adapterToMac + discharge / 2) * scale)
            var offset = mac.rect.midY - CGFloat(partTotal) * scale / 2
            for component in components {
                let watts = values.parts[component] ?? 0
                connect("mac", component.rawValue, watts: watts, startY: offset + CGFloat(watts) * scale / 2)
                offset += CGFloat(watts) * scale
            }
        }
        var description = nodes.map { $0.text.replacingOccurrences(of: "\n", with: " ") }
        if values.external {
            description.append("适配器损耗 " + PowerFlowPanelController.watts(values.adapterLoss))
        }
        setAccessibilityValue(description.joined(separator: "，"))
        needsDisplay = true; updateParticles()
    }

    /// 使用平滑三次曲线连接同一功率带，动画路径取带的中心线。
    private func path(for band: Band, ribbon: Bool) -> CGPath {
        let path = CGMutablePath(), middle = (band.start.x + band.end.x) / 2
        let half = ribbon ? band.thickness / 2 : 0
        path.move(to: CGPoint(x: band.start.x, y: band.start.y - half))
        path.addCurve(to: CGPoint(x: band.end.x, y: band.end.y - half),
                      control1: CGPoint(x: middle, y: band.start.y - half),
                      control2: CGPoint(x: middle, y: band.end.y - half))
        if ribbon {
            path.addLine(to: CGPoint(x: band.end.x, y: band.end.y + half))
            path.addCurve(to: CGPoint(x: band.start.x, y: band.start.y + half),
                          control1: CGPoint(x: middle, y: band.end.y + half),
                          control2: CGPoint(x: middle, y: band.start.y + half))
            path.closeSubpath()
        }
        return path
    }

    /// 绘制缓存几何和标签；Core Animation 运动不触发本方法或 AppKit 的逐帧布局。
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            for band in bands {
                context.setFillColor(band.color.withAlphaComponent(0.22).cgColor)
                context.addPath(path(for: band, ribbon: true)); context.fillPath()
            }
            for node in nodes {
                node.color.withAlphaComponent(0.8).setFill()
                NSBezierPath(roundedRect: node.rect, xRadius: 2, yRadius: 2).fill()
            }
            drawLabels()
        }
    }

    /// 部件名称与瓦数按各自文字高度对齐到节点行中心，不再移动文字或绘制错位引线。
    private func drawLabels() {
        let names: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]
        let numbers: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                                                    .foregroundColor: NSColor.labelColor]
        let right = nodes.filter { PowerComponent(rawValue: $0.key) != nil }
        for node in right {
            let y = node.rect.midY
            let text = node.text.components(separatedBy: "\n")
            let name = text[0] as NSString, nameSize = name.size(withAttributes: names)
            name.draw(at: NSPoint(x: node.rect.maxX + 7, y: y - nameSize.height / 2), withAttributes: names)
            let value = text[1] as NSString, size = value.size(withAttributes: numbers)
            value.draw(at: NSPoint(x: bounds.width - size.width, y: y - size.height / 2), withAttributes: numbers)
        }
        for node in nodes where node.key == "adapter" || node.key == "batteryOut" {
            let text = node.text.components(separatedBy: "\n")
            for (index, line) in text.enumerated() {
                let attributes = index == 0 ? names : numbers
                let value = line as NSString, size = value.size(withAttributes: attributes)
                value.draw(at: NSPoint(x: node.rect.minX - 6 - size.width, y: node.rect.midY - 13 + CGFloat(index) * 13),
                           withAttributes: attributes)
            }
        }
        for node in nodes where node.key == "mac" || node.key == "batteryIn" {
            let text = node.text as NSString, size = text.size(withAttributes: numbers)
            text.draw(at: NSPoint(x: node.rect.midX - size.width / 2,
                                 y: node.key == "mac" ? node.rect.minY - 15 : node.rect.maxY + 3),
                      withAttributes: numbers)
        }
        if let values, values.external {
            let text = ("适配器损耗 " + PowerFlowPanelController.watts(values.adapterLoss)) as NSString
            let size = text.size(withAttributes: names)
            text.draw(at: NSPoint(x: 0, y: bounds.height - size.height), withAttributes: names)
        }
    }

    /// 仅可见详情使用动画；低电量模式和减少动态效果时保留静态功率带，停止所有圆点。
    private func updateParticles() {
        guard active, window != nil, let root = layer,
              !ProcessInfo.processInfo.isLowPowerModeEnabled,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { clearTracks(); return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        var seen = Set<String>()
        for band in bands.prefix(8) where band.thickness >= 0.8 {
            seen.insert(band.key)
            let signature = [band.start.x, band.start.y, band.end.x, band.end.y].map { Int(($0 / 2).rounded()) }
            if tracks[band.key]?.signature == signature { continue }
            tracks[band.key]?.layer.removeFromSuperlayer()
            let container = CALayer(); container.frame = bounds
            var color = NSColor.labelColor.cgColor
            effectiveAppearance.performAsCurrentDrawingAppearance { color = band.color.cgColor }
            for index in 0..<2 {
                let dot = CALayer()
                dot.bounds = CGRect(x: 0, y: 0, width: 3, height: 3)
                dot.cornerRadius = 1.5; dot.backgroundColor = color; dot.opacity = 0.7
                dot.position = band.start
                let animation = CAKeyframeAnimation(keyPath: "position")
                animation.path = path(for: band, ribbon: false); animation.calculationMode = .paced
                animation.duration = 3; animation.repeatCount = .infinity
                animation.timeOffset = Double(index) * 1.5
                animation.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 15, preferred: 15)
                dot.add(animation, forKey: "powerFlow")
                container.addSublayer(dot)
            }
            root.addSublayer(container)
            tracks[band.key] = Track(layer: container, signature: signature)
        }
        for key in tracks.keys.filter({ !seen.contains($0) }) {
            tracks.removeValue(forKey: key)?.layer.removeFromSuperlayer()
        }
    }

    /// 同步移除运动图层，关闭窗口后不保留合成器动画或循环回调。
    private func clearTracks() {
        for track in tracks.values { track.layer.removeFromSuperlayer() }
        tracks.removeAll()
    }
}
