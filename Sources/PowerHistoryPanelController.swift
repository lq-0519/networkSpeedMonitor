import AppKit

/// 电源二级详情只展示系统电量曲线及两项摘要，不创建应用耗电排行或历史采集器。
final class PowerHistoryPanelController: NSViewController {
    /// 历史模型独立于实时功率，仅在本详情可见时读取系统数据库。
    private let monitor = PowerHistoryMonitor()
    /// 轻量 AppKit 曲线视图，没有动画或 UI 刷新计时器。
    private let chart = PowerHistoryChartView(frame: .zero)
    /// 电池供电时间按系统记录区间推算，未知值保持破折号。
    private let duration = NSTextField(labelWithString: "—")
    /// 电池供电期间下降的百分点之和，与充电回升分别统计。
    private let decline = NSTextField(labelWithString: "—")
    /// 按一小时、十小时、二十四小时、七天排列，默认十小时；仅切换系统历史查询范围。
    private let rangeControl = NSSegmentedControl(labels: PowerHistoryRange.allCases.map(\.title),
        trackingMode: .selectOne, target: nil, action: nil)

    /// 创建没有采样副作用的详情控制器，首次呈现由协调器显式启动按需读取。
    init() { super.init(nibName: nil, bundle: nil) }

    /// 历史详情完全使用代码创建。
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 沿用侧边浮层的宽度与字体，上方为曲线，下方只有两个等宽摘要。
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 392, height: 312))
        let title = NSTextField(labelWithString: "电量历史")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        rangeControl.controlSize = .small
        rangeControl.selectedSegment = PowerHistoryRange.allCases.firstIndex(of: .tenHours) ?? -1
        rangeControl.target = self; rangeControl.action = #selector(changeRange)
        rangeControl.setAccessibilityLabel("电量历史时间范围")
        let header = NSStackView(views: [title, NSView(), rangeControl]); header.alignment = .centerY
        let separator = NSBox(); separator.boxType = .separator
        let summary = NSStackView(views: [metric("电池供电", value: duration), metric("累计下降", value: decline)])
        summary.distribution = .fillEqually; summary.spacing = 16
        let root = NSStackView(views: [header, chart, separator, summary])
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor),
            chart.heightAnchor.constraint(equalToConstant: 218),
            separator.heightAnchor.constraint(equalToConstant: 1)
        ])
        for row in root.arrangedSubviews { row.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        duration.toolTip = "根据系统历史记录推算，包含有记录支持的休眠时间；缺失区间不累计。"
        decline.toolTip = "按系统记录推算电池供电期间下降的百分点累计；接电区间与电量回升不计入。"
        monitor.onUpdate = { [weak self] in self?.refresh() }
        refresh()
    }

    /// 协调器呈现和关闭详情时调用；一级概览可见及实时功率刷新均不会触发历史查询。
    func setVisible(_ visible: Bool) {
        if visible { _ = view }
        monitor.setVisible(visible)
        if visible { refresh() }
    }

    /// 关闭一级弹窗后恢复默认范围；仅切换其他资源详情时保留本次选择。
    func resetRange() { monitor.setRange(.tenHours) }

    /// 分段按钮切换到固定范围，拒绝无效索引，不提供十二小时或任意范围输入。
    @objc private func changeRange() {
        guard PowerHistoryRange.allCases.indices.contains(rangeControl.selectedSegment) else { return }
        monitor.setRange(PowerHistoryRange.allCases[rangeControl.selectedSegment])
    }

    /// 将系统快照渲染成曲线和摘要；错误、无记录、正在读取分别显示，不能伪装成零。
    private func refresh() {
        guard isViewLoaded else { return }
        let snapshot = monitor.snapshot
        rangeControl.selectedSegment = PowerHistoryRange.allCases.firstIndex(of: monitor.range) ?? -1
        chart.setRange(monitor.range)
        let hasRecords = snapshot?.samples.contains(where: { $0.time >= (snapshot?.start ?? 0) }) ?? false
        let message = monitor.error ?? (monitor.loading && snapshot == nil
            ? "正在读取系统电量历史…" : "系统暂无这段时间的电量记录")
        chart.update(snapshot: hasRecords ? snapshot : nil, message: message)
        if hasRecords, let summary = snapshot?.summary {
            let minutes = Int(summary.batterySeconds / 60)
            duration.stringValue = minutes >= 60 ? "\(minutes / 60)时\(minutes % 60)分" : "\(minutes) 分钟"
            decline.stringValue = String(format: "%.1f 个百分点", summary.decline)
        } else {
            duration.stringValue = "—"; decline.stringValue = "—"
        }
    }

    /// 创建摘要的标签和等宽数值，不添加被排除的底部采集说明。
    private func metric(_ title: String, value: NSTextField) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor
        value.font = .monospacedDigitSystemFont(ofSize: 19, weight: .medium)
        value.lineBreakMode = .byTruncatingTail
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [label, value])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 3
        value.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }
}

/// 原生静态电量曲线；系统记录之间连线，长缺口断开，接电和休眠按系统状态加背景标记。
private final class PowerHistoryChartView: NSView {
    /// 当前内存快照，不读取数据库或调用实时电池接口。
    private var snapshot: PowerHistorySnapshot?
    /// 没有可展示记录时的简短提示，保持错误与零电量的区别。
    private var message = "正在读取系统电量历史…"
    /// 当前指针对应的最近真实采样点，读数固定显示在顶部图例行右侧。
    private var hovered: PowerHistorySample?
    /// 跟踪区域仅处理指针位置，不安排周期绘制。
    private var hoverTrackingArea: NSTrackingArea?
    /// 用于坐标和辅助功能的当前范围，切换到七天时横轴显示日期。
    private var range: PowerHistoryRange = .tenHours
    /// 坐标和顶部悬停读数复用的本地时间格式器。
    private let timeFormatter: DateFormatter = {
        let value = DateFormatter(); value.dateFormat = "HH:mm"; return value
    }()

    /// 建立辅助功能图像描述，使无法看到曲线的用户也可获得窗口与当前电量信息。
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true); setAccessibilityRole(.image)
        setAccessibilityLabel("过去 10 小时电量变化")
    }

    /// 图形视图不使用归档初始化。
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 坐标按所选范围切换，二十四小时和七天的悬浮信息包含日期以区分跨日记录。
    func setRange(_ value: PowerHistoryRange) {
        range = value
        timeFormatter.dateFormat = value == .day || value == .week ? "M/d HH:mm" : "HH:mm"
        setAccessibilityLabel("过去 \(value.title)电量变化")
    }

    /// 新快照到达才触发绘制；历史面板持续打开时不会随两秒实时功率重绘。
    func update(snapshot: PowerHistorySnapshot?, message: String) {
        self.snapshot = snapshot; self.message = message; hovered = nil
        if let snapshot, let last = snapshot.samples.last {
            setAccessibilityValue("\(timeFormatter.string(from: Date(timeIntervalSince1970: snapshot.start))) 至 "
                + "\(timeFormatter.string(from: Date(timeIntervalSince1970: snapshot.end)))，"
                + "最后记录 \(timeFormatter.string(from: Date(timeIntervalSince1970: last.time)))，电量 \(Int(last.percent.rounded()))%")
        } else { setAccessibilityValue(message) }
        needsDisplay = true
    }

    /// 为左侧百分比、底部时间及顶部图例和读数预留固定空间，悬停不会改变曲线尺寸。
    private var plot: NSRect {
        NSRect(x: 34, y: 25, width: max(1, bounds.width - 43), height: max(1, bounds.height - 50))
    }

    /// 只在布局变化时重建鼠标区域，跨入侧边详情的关闭逻辑仍由外层协调器负责。
    override func updateTrackingAreas() {
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); hoverTrackingArea = area
        super.updateTrackingAreas()
    }

    /// 指针移动时选最近的真实点，只在点发生变化时重绘悬浮提示。
    override func mouseMoved(with event: NSEvent) {
        guard let snapshot else { return }
        let location = convert(event.locationInWindow, from: nil)
        guard plot.contains(location) else { clearHover(); return }
        let time = snapshot.start + Double((location.x - plot.minX) / plot.width) * (snapshot.end - snapshot.start)
        let nearest = snapshot.samples.filter { $0.time >= snapshot.start }.min { abs($0.time - time) < abs($1.time - time) }
        guard nearest?.time != hovered?.time else { return }
        hovered = nearest; needsDisplay = true
    }

    /// 指针离开曲线区域后清理提示，不影响外层窗口悬浮状态。
    override func mouseExited(with event: NSEvent) { clearHover() }

    /// 无提示时不触发绘制，避免跨区移动产生多余工作。
    private func clearHover() {
        guard hovered != nil else { return }
        hovered = nil; needsDisplay = true
    }

    /// 统一把时间和电量映射到所选时间窗口、0～100% 的绘图坐标。
    private func point(_ sample: PowerHistorySample, in snapshot: PowerHistorySnapshot) -> NSPoint {
        NSPoint(x: plot.minX + CGFloat((sample.time - snapshot.start) / (snapshot.end - snapshot.start)) * plot.width,
                y: plot.minY + CGFloat(sample.percent / 100) * plot.height)
    }

    /// 外观变化时主动刷新自绘图表，使已打开的系统电量历史无需重新查询即可切换配色。
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// 在本视图的实际外观中解析动态系统色，避免二级透明浮层中的坐标文字颜色过暗。
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        effectiveAppearance.performAsCurrentDrawingAppearance { drawChart() }
    }

    /// 绘制网格、系统供电/休眠区间和电量曲线；空历史只显示状态文字。
    /// 调用方已设置当前绘制外观，坐标、图例和悬停读数使用一致的深浅模式配色。
    private func drawChart() {
        guard let snapshot else {
            drawText(message, at: NSPoint(x: max(0, (bounds.width - textWidth(message)) / 2), y: bounds.midY - 7))
            return
        }
        drawLegend()
        for value in [0, 50, 100] {
            let y = plot.minY + CGFloat(value) / 100 * plot.height
            NSColor.separatorColor.withAlphaComponent(0.45).setStroke()
            let line = NSBezierPath(); line.move(to: NSPoint(x: plot.minX, y: y))
            line.line(to: NSPoint(x: plot.maxX, y: y)); line.lineWidth = 0.5; line.stroke()
            drawText("\(value)%", at: NSPoint(x: plot.minX - textWidth("\(value)%") - 5, y: y - 6), color: .labelColor)
        }
        // 一小时每十分钟标注一次；其余范围保留既有时间或日期刻度。
        let ticks = range == .week ? 7 : (range == .hour ? 6 : 5)
        let axisFormatter = DateFormatter(); axisFormatter.dateFormat = range == .week ? "M/d" : "HH:mm"
        for index in 0...ticks {
            let time = snapshot.start + Double(index) / Double(ticks) * (snapshot.end - snapshot.start)
            let label = axisFormatter.string(from: Date(timeIntervalSince1970: time))
            let x = plot.minX + CGFloat(index) / CGFloat(ticks) * plot.width
            drawText(label, at: NSPoint(x: min(bounds.maxX - textWidth(label), max(0, x - textWidth(label) / 2)), y: 5), color: .labelColor)
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: plot.insetBy(dx: -1, dy: -2)).addClip()
        for interval in snapshot.sleeps {
            drawInterval(interval.start, interval.end, snapshot: snapshot,
                         color: .secondaryLabelColor, alpha: 0.10)
        }
        for (before, after) in zip(snapshot.samples, snapshot.samples.dropFirst()) where snapshot.connects(before, after) {
            if before.external {
                drawInterval(before.time, after.time, snapshot: snapshot, color: .systemGreen, alpha: 0.10)
            }
            let first = point(before, in: snapshot), second = point(after, in: snapshot)
            let fill = NSBezierPath(); fill.move(to: NSPoint(x: first.x, y: plot.minY))
            fill.line(to: first); fill.line(to: second); fill.line(to: NSPoint(x: second.x, y: plot.minY)); fill.close()
            NSColor.systemGreen.withAlphaComponent(0.12).setFill(); fill.fill()
            let line = NSBezierPath(); line.move(to: first); line.line(to: second)
            line.lineWidth = 2; NSColor.systemGreen.setStroke(); line.stroke()
        }
        // 每个真实点都可见；只有一条系统记录时也不会伪造整段水平曲线。
        NSColor.systemGreen.setFill()
        for sample in snapshot.samples where sample.time >= snapshot.start {
            let location = point(sample, in: snapshot)
            NSBezierPath(ovalIn: NSRect(x: location.x - 1.7, y: location.y - 1.7, width: 3.4, height: 3.4)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        if let hovered { drawHover(hovered, snapshot: snapshot) }
    }

    /// 图例放在曲线上方，不增加被排除的底部采集说明或覆盖率行。
    private func drawLegend() {
        let y = bounds.maxY - 13
        NSColor.systemGreen.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: NSRect(x: plot.minX, y: y + 1, width: 10, height: 7), xRadius: 2, yRadius: 2).fill()
        drawText("接通电源", at: NSPoint(x: plot.minX + 15, y: y - 2))
        NSColor.secondaryLabelColor.withAlphaComponent(0.20).setFill()
        NSBezierPath(roundedRect: NSRect(x: plot.minX + 86, y: y + 1, width: 10, height: 7), xRadius: 2, yRadius: 2).fill()
        drawText("休眠", at: NSPoint(x: plot.minX + 101, y: y - 2))
    }

    /// 将真实状态区间裁剪到所选窗口，避免左侧基线或重叠区间越出图形。
    private func drawInterval(_ start: TimeInterval, _ end: TimeInterval, snapshot: PowerHistorySnapshot,
                              color: NSColor, alpha: CGFloat) {
        let lower = max(snapshot.start, start), upper = min(snapshot.end, end)
        guard upper > lower else { return }
        let x = plot.minX + CGFloat((lower - snapshot.start) / (snapshot.end - snapshot.start)) * plot.width
        let width = CGFloat((upper - lower) / (snapshot.end - snapshot.start)) * plot.width
        color.withAlphaComponent(alpha).setFill()
        NSBezierPath(rect: NSRect(x: x, y: plot.minY, width: width, height: plot.height)).fill()
    }

    /// 图内仅绘制定位竖线；真实记录的时间、电量和供电状态固定右对齐到顶部图例行，
    /// 不随指针位置移动、不覆盖曲线，也不为指针所在时间插值生成假记录。
    private func drawHover(_ sample: PowerHistorySample, snapshot: PowerHistorySnapshot) {
        let location = point(sample, in: snapshot)
        NSColor.secondaryLabelColor.withAlphaComponent(0.5).setStroke()
        let guide = NSBezierPath(); guide.move(to: NSPoint(x: location.x, y: plot.minY))
        guide.line(to: NSPoint(x: location.x, y: plot.maxY)); guide.lineWidth = 0.5; guide.stroke()
        let state = sample.external ? (sample.charging ? "充电中" : "已接通电源") : "电池供电"
        let text = timeFormatter.string(from: Date(timeIntervalSince1970: sample.time))
            + String(format: " · %.0f%% · ", sample.percent) + state
        drawText(text, at: NSPoint(x: plot.maxX - textWidth(text), y: bounds.maxY - 15), color: .labelColor)
        drawHoverTime(sample.time, lineX: location.x)
    }

    /// 把真实系统电量记录的时间标在悬浮线下方，并钳制到横轴范围内避免长日期越界。
    private func drawHoverTime(_ time: TimeInterval, lineX: CGFloat) {
        let text = timeFormatter.string(from: Date(timeIntervalSince1970: time))
        let width = ceil(textWidth(text)) + 10
        let originX = min(plot.maxX - width, max(plot.minX, lineX - width / 2))
        let rect = NSRect(x: originX, y: 3, width: width, height: 15)
        NSColor.controlBackgroundColor.withAlphaComponent(0.96).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        NSColor.separatorColor.setStroke()
        let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: 3, yRadius: 3)
        border.lineWidth = 0.5
        border.stroke()
        drawText(text, at: NSPoint(x: rect.minX + 5, y: rect.minY + 1), color: .labelColor)
    }

    /// 统一使用小字号系统字体测量，保证坐标文字和顶部悬停读数不越过浮窗边界。
    private func textWidth(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10)]).width
    }

    /// 绘制动态系统色文本，深色模式与浅色模式均由 AppKit 解析当前外观。
    private func drawText(_ text: String, at point: NSPoint, color: NSColor = .secondaryLabelColor) {
        (text as NSString).draw(at: point, withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: color])
    }
}
