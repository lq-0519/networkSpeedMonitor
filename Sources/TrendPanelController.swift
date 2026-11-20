import AppKit

/// 单张曲线的坐标约定，容量窗口与 CPU 百分比采用不同纵轴。
private enum TrendAxis {
    /// CPU 固定零至百分之百。
    case percent
    /// 内存固定零至本机物理总量。
    case memory
    /// 所有风扇共用窗口内真实最小最大转速，不强制从零开始，便于比较细微变化。
    case fan
    /// 多项功率共用瓦特坐标；电池放电可低于零，输入与系统耗电保持正值。
    case signed
    /// 已用容量按窗口真实极值缩放，纵轴至少跨 512 MB，不足时上下居中补足。
    case capacity
    /// 下载或磁盘读取位于中线上方，上传或磁盘写入位于下方，各自按可见窗口内的真实峰值缩放。
    /// 两个方向各占一半绘图区，中线始终为零；零流量时不人为抬高对应峰值。
    case independentMirrored

    /// 双向速度轴以中线为零，上传或写入画在下方，两个方向分别使用自己的峰值尺度。
    var isMirrored: Bool { self == .independentMirrored }
}

/// 原生曲线的静态展示规格，不持有采样器或定时器。
private struct TrendChartSpec {
    /// 图表标题与辅助功能名称。
    let title: String
    /// 同一坐标区域绘制的指标，风扇按稳定编号排序；双向速度图依次配置上方和下方指标。
    let metrics: [TrendMetric]
    /// 纵轴和上下方向的语义。
    let axis: TrendAxis
    /// 常规窗口中的首选高度，屏幕不足时允许压缩。
    let height: CGFloat
}

/// 组合资源趋势、原生应用排行和按需系统电量历史，不改变底层采样生命周期。
final class ResourceTrendController: NSViewController {
    /// 流向区保留固定高度，屏幕不足时只缩减下方历史曲线的绘图区。
    private static let powerFlowHeight: CGFloat = 252
    /// 与趋势图已有最小高度一致，压缩后仍保留标题读数、时间轴和功率曲线。
    private static let minimumPowerChartHeight: CGFloat = 55
    /// 时段写入榜最多每十秒查询一次，由当前可见图表收到真实样本时触发。
    private static let diskHistoryRefreshInterval: TimeInterval = 10
    /// 当前资源决定图表组和需要读取的历史列。
    private let section: ResourceSection
    /// 所有资源共享一个有界历史库。
    private let history: TrendHistoryStore
    /// 原有排行控制器，表格仍使用独立滚动区域。
    private let ranking: NSViewController?
    /// 磁盘容量图下方的时段写入排行，与上方实时读写排行独立更新。
    private let diskHistoryRanking: DiskPanelController?
    /// 电源独有的系统电量历史，和功率趋势在同一个详情中上下排列。
    private let batteryHistory: PowerHistoryPanelController?
    /// 电源独有的固定实时流向区，采样仍由一级弹窗的共享模型管理。
    private let powerFlow: PowerFlowPanelController?
    /// 自行采集的曲线固定四档，初次及关闭一级弹窗后统一恢复十分钟。
    private var range: TrendRange = .defaultRange
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
    /// 可见范围右边界随真实采样更新，不额外设置 UI 定时器。
    private var end = Date().timeIntervalSince1970
    /// 下方容量图与时段排行共用的右边界；上方实时读写图沿用最新采样时间。
    private var diskHistoryEnd: TimeInterval?
    /// 当前磁盘排行查询标识，切换范围或隐藏后拒绝旧结果。
    private var diskHistoryRequest: UUID?
    /// 以单调时钟限制滚动查询，系统日期调整不会导致密集刷新。
    private var lastDiskHistoryRequest: TimeInterval = -.infinity
    /// 所有新趋势共用的四档范围控件。
    private let rangeControl = NSSegmentedControl(labels: TrendRange.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    /// 当前资源的一至两张轻量原生曲线；功率三项和磁盘读写分别共享坐标区域。
    private var charts: [TrendChartView] = []
    /// 图表组只包含当前资源的实时趋势，不承载系统电量历史。
    private let chartStack = NSStackView()
    /// 电源三块内容直接纵向排列，非电源资源继续使用原有趋势和排行布局。
    private let contentStack = NSStackView()
    /// 功率绘图区高度仅由可用屏幕高度调整，不随实时读数变化。
    private var powerChartHeightConstraint: NSLayoutConstraint?
    /// 系统电量历史的完整高度，包含可压缩曲线和不可压缩的标题及摘要。
    private var batteryHistoryHeightConstraint: NSLayoutConstraint?
    /// 仅在较早历史不可读时出现，实时内存曲线仍可展示。
    private let errorLabel = NSTextField(labelWithString: "")
    /// 电源错误提示行显隐改变内容高度时通知协调器重新定位；实时采样不调用此回调。
    var onLayoutChange: (() -> Void)?

    /// 组合现有控制器，不改变模型的采样可见性或请求管理员权限。
    init(section: ResourceSection, history: TrendHistoryStore, ranking: NSViewController? = nil,
         diskHistoryRanking: DiskPanelController? = nil,
         batteryHistory: PowerHistoryPanelController? = nil, powerFlow: PowerFlowPanelController? = nil) {
        self.section = section; self.history = history; self.ranking = ranking
        self.diskHistoryRanking = diskHistoryRanking
        self.batteryHistory = batteryHistory; self.powerFlow = powerFlow
        super.init(nibName: nil, bundle: nil)
    }

    /// 趋势页面完全使用代码创建。
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 为 CPU、内存、网络、功率、容量、读写和多风扇确定固定图表语义。
    private var specifications: [TrendChartSpec] {
        switch section {
        case .cpu: return [TrendChartSpec(title: "CPU 占用", metrics: [.cpu], axis: .percent, height: 150)]
        case .memory: return [TrendChartSpec(title: "已用内存", metrics: [.memory], axis: .memory, height: 150)]
        case .network: return [TrendChartSpec(title: "网络速度", metrics: [.download, .upload], axis: .independentMirrored, height: 170)]
        case .disk: return [TrendChartSpec(title: "磁盘读写", metrics: [.diskRead, .diskWrite], axis: .independentMirrored, height: 170),
                            TrendChartSpec(title: "磁盘已用容量", metrics: [.diskUsed], axis: .capacity, height: 125)]
        case .power: return [TrendChartSpec(title: "功率对比",
                                            metrics: [.systemPower, .inputPower, .batteryPower],
                                            axis: .signed, height: 190)]
        case .fan: return [TrendChartSpec(title: "风扇转速", metrics: (0..<10).compactMap(TrendMetric.fan), axis: .fan, height: 210)]
        }
    }

    /// 展示图表时只查询该资源对应的固定列。
    private var metrics: [TrendMetric] { specifications.flatMap(\.metrics) }

    /// 组装共享的时间控件与图表；磁盘的两张排行表分别紧跟对应曲线。
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 392, height: 460))
        let root = contentStack
        let pairsDiskRankings = section == .disk && ranking != nil && diskHistoryRanking != nil
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 8; root.detachesHiddenViews = true
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        if let powerFlow {
            addChild(powerFlow)
            let separator = NSBox(); separator.boxType = .separator
            root.addArrangedSubview(powerFlow.view)
            root.addArrangedSubview(separator)
            NSLayoutConstraint.activate([
                powerFlow.view.heightAnchor.constraint(equalToConstant: Self.powerFlowHeight),
                separator.heightAnchor.constraint(equalToConstant: 1)
            ])
        }
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor), root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.topAnchor), root.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        let title = NSTextField(labelWithString: section == .power ? "功率趋势" : "\(section.title)趋势")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        rangeControl.controlSize = .small
        rangeControl.selectedSegment = TrendRange.allCases.firstIndex(of: range) ?? -1
        rangeControl.target = self; rangeControl.action = #selector(changeRange)
        rangeControl.setAccessibilityLabel("\(section.title)趋势时间范围")
        let header = NSStackView(views: [title, NSView(), rangeControl])
        header.alignment = .centerY
        chartStack.orientation = .vertical; chartStack.alignment = .leading; chartStack.spacing = 8
        chartStack.detachesHiddenViews = true
        for spec in specifications {
            let chart = TrendChartView(specification: spec)
            charts.append(chart)
            if !pairsDiskRankings {
                chartStack.addArrangedSubview(chart)
                chart.widthAnchor.constraint(equalTo: chartStack.widthAnchor).isActive = true
            }
            let preferred = chart.heightAnchor.constraint(equalToConstant: spec.height)
            preferred.priority = section == .power ? .required : .defaultHigh; preferred.isActive = true
            if section == .power { powerChartHeightConstraint = preferred }
            chart.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumPowerChartHeight).isActive = true
            chart.onHoverTime = { [weak self] time in self?.charts.forEach { $0.setHover(time) } }
        }
        errorLabel.font = .systemFont(ofSize: 10); errorLabel.textColor = .secondaryLabelColor; errorLabel.isHidden = true
        if let batteryHistory {
            addChild(batteryHistory)
            root.addArrangedSubview(batteryHistory.view)
            let height = batteryHistory.setChartHeight(PowerHistoryPanelController.preferredChartHeight)
            let constraint = batteryHistory.view.heightAnchor.constraint(equalToConstant: height)
            constraint.isActive = true; batteryHistoryHeightConstraint = constraint
            let separator = NSBox()
            separator.boxType = .separator
            root.addArrangedSubview(separator)
            separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        }
        root.addArrangedSubview(header)
        if pairsDiskRankings, let ranking, let diskHistoryRanking {
            addChild(ranking); addChild(diskHistoryRanking)
            let separator = NSBox(); separator.boxType = .separator
            for part in [charts[0], ranking.view, separator, charts[1], errorLabel, diskHistoryRanking.view] {
                root.addArrangedSubview(part)
            }
            separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
            // 两张排行共用剩余空间，表内可滚动，避免窗口较矮时只有一张表可读。
            let equalRankingHeights = ranking.view.heightAnchor.constraint(equalTo: diskHistoryRanking.view.heightAnchor)
            equalRankingHeights.priority = .defaultHigh
            equalRankingHeights.isActive = true
        } else {
            root.addArrangedSubview(chartStack)
            root.addArrangedSubview(errorLabel)
            if let ranking {
                addChild(ranking); root.addArrangedSubview(ranking.view)
                ranking.view.setContentHuggingPriority(.defaultLow, for: .vertical)
            }
        }
        // 无排行时使用底部弹性空间，避免窗口拉高时把图表强行拉伸。
        if ranking == nil && powerFlow == nil {
            let spacer = NSView(); root.addArrangedSubview(spacer)
            spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        }
        for child in root.arrangedSubviews { child.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        render()
    }

    /// 呈现电源详情时先恢复两张曲线的正常高度，再按屏幕不足的空间共同压缩绘图区。
    /// 返回整块内容的实际高度，宿主自行添加四周边距；不创建滚动区域或采样定时器。
    func fitPowerContent(maximumHeight: CGFloat) -> CGFloat {
        _ = view
        guard section == .power, let powerChartHeightConstraint else { return view.fittingSize.height }
        let preferredPowerHeight = specifications[0].height
        let preferredBatteryHeight = PowerHistoryPanelController.preferredChartHeight
        powerChartHeightConstraint.constant = preferredPowerHeight
        batteryHistoryHeightConstraint?.constant = batteryHistory?.setChartHeight(preferredBatteryHeight) ?? 0
        let naturalHeight = powerContentHeight
        let powerReduction = preferredPowerHeight - Self.minimumPowerChartHeight
        let batteryReduction = batteryHistory == nil ? 0
            : preferredBatteryHeight - PowerHistoryPanelController.minimumChartHeight
        let reducibleHeight = powerReduction + batteryReduction
        let reduction = min(reducibleHeight, max(0, naturalHeight - maximumHeight))
        guard reduction > 0, reducibleHeight > 0 else { return naturalHeight }
        let fraction = reduction / reducibleHeight
        powerChartHeightConstraint.constant = preferredPowerHeight - powerReduction * fraction
        batteryHistoryHeightConstraint?.constant = batteryHistory?.setChartHeight(
            preferredBatteryHeight - batteryReduction * fraction) ?? 0
        return powerContentHeight
    }

    /// 按独立行的实际字体尺寸和当前曲线高度求和，排除隐藏提示行及其间距。
    /// 不测量受旧窗口高度约束的根视图，避免从较矮屏幕返回较高屏幕时继续保留压缩尺寸。
    private var powerContentHeight: CGFloat {
        let rows = contentStack.arrangedSubviews.filter { !$0.isHidden }
        let height = rows.reduce(CGFloat.zero) { total, row in
            if row === powerFlow?.view { return total + Self.powerFlowHeight }
            if row === batteryHistory?.view { return total + (batteryHistoryHeightConstraint?.constant ?? 0) }
            if row === chartStack { return total + (powerChartHeightConstraint?.constant ?? 0) }
            return total + row.fittingSize.height
        }
        return height + contentStack.spacing * CGFloat(max(0, rows.count - 1))
    }

    /// 仅当前详情订阅实时曲线；电源可见时同步启动按需系统电量历史读取。
    func setVisible(_ value: Bool) {
        visible = value; epoch = UUID(); loading = false
        diskHistoryRequest = nil; lastDiskHistoryRequest = -.infinity; diskHistoryEnd = nil
        history.observe(metrics: value ? metrics : [])
        if value {
            _ = view
            powerFlow?.setVisible(true)
            batteryHistory?.setVisible(true)
            reload()
        } else {
            powerFlow?.setVisible(false)
            batteryHistory?.setVisible(false)
            series.removeAll(); watermark = 0
            if isViewLoaded { charts.forEach { $0.update(series: [:], range: range, end: end, loading: false) } }
        }
    }

    /// 实时电源通知只刷新顶部流向区；不查询历史、不重绘下方电量曲线或其他资源。
    func refreshPowerFlow() {
        guard visible else { return }
        powerFlow?.refresh()
    }

    /// 关闭一级弹窗后将当前资源趋势恢复十分钟，并重置系统电量历史自身的默认范围。
    func resetRange() {
        range = .defaultRange
        batteryHistory?.resetRange()
        if isViewLoaded {
            rangeControl.selectedSegment = TrendRange.allCases.firstIndex(of: range) ?? -1
        }
    }

    /// 合并尚未入库的实时样本；数据库提交完成不会改变曲线或导致重复绘制。
    func receive(_ sample: TrendSample) {
        guard visible, !loading, sample.id > watermark else { return }
        let relevant = sample.values.filter { metrics.contains($0.metric) }
        guard !relevant.isEmpty else { return }
        watermark = sample.id
        end = Date().timeIntervalSince1970
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
        if diskHistoryRanking != nil {
            if relevant.contains(where: { $0.metric == .diskRead || $0.metric == .diskWrite }), let liveChart = charts.first {
                trimSeries(only: [.diskRead, .diskWrite])
                render(only: liveChart)
            }
            refreshDiskHistory(through: end)
        } else {
            trimSeries()
            render()
        }
    }

    /// 每张图只裁剪自己正在使用的时间窗口，容量保留等待下次时段刷新时需要的新样本。
    private func trimSeries(only selectedMetrics: [TrendMetric]? = nil) {
        for metric in selectedMetrics ?? metrics {
            let chartEnd = metric == .diskUsed ? diskHistoryEnd ?? end : end
            let start = chartEnd - Double(range.rawValue)
            let points = (series[metric] ?? []).filter { $0.time >= start && (metric == .diskUsed || $0.time <= chartEnd) }
            // 网络、磁盘容量与读写、风扇保留完整标量，以便旧极值滑出窗口后仍能准确计算新的上下限。
            series[metric] = metric.usesWindowBounds || points.count <= 800
                ? points : TrendDownsampler.reduce(points, since: start, range: range)
        }
    }

    /// 固定四档切换只读取历史，不修改采样器和设置中的刷新周期。
    @objc private func changeRange() {
        guard TrendRange.allCases.indices.contains(rangeControl.selectedSegment) else { return }
        range = TrendRange.allCases[rangeControl.selectedSegment]
        reload()
    }

    /// 数据库与缓冲由一个队列产生一致快照，样本通知按同队列顺序在快照之后继续交付。
    private func reload() {
        guard visible else { return }
        let current = UUID(); epoch = current; loading = true
        diskHistoryRequest = nil; lastDiskHistoryRequest = -.infinity; diskHistoryEnd = nil
        diskHistoryRanking?.showWriteHistoryLoading()
        series.removeAll(); end = Date().timeIntervalSince1970; updateHistoryError(nil); render()
        history.load(metrics: metrics, range: range) { [weak self] snapshot in
            guard let self, self.visible, self.epoch == current else { return }
            self.loading = false; self.series = snapshot.series; self.watermark = snapshot.watermark
            self.end = Date().timeIntervalSince1970
            if self.diskHistoryRanking != nil { self.diskHistoryEnd = snapshot.end }
            self.updateHistoryError(snapshot.error)
            self.render()
            self.refreshDiskHistory(through: snapshot.end)
        }
    }

    /// 时段排行查询完成后与容量图同时前移，实时读写图继续随各自采样刷新。
    private func refreshDiskHistory(through end: TimeInterval) {
        guard visible, let diskHistoryRanking, diskHistoryRequest == nil else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        guard uptime - lastDiskHistoryRequest >= Self.diskHistoryRefreshInterval else { return }
        let request = UUID(), range = self.range
        diskHistoryRequest = request; lastDiskHistoryRequest = uptime
        history.loadDiskWrites(start: end - Double(range.rawValue), end: end,
                               limit: RankingPreferences.count(for: .disk)) { [weak self, weak diskHistoryRanking] snapshot in
            guard let self, let diskHistoryRanking, self.diskHistoryRequest == request else { return }
            self.diskHistoryRequest = nil; self.diskHistoryEnd = end
            self.trimSeries(only: [.diskUsed])
            diskHistoryRanking.showWriteHistory(snapshot, range: range)
            if let capacityChart = self.charts.last { self.render(only: capacityChart) }
        }
    }

    /// 历史错误行只有显隐变化时才影响弹窗高度；相同状态不会重复计算窗口尺寸。
    private func updateHistoryError(_ message: String?) {
        let hidden = message == nil
        let visibilityChanged = errorLabel.isHidden != hidden
        errorLabel.stringValue = message ?? ""; errorLabel.isHidden = hidden
        if visibilityChanged, visible, section == .power { onLayoutChange?() }
    }

    /// 只更新指定的可见图形，容量图与时段写入排行使用同一个截止时间。
    private func render(only targetChart: TrendChartView? = nil) {
        guard isViewLoaded else { return }
        for chart in targetChart.map({ [$0] }) ?? charts {
            let chartEnd = chart === charts.last ? diskHistoryEnd ?? end : end
            chart.update(series: series, range: range, end: chartEnd, loading: loading)
        }
    }
}

/// 几百个显示点的 AppKit 曲线；无 WebView、持续动画或额外渲染循环。
private final class TrendChartView: NSView {
    /// 磁盘已用容量纵轴至少展示 512 MB，沿用容量标签的十进制单位，即 512,000,000 字节。
    /// 四档时间窗口共用此下限，避免短时间内的微小变化被放大到整个绘图区。
    private static let minimumCapacitySpan: Double = 512_000_000
    /// 同组功率或磁盘图共享悬停时间，便于比较同一时刻。
    var onHoverTime: ((TimeInterval?) -> Void)?
    /// 固定的指标、纵轴和标题配置。
    private let specification: TrendChartSpec
    /// 可见曲线的真实显示点；网络、磁盘容量与读写、风扇纵轴另从完整标量计算。
    private var series: [TrendMetric: [TrendPoint]] = [:]
    /// 当前图形纵轴最小最大值，不随鼠标移动重新计算；双向速度轴分别保存下方指标的负峰值与上方指标的正峰值。
    private var limits: (low: Double, high: Double) = (0, 1)
    /// 固定四档窗口，初始范围与资源控制器统一默认十分钟。
    private var range: TrendRange = .defaultRange
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
        // 在绘图压缩前分别求每条曲线的峰值，下载与上传、读取与写入分别计算，不互相抬高刻度。
        var peaks: [TrendMetric: Double] = [:]
        for metric in specification.metrics {
            let points = (source[metric] ?? []).filter { $0.time >= start && $0.time <= end }
            let metricValues = points.compactMap(\.value)
            values += metricValues
            peaks[metric] = metricValues.max()
            series[metric] = points.count <= 800 ? points : TrendDownsampler.reduce(points, since: start, range: range)
        }
        let minimum = values.min() ?? 0, maximum = values.max() ?? 0
        switch specification.axis {
        case .percent: limits = (0, 100)
        case .memory: limits = (0, Double(ProcessInfo.processInfo.physicalMemory))
        case .independentMirrored:
            // 按图表配置的上下方向选择指标，网络和磁盘共用独立缩放逻辑，不硬编码网络指标。
            let upperPeak = specification.metrics.first.flatMap { peaks[$0] } ?? 0
            let lowerPeak = specification.metrics.last.flatMap { peaks[$0] } ?? 0
            limits = (-max(0, lowerPeak), max(0, upperPeak))
        case .signed: limits = (min(0, minimum), max(1, maximum))
        case .capacity:
            // 不足最小跨度时向真实极值两侧均匀补足；接近零时整体上移，确保下界非负且跨度不缩小。
            let span = max(Self.minimumCapacitySpan, maximum - minimum)
            let low = max(0, minimum - (span - (maximum - minimum)) / 2)
            limits = (low, low + span)
        case .fan:
            // 非恒定转速严格使用窗口极值，恒定转速才扩展范围以避免零跨度。
            let padding = max(1, abs(minimum) * 0.001)
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

    /// 外观变化时主动重绘自绘文字和线条，持续打开的详情也立即使用新的深浅模式配色。
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// 在本视图的实际外观中解析全部动态系统色，避免透明浮层中的坐标使用浅色模式文字色。
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        effectiveAppearance.performAsCurrentDrawingAppearance { drawChart() }
    }

    /// 原生线条与轻量面积填充，下载/读取向上、上传/写入向下；缺失和生命周期分段均断线。
    /// 调用方已设置当前绘制外观，轴文字、图例、网格和悬停读数均在同一外观中绘制。
    private func drawChart() {
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
            let value: Double
            if specification.axis == .independentMirrored {
                // 双向速度刻度在上下端分别显示各自峰值，中间固定为零，不能对不对称上下限做线性插值。
                value = fraction == 0.5 ? 0 : (fraction == 0 ? limits.low : limits.high)
            } else {
                value = limits.low + fraction * (limits.high - limits.low)
            }
            let metric: TrendMetric = specification.axis.isMirrored && fraction == 0
                ? (specification.metrics.last ?? axisMetric) : axisMetric
            NSColor.separatorColor.withAlphaComponent(fraction == 0.5 && specification.axis.isMirrored ? 0.9 : 0.45).setStroke()
            let line = NSBezierPath(); line.move(to: NSPoint(x: plot.minX, y: y)); line.line(to: NSPoint(x: plot.maxX, y: y))
            line.lineWidth = 0.5; line.stroke()
            let missingPeak = specification.axis == .independentMirrored && fraction != 0.5 && !active.contains(metric)
            drawText(missingPeak ? "—" : format(abs(value), metric: metric, signed: specification.axis == .signed && value < 0),
                     rect: NSRect(x: 0, y: y - 6, width: plot.minX - 6, height: 12),
                     color: .labelColor, weight: .medium, alignment: .right)
        }
        timeFormatter.dateFormat = range == .minute ? "HH:mm:ss" : (range == .day ? "M/d HH:mm" : "HH:mm")
        for fraction in [0.0, 0.5, 1.0] {
            let time = end - Double(range.rawValue) * (1 - fraction)
            let x = plot.minX + CGFloat(fraction) * plot.width
            let width: CGFloat = 60
            let origin = fraction == 0 ? x : (fraction == 1 ? x - width : x - width / 2)
            drawText(timeFormatter.string(from: Date(timeIntervalSince1970: time)), rect: NSRect(x: origin, y: 0, width: width, height: 14),
                     color: .labelColor, alignment: fraction == 1 ? .right : (fraction == 0 ? .left : .center))
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
                    let shouldFill = specification.axis.isMirrored || specification.metrics.count == 1
                    if shouldFill {
                        let fill = NSBezierPath(); fill.move(to: NSPoint(x: before.x, y: zero)); fill.line(to: before)
                        fill.line(to: location); fill.line(to: NSPoint(x: location.x, y: zero)); fill.close()
                        color.withAlphaComponent(0.10).setFill(); fill.fill()
                    }
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
        if let hoverTime {
            drawHoverTime(hoverTime)
        }
    }

    /// 将真实数值映射到纵轴；网络和磁盘读写的上下方向各用自己的峰值映射到半幅高度，零值始终落在中线。
    /// 某方向全为零或缺失时直接回到中线，避免除零；其他资源仍沿用整幅线性映射及容量裁剪。
    private func y(_ value: Double) -> CGFloat {
        if specification.axis == .independentMirrored {
            let peak = value >= 0 ? limits.high : -limits.low
            let fraction = peak > 0 ? value / peak : 0
            return plot.midY + CGFloat(fraction) * plot.height / 2
        }
        return plot.minY + CGFloat((value - limits.low) / max(0.000001, limits.high - limits.low)) * plot.height
    }

    /// 上传和磁盘写入仅改变视觉方向，实际读数和历史值始终为正速度。
    private func coordinate(_ point: TrendPoint, metric: TrendMetric) -> NSPoint {
        let mirroredBelow = metric == .upload || metric == .diskWrite
        let value = (point.value ?? 0) * (specification.axis.isMirrored && mirroredBelow ? -1 : 1)
        return NSPoint(x: plot.minX + CGFloat((point.time - end + Double(range.rawValue)) / Double(range.rawValue)) * plot.width, y: y(value))
    }

    /// 多曲线图例使用固定用户名称，不暴露历史表列名或 SMC key。
    private func name(_ metric: TrendMetric) -> String {
        switch metric {
        case .download: return "↓下载"
        case .upload: return "↑上传"
        case .diskRead: return "读取"
        case .diskWrite: return "写入"
        case .systemPower: return "系统"
        case .inputPower: return "输入"
        case .batteryPower: return "电池"
        default:
            if metric.rawValue >= TrendMetric.fan0.rawValue { return "风扇\(metric.rawValue - TrendMetric.fan0.rawValue + 1)" }
            return specification.title
        }
    }

    /// 上传下载和不同风扇具有稳定颜色，同组图的数值含义不随刷新变化。
    private func color(_ metric: TrendMetric) -> NSColor {
        if metric == .upload || metric == .diskWrite { return .systemOrange }
        if metric == .download || metric == .diskRead { return .systemBlue }
        if metric == .inputPower { return .systemBlue }
        if metric == .batteryPower { return .systemOrange }
        if metric == .systemPower { return .systemGreen }
        if metric.rawValue >= TrendMetric.fan0.rawValue {
            let colors: [NSColor] = [.systemBlue, .systemOrange, .systemGreen, .systemPurple, .systemPink,
                                     .systemTeal, .systemRed, .systemYellow, .systemBrown, .systemCyan]
            return colors[(metric.rawValue - TrendMetric.fan0.rawValue) % colors.count]
        }
        return .systemGreen
    }

    /// 在悬浮竖线正下方绘制对应横轴时间，并限制在绘图区内以免靠近两端时被窗口裁剪。
    private func drawHoverTime(_ time: TimeInterval) {
        timeFormatter.dateFormat = range == .day ? "M/d HH:mm" : "HH:mm:ss"
        let text = timeFormatter.string(from: Date(timeIntervalSince1970: time))
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        let width = ceil((text as NSString).size(withAttributes: [.font: font]).width) + 10
        let lineX = plot.minX + CGFloat((time - end + Double(range.rawValue)) / Double(range.rawValue)) * plot.width
        let originX = min(plot.maxX - width, max(plot.minX, lineX - width / 2))
        let rect = NSRect(x: originX, y: 0, width: width, height: 15)
        NSColor.controlBackgroundColor.withAlphaComponent(0.96).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        NSColor.separatorColor.setStroke()
        let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: 3, yRadius: 3)
        border.lineWidth = 0.5
        border.stroke()
        drawText(text, rect: rect, color: .labelColor, weight: .medium, alignment: .center)
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
