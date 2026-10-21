import AppKit

/// 单张曲线的坐标约定，容量窗口与 CPU 百分比采用不同纵轴。
private enum TrendAxis {
    /// CPU 固定零至百分之百。
    case percent
    /// 内存固定零至本机物理总量。
    case memory
    /// 普通速度、功率或转速从零开始，按窗口峰值扩展。
    case positive
    /// 电池净功率保留正充入、负放出的方向。
    case signed
    /// 已用容量紧贴窗口真实最小最大值，不强制从零开始。
    case capacity
    /// 下载位于中线上方，上传位于下方，上下共用速度尺度。
    case mirrored
}

/// 原生曲线的静态展示规格，不持有采样器或定时器。
private struct TrendChartSpec {
    /// 图表标题与辅助功能名称。
    let title: String
    /// 同一坐标区域绘制的指标，风扇按稳定编号排序。
    let metrics: [TrendMetric]
    /// 纵轴和上下方向的语义。
    let axis: TrendAxis
    /// 常规窗口中的首选高度，屏幕不足时允许压缩。
    let height: CGFloat
}

/// 在现有资源二级详情上方组合趋势，继续复用原生应用排行和独立系统电量历史。
final class ResourceTrendController: NSViewController {
    /// 当前资源决定图表组和需要读取的历史列。
    private let section: ResourceSection
    /// 所有资源共享一个有界历史库。
    private let history: TrendHistoryStore
    /// 原有排行控制器，表格仍使用独立滚动区域。
    private let ranking: NSViewController?
    /// 电源独有的旧电量历史页面，只在用户切换到该页时读取 Powerlog。
    private let batteryHistory: PowerHistoryPanelController?
    /// 新曲线固定四档，初次及关闭一级弹窗后恢复一分钟。
    private var range: TrendRange = .minute
    /// 不同来源的真实曲线点，隐藏时释放，不缓存二十四小时的所有资源。
    private var series: [TrendMetric: [TrendPoint]] = [:]
    /// 当前快照包含的最后一个采样标识，实时通知据此去重。
    private var watermark: Int64 = 0
    /// 展示世代用于拒绝已关闭页面或旧范围的异步查询结果。
    private var epoch = UUID()
    /// 只有当前二级详情可见时才整理数据和重绘。
    private var visible = false
    /// 正在加载期间的样本由同一历史队列快照覆盖，不重复叠加。
    private var loading = false
    /// 电源切换到旧电量页面时暂停新趋势的渲染。
    private var showingBatteryHistory = false
    /// 可见范围右边界随真实采样更新，不额外设置 UI 定时器。
    private var end = Date().timeIntervalSince1970
    /// 所有新趋势共用的四档范围控件。
    private let rangeControl = NSSegmentedControl(labels: TrendRange.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    /// 功率与电量分开显示，保留旧系统历史的范围和读取语义。
    private let powerPages = NSSegmentedControl(labels: ["功率趋势", "电量历史"], trackingMode: .selectOne, target: nil, action: nil)
    /// 当前资源的一至三张轻量原生曲线。
    private var charts: [TrendChartView] = []
    /// 图表组可整体隐藏，隐藏后不占用旧电量页面空间。
    private let chartStack = NSStackView()
    /// 仅在较早历史不可读时出现，实时内存曲线仍可展示。
    private let errorLabel = NSTextField(labelWithString: "")

    /// 组合现有控制器，不改变模型的采样可见性或请求管理员权限。
    init(section: ResourceSection, history: TrendHistoryStore, ranking: NSViewController? = nil,
         batteryHistory: PowerHistoryPanelController? = nil) {
        self.section = section; self.history = history; self.ranking = ranking; self.batteryHistory = batteryHistory
        super.init(nibName: nil, bundle: nil)
    }

    /// 趋势页面完全使用代码创建。
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 为 CPU、内存、网络、功率、容量、读写和多风扇确定固定图表语义。
    private var specifications: [TrendChartSpec] {
        switch section {
        case .cpu: return [TrendChartSpec(title: "CPU 占用", metrics: [.cpu], axis: .percent, height: 150)]
        case .memory: return [TrendChartSpec(title: "已用内存", metrics: [.memory], axis: .memory, height: 150)]
        case .network: return [TrendChartSpec(title: "网络速度", metrics: [.download, .upload], axis: .mirrored, height: 170)]
        case .disk: return [TrendChartSpec(title: "磁盘已用容量", metrics: [.diskUsed], axis: .capacity, height: 105),
                            TrendChartSpec(title: "磁盘读取", metrics: [.diskRead], axis: .positive, height: 90),
                            TrendChartSpec(title: "磁盘写入", metrics: [.diskWrite], axis: .positive, height: 90)]
        case .power: return [TrendChartSpec(title: "系统耗电", metrics: [.systemPower], axis: .positive, height: 150),
                             TrendChartSpec(title: "输入功率", metrics: [.inputPower], axis: .positive, height: 100),
                             TrendChartSpec(title: "电池充放电功率", metrics: [.batteryPower], axis: .signed, height: 100)]
        case .fan: return [TrendChartSpec(title: "风扇转速", metrics: (0..<10).compactMap(TrendMetric.fan), axis: .positive, height: 210)]
        }
    }

    /// 展示图表时只查询该资源对应的固定列。
    private var metrics: [TrendMetric] { specifications.flatMap(\.metrics) }

    /// 上方固定趋势、下方可伸缩排行；屏幕高度不足时优先压缩图表而非遮住排行按钮。
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 392, height: 460))
        let root = NSStackView()
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 8; root.detachesHiddenViews = true
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor), root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.topAnchor), root.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        let title = NSTextField(labelWithString: "\(section.title)趋势")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        rangeControl.controlSize = .small; rangeControl.selectedSegment = 0
        rangeControl.target = self; rangeControl.action = #selector(changeRange)
        rangeControl.setAccessibilityLabel("\(section.title)趋势时间范围")
        powerPages.controlSize = .small; powerPages.selectedSegment = 0
        powerPages.target = self; powerPages.action = #selector(changePowerPage)
        let header = NSStackView(views: [section == .power ? powerPages : title, NSView(), rangeControl])
        header.alignment = .centerY; root.addArrangedSubview(header)
        chartStack.orientation = .vertical; chartStack.alignment = .leading; chartStack.spacing = 8
        chartStack.detachesHiddenViews = true
        for spec in specifications {
            let chart = TrendChartView(specification: spec)
            charts.append(chart); chartStack.addArrangedSubview(chart)
            let preferred = chart.heightAnchor.constraint(equalToConstant: spec.height)
            preferred.priority = .defaultHigh; preferred.isActive = true
            chart.heightAnchor.constraint(greaterThanOrEqualToConstant: 55).isActive = true
            chart.widthAnchor.constraint(equalTo: chartStack.widthAnchor).isActive = true
            chart.onHoverTime = { [weak self] time in self?.charts.forEach { $0.setHover(time) } }
        }
        root.addArrangedSubview(chartStack)
        errorLabel.font = .systemFont(ofSize: 10); errorLabel.textColor = .secondaryLabelColor; errorLabel.isHidden = true
        root.addArrangedSubview(errorLabel)
        if let ranking {
            addChild(ranking); root.addArrangedSubview(ranking.view)
            ranking.view.setContentHuggingPriority(.defaultLow, for: .vertical)
        }
        if let batteryHistory {
            addChild(batteryHistory); root.addArrangedSubview(batteryHistory.view); batteryHistory.view.isHidden = true
        }
        // 无排行时使用底部弹性空间，避免窗口拉高时把图表强行拉伸。
        if ranking == nil {
            let spacer = NSView(); root.addArrangedSubview(spacer)
            spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        }
        for child in root.arrangedSubviews { child.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        render()
    }

    /// 仅当前详情订阅实时曲线，旧系统电量页面拥有独立按需读取生命周期。
    func setVisible(_ value: Bool) {
        visible = value; epoch = UUID(); loading = false
        history.observe(metrics: value && !showingBatteryHistory ? metrics : [])
        if value {
            _ = view
            if showingBatteryHistory { batteryHistory?.setVisible(true) }
            else { reload() }
        } else {
            batteryHistory?.setVisible(false)
            series.removeAll(); watermark = 0
            if isViewLoaded { charts.forEach { $0.update(series: [:], range: range, end: end, loading: false) } }
        }
    }

    /// 关闭一级弹窗后重置新趋势范围和功率页，不修改系统电量历史的既有默认值。
    func resetRange() {
        range = .minute; showingBatteryHistory = false
        batteryHistory?.resetRange()
        if isViewLoaded {
            rangeControl.selectedSegment = 0; powerPages.selectedSegment = 0
            chartStack.isHidden = false; rangeControl.isHidden = false; batteryHistory?.view.isHidden = true
        }
    }

    /// 合并尚未入库的实时样本；数据库提交完成不会改变曲线或导致重复绘制。
    func receive(_ sample: TrendSample) {
        guard visible, !showingBatteryHistory, !loading, sample.id > watermark else { return }
        let relevant = sample.values.filter { metrics.contains($0.metric) }
        guard !relevant.isEmpty else { return }
        watermark = sample.id; end = Date().timeIntervalSince1970
        let start = end - Double(range.rawValue)
        for value in relevant {
            let previous = series[value.metric]?.last
            let point = TrendPoint(id: sample.id, time: sample.time, value: value.value, segment: sample.segment,
                spacing: sample.spacing, estimated: value.estimated,
                breakBefore: previous.map { sample.time - $0.time > max(3, $0.spacing * 3) } ?? false)
            series[value.metric, default: []].append(point)
            if previous.map({ $0.time > sample.time }) == true {
                series[value.metric]?.sort { left, right in
                    left.time == right.time ? left.id < right.id : left.time < right.time
                }
            }
        }
        for metric in metrics {
            let points = (series[metric] ?? []).filter { $0.time >= start && $0.time <= end }
            // 容量保留完整标量，以便滑动窗口的上下限始终来自窗口内真实最小最大值。
            series[metric] = metric == .diskUsed || points.count <= 800
                ? points : TrendDownsampler.reduce(points, since: start, range: range)
        }
        render()
    }

    /// 固定四档切换只读取历史，不修改采样器和设置中的刷新周期。
    @objc private func changeRange() {
        guard TrendRange.allCases.indices.contains(rangeControl.selectedSegment) else { return }
        range = TrendRange.allCases[rangeControl.selectedSegment]
        reload()
    }

    /// 用户显式选择电量历史时才启动 Powerlog 查询，返回功率页时立即加载当前趋势。
    @objc private func changePowerPage() {
        showingBatteryHistory = powerPages.selectedSegment == 1
        history.observe(metrics: visible && !showingBatteryHistory ? metrics : [])
        epoch = UUID(); loading = false
        chartStack.isHidden = showingBatteryHistory; rangeControl.isHidden = showingBatteryHistory
        errorLabel.isHidden = true; batteryHistory?.view.isHidden = !showingBatteryHistory
        batteryHistory?.setVisible(visible && showingBatteryHistory)
        if !showingBatteryHistory { reload() }
    }

    /// 数据库与缓冲由一个队列产生一致快照，样本通知按同队列顺序在快照之后继续交付。
    private func reload() {
        guard visible, !showingBatteryHistory else { return }
        let current = UUID(); epoch = current; loading = true
        series.removeAll(); end = Date().timeIntervalSince1970; errorLabel.isHidden = true; render()
        history.load(metrics: metrics, range: range) { [weak self] snapshot in
            guard let self, self.visible, self.epoch == current, !self.showingBatteryHistory else { return }
            self.loading = false; self.series = snapshot.series; self.watermark = snapshot.watermark
            self.end = Date().timeIntervalSince1970
            self.errorLabel.stringValue = snapshot.error ?? ""; self.errorLabel.isHidden = snapshot.error == nil
            self.render()
        }
    }

    /// 只更新可见图形，没有动画或隐藏页面刷新计时器。
    private func render() {
        guard isViewLoaded else { return }
        charts.forEach { $0.update(series: series, range: range, end: end, loading: loading) }
    }
}

/// 几百个显示点的 AppKit 曲线；无 WebView、持续动画或额外渲染循环。
private final class TrendChartView: NSView {
    /// 同组功率或磁盘图共享悬停时间，便于比较同一时刻。
    var onHoverTime: ((TimeInterval?) -> Void)?
    /// 固定的指标、纵轴和标题配置。
    private let specification: TrendChartSpec
    /// 可见曲线的真实显示点；容量纵轴另从完整标量计算。
    private var series: [TrendMetric: [TrendPoint]] = [:]
    /// 当前图形纵轴最小最大值，不随鼠标移动重新计算。
    private var limits: (low: Double, high: Double) = (0, 1)
    /// 固定四档窗口及其真实右边界。
    private var range: TrendRange = .minute
    /// 横轴右边界的 Unix 秒。
    private var end: TimeInterval = 0
    /// 初次读取状态与空历史分别展示。
    private var loading = false
    /// 多图共享的鼠标对应时间；只展示附近真实样本，不插值伪造读数。
    private var hoverTime: TimeInterval?
    /// 随视图尺寸更新的跟踪区域。
    private var tracking: NSTrackingArea?
    /// 轴标签与悬停读数复用格式器，避免每次绘图创建。
    private let timeFormatter = DateFormatter()

    /// 创建仅由真实数据变化触发重绘的原生视图。
    init(specification: TrendChartSpec) {
        self.specification = specification
        super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.image); setAccessibilityLabel(specification.title)
    }

    /// 曲线完全使用代码创建。
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 坐标文字保留左边距，顶部给标题读数，底部给时间轴。
    private var plot: NSRect {
        let left: CGFloat = specification.axis == .capacity ? 84 : 64
        return NSRect(x: left, y: 20, width: max(1, bounds.width - left - 6), height: max(1, bounds.height - 45))
    }

    /// 新数据到达后计算纵轴和显示点，鼠标移动时无需重复扫描历史。
    func update(series source: [TrendMetric: [TrendPoint]], range: TrendRange, end: TimeInterval, loading: Bool) {
        self.range = range; self.end = end; self.loading = loading
        let start = end - Double(range.rawValue)
        var values: [Double] = []
        for metric in specification.metrics {
            let points = (source[metric] ?? []).filter { $0.time >= start && $0.time <= end }
            values += points.compactMap(\.value)
            series[metric] = points.count <= 800 ? points : TrendDownsampler.reduce(points, since: start, range: range)
        }
        let minimum = values.min() ?? 0, maximum = values.max() ?? 0
        switch specification.axis {
        case .percent: limits = (0, 100)
        case .memory: limits = (0, Double(ProcessInfo.processInfo.physicalMemory))
        case .mirrored: let peak = max(1024, maximum); limits = (-peak, peak)
        case .signed: let peak = max(1, max(abs(minimum), abs(maximum))); limits = (-peak, peak)
        case .positive: limits = (0, max(1, maximum))
        case .capacity:
            let padding = max(50_000_000, abs(minimum) * 0.00001)
            limits = maximum > minimum ? (minimum, maximum) : (max(0, minimum - padding), maximum + padding)
        }
        setAccessibilityValue(specification.metrics.compactMap { metric in
            guard let point = series[metric]?.last, let value = point.value else { return nil }
            return "\(name(metric)) \(point.estimated ? "≈" : "")\(format(value, metric: metric))"
        }.joined(separator: "，"))
        needsDisplay = true
    }

    /// 多图同步指针仅重画定位线和读数，不触发查询或重新采样。
    func setHover(_ time: TimeInterval?) { hoverTime = time; needsDisplay = true }

    /// 使用实际可见区域跟踪鼠标，兼容窗口高度和屏幕位置变化。
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area; super.updateTrackingAreas()
    }

    /// 将指针横向位置映射成时间，由每条曲线选择附近真实采样点。
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard plot.contains(point) else { onHoverTime?(nil); return }
        onHoverTime?(end - Double(range.rawValue) + Double((point.x - plot.minX) / plot.width) * Double(range.rawValue))
    }

    /// 指针移出后恢复最新读数，不保留过期悬停位置。
    override func mouseExited(with event: NSEvent) { onHoverTime?(nil) }

    /// 原生线条与轻量面积填充，下载向上、上传向下；数据缺失和生命周期分段均断线。
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawText(specification.title, rect: NSRect(x: 0, y: bounds.maxY - 16, width: 145, height: 14), color: .labelColor, weight: .medium)
        let active = specification.metrics.filter { (series[$0] ?? []).contains { $0.value != nil } }
        let readout = NSMutableAttributedString(string: "")
        for metric in active.prefix(4) {
            let points = series[metric] ?? []
            let point: TrendPoint?
            if let hoverTime {
                point = points.min { abs($0.time - hoverTime) < abs($1.time - hoverTime) }
            } else { point = points.last }
            guard let point, let value = point.value,
                  hoverTime.map({ abs(point.time - $0) <= max(point.spacing * 3, Double(range.rawValue) / 80) }) ?? true else { continue }
            let label = specification.metrics.count > 1 ? "\(name(metric)) " : ""
            if readout.length > 0 { readout.append(NSAttributedString(string: " · ", attributes: [.foregroundColor: NSColor.secondaryLabelColor])) }
            readout.append(NSAttributedString(string: "\(label)\(point.estimated ? "≈" : "")\(format(value, metric: metric))",
                                             attributes: [.foregroundColor: color(metric)]))
        }
        let readoutStyle = NSMutableParagraphStyle(); readoutStyle.alignment = .right; readoutStyle.lineBreakMode = .byTruncatingTail
        readout.addAttributes([.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular), .paragraphStyle: readoutStyle],
                              range: NSRange(location: 0, length: readout.length))
        readout.draw(in: NSRect(x: 135, y: bounds.maxY - 16, width: max(1, bounds.width - 135), height: 14))
        let axisMetric = specification.metrics.first ?? .cpu
        for fraction in [0.0, 0.5, 1.0] {
            let y = plot.minY + CGFloat(fraction) * plot.height
            let value = limits.low + fraction * (limits.high - limits.low)
            NSColor.separatorColor.withAlphaComponent(fraction == 0.5 && specification.axis == .mirrored ? 0.9 : 0.45).setStroke()
            let line = NSBezierPath(); line.move(to: NSPoint(x: plot.minX, y: y)); line.line(to: NSPoint(x: plot.maxX, y: y))
            line.lineWidth = 0.5; line.stroke()
            drawText(format(abs(value), metric: axisMetric, signed: specification.axis == .signed && value < 0),
                     rect: NSRect(x: 0, y: y - 6, width: plot.minX - 6, height: 12), alignment: .right)
        }
        timeFormatter.dateFormat = range == .minute ? "HH:mm:ss" : "HH:mm"
        for fraction in [0.0, 0.5, 1.0] {
            let time = end - Double(range.rawValue) * (1 - fraction)
            let x = plot.minX + CGFloat(fraction) * plot.width
            let width: CGFloat = 60
            let origin = fraction == 0 ? x : (fraction == 1 ? x - width : x - width / 2)
            drawText(timeFormatter.string(from: Date(timeIntervalSince1970: time)), rect: NSRect(x: origin, y: 0, width: width, height: 14),
                     alignment: fraction == 1 ? .right : (fraction == 0 ? .left : .center))
        }
        guard !active.isEmpty else {
            drawText(loading ? "正在读取趋势…" : "暂无这段时间的记录", rect: NSRect(x: plot.minX, y: plot.midY - 7, width: plot.width, height: 16), alignment: .center)
            return
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: plot.insetBy(dx: -1, dy: -1)).addClip()
        for metric in active {
            let color = color(metric)
            let points = series[metric] ?? []
            var previous: TrendPoint?
            for point in points {
                guard point.value != nil else { previous = nil; continue }
                let location = coordinate(point, metric: metric)
                if let previous, previous.value != nil, previous.segment == point.segment, !point.breakBefore {
                    let before = coordinate(previous, metric: metric)
                    let zero = y(max(limits.low, min(limits.high, 0)))
                    let fill = NSBezierPath(); fill.move(to: NSPoint(x: before.x, y: zero)); fill.line(to: before)
                    fill.line(to: location); fill.line(to: NSPoint(x: location.x, y: zero)); fill.close()
                    color.withAlphaComponent(0.10).setFill(); fill.fill()
                    let line = NSBezierPath(); line.move(to: before); line.line(to: location)
                    color.setStroke(); line.lineWidth = 1.5; line.stroke()
                }
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: location.x - 1.3, y: location.y - 1.3, width: 2.6, height: 2.6)).fill()
                previous = point
            }
        }
        if let hoverTime {
            let x = plot.minX + CGFloat((hoverTime - end + Double(range.rawValue)) / Double(range.rawValue)) * plot.width
            let guide = NSBezierPath(); guide.move(to: NSPoint(x: x, y: plot.minY)); guide.line(to: NSPoint(x: x, y: plot.maxY))
            NSColor.secondaryLabelColor.withAlphaComponent(0.6).setStroke(); guide.lineWidth = 0.5; guide.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 将真实数值映射到纵轴；容量面积填充也会被裁剪在窗口最小最大值之间。
    private func y(_ value: Double) -> CGFloat {
        plot.minY + CGFloat((value - limits.low) / max(0.000001, limits.high - limits.low)) * plot.height
    }

    /// 上传仅改变视觉方向，实际读数和历史值始终为正速度。
    private func coordinate(_ point: TrendPoint, metric: TrendMetric) -> NSPoint {
        let value = (point.value ?? 0) * (specification.axis == .mirrored && metric == .upload ? -1 : 1)
        return NSPoint(x: plot.minX + CGFloat((point.time - end + Double(range.rawValue)) / Double(range.rawValue)) * plot.width, y: y(value))
    }

    /// 多曲线图例使用固定用户名称，不暴露历史表列名或 SMC key。
    private func name(_ metric: TrendMetric) -> String {
        switch metric {
        case .download: return "↓下载"
        case .upload: return "↑上传"
        default:
            if metric.rawValue >= TrendMetric.fan0.rawValue { return "风扇\(metric.rawValue - TrendMetric.fan0.rawValue + 1)" }
            return specification.title
        }
    }

    /// 上传下载和不同风扇具有稳定颜色，同组图的数值含义不随刷新变化。
    private func color(_ metric: TrendMetric) -> NSColor {
        if metric == .upload || metric == .diskWrite { return .systemOrange }
        if metric == .download || metric == .diskRead { return .systemBlue }
        if metric.rawValue >= TrendMetric.fan0.rawValue {
            let colors: [NSColor] = [.systemBlue, .systemOrange, .systemGreen, .systemPurple, .systemPink,
                                     .systemTeal, .systemRed, .systemYellow, .systemBrown, .systemCyan]
            return colors[(metric.rawValue - TrendMetric.fan0.rawValue) % colors.count]
        }
        return .systemGreen
    }

    /// 容量保留足够小数区分窄窗口；速度复用应用现有单位口径。
    private func format(_ value: Double, metric: TrendMetric, signed: Bool = false) -> String {
        let prefix = signed ? "−" : ""
        switch metric {
        case .cpu: return String(format: "%.0f%%", value)
        case .memory: return MemoryText.string(UInt64(max(0, value)))
        case .diskUsed:
            let span = limits.high - limits.low
            let precision = span < 1_000_000 ? 6 : (span < 100_000_000 ? 4 : 3)
            return String(format: "%.*f GB", precision, value / 1_000_000_000)
        case .download, .upload, .diskRead, .diskWrite: return SpeedText.string(value)
        case .inputPower, .systemPower, .batteryPower: return prefix + String(format: "%.1f W", value)
        default: return String(format: "%.0f RPM", value)
        }
    }

    /// 使用动态系统色和可截断单行文本，深浅外观及窄屏中不覆盖相邻标题。
    private func drawText(_ text: String, rect: NSRect, color: NSColor = .secondaryLabelColor,
                          weight: NSFont.Weight = .regular, alignment: NSTextAlignment = .left) {
        let style = NSMutableParagraphStyle(); style.alignment = alignment; style.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: weight),
                                                         .foregroundColor: color, .paragraphStyle: style])
    }
}
