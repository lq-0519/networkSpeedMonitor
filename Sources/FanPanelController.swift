import AppKit

/// 磁盘下方的按需风扇区域，按实际风扇数量展示当前 RPM，无风扇机型自动折叠。
final class FanPanelController: NSViewController {
    /// 只在显隐或行数导致高度变化时通知一级窗口，不为普通 RPM 更新触发尺寸计算。
    var onLayoutChange: (() -> Void)?
    /// 风扇趋势与其他资源共用悬浮、跨窗口退出及点击锁定行为。
    var onEnter: ((NSView) -> Void)?
    /// 指针离开风扇概览后交给统一协调器延迟关闭。
    var onExit: ((NSView) -> Void)?
    /// 点击或键盘确认时锁定风扇趋势。
    var onActivate: ((NSView) -> Void)?
    /// 复用电源概览的轻量交互容器，不新增事件监控或采样器。
    private let overview = ResourceHistoryOverviewView(frame: .zero)
    /// 与电源区域共享采样周期和生命周期的模型。
    private let monitor: PowerMonitor
    /// 标题右侧显示风扇数量与统一刷新周期，详细口径放在悬停提示中。
    private let stateLabel = NSTextField(labelWithString: "正在读取…")
    /// 一到多行指标容器，每行最多四个风扇，防止多风扇机型挤压文字。
    private let rows = NSStackView()
    /// 当前指标视图，顺序与 FanSnapshot.fans 保持一致。
    private var metrics: [FanMetric] = []
    /// 根据风扇行数调整区域高度，无风扇时由 NSStackView 隐藏并折叠。
    private var heightConstraint: NSLayoutConstraint?

    /// 关联共享模型，不创建采样器、连接或独立计时器。
    init(monitor: PowerMonitor) {
        self.monitor = monitor
        super.init(nibName: nil, bundle: nil)
    }

    /// 风扇区域完全由代码布局。
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 构建紧凑标题和最多四列的转速网格，初始高度容纳一行指标。
    override func loadView() {
        view = overview
        overview.frame = NSRect(x: 0, y: 0, width: 392, height: 54)
        overview.setAccessibilityLabel("风扇详情")
        overview.setAccessibilityHelp("查看各风扇转速趋势，点击锁定详情")
        overview.onEnter = { [weak self] in self?.onEnter?($0) }
        overview.onExit = { [weak self] in self?.onExit?($0) }
        overview.onActivate = { [weak self] in self?.onActivate?($0) }
        let title = NSTextField(labelWithString: "风扇")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        stateLabel.font = .systemFont(ofSize: 11)
        stateLabel.textColor = .secondaryLabelColor
        let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "风扇趋势") ?? NSImage())
        chevron.contentTintColor = .tertiaryLabelColor
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        let header = NSStackView(views: [title, NSView(), stateLabel, chevron])
        header.alignment = .centerY
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 5
        let root = NSStackView(views: [header, rows])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 5
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        let height = view.heightAnchor.constraint(equalToConstant: 54)
        heightConstraint = height
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor),
            height
        ])
        header.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        rows.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        stateLabel.toolTip = "只读 AppleSMC 当前实际转速，与电源共用采样周期；"
            + "本程序不修改风扇模式或目标转速。"
    }

    /// 协调器统一反映点击锁定状态，不改变风扇读取周期或控制硬件。
    func setPinned(_ value: Bool) { overview.setPinned(value) }

    /// 刷新当前风扇数值；无风扇隐藏区域，接口失败保留区域并显示不可用。
    func refresh() {
        guard isViewLoaded else { return }
        let wasHidden = view.isHidden, previousHeight = heightConstraint?.constant
        defer {
            if wasHidden != view.isHidden || previousHeight != heightConstraint?.constant { onLayoutChange?() }
        }
        guard let snapshot = monitor.fanSnapshot else {
            view.isHidden = false
            stateLabel.stringValue = "风扇数据不可用"
            updateMetrics([])
            return
        }
        guard !snapshot.fans.isEmpty else {
            view.isHidden = true
            return
        }
        view.isHidden = false
        stateLabel.stringValue = "\(snapshot.fans.count) 个"
        updateMetrics(snapshot.fans)
    }

    /// 风扇数量或名称变化时重建轻量指标，普通采样只更新文字，避免持续触发布局。
    private func updateMetrics(_ fans: [FanReading]) {
        let names = metrics.map { $0.name }
        if names != fans.map(\.name) { rebuildMetrics(fans) }
        for (metric, fan) in zip(metrics, fans) {
            metric.update(fan.rpm.map { "\(Int($0.rounded())) RPM" } ?? "—")
        }
    }

    /// 按每行最多四列创建稳定网格，并同步区域高度以容纳多风扇机型。
    private func rebuildMetrics(_ fans: [FanReading]) {
        for row in rows.arrangedSubviews {
            rows.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        metrics = fans.map { FanMetric(name: $0.name, index: $0.index) }
        for start in stride(from: 0, to: metrics.count, by: 4) {
            let end = min(start + 4, metrics.count)
            let row = NSStackView(views: Array(metrics[start..<end]))
            row.distribution = .fillEqually
            row.spacing = 8
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        let rowCount = max(1, (metrics.count + 3) / 4)
        heightConstraint?.constant = 54 + CGFloat(rowCount - 1) * 39
    }
}

/// 一个风扇的紧凑双行指标，使用等宽数字避免采样刷新造成水平抖动。
private final class FanMetric: NSView {
    /// 稳定的用户可读名称，用于判断是否需要重建指标。
    let name: String
    /// 当前 RPM 文本，缺失读数显示破折号而不是零。
    private let value = NSTextField(labelWithString: "—")

    /// 创建名称和转速标签，并在悬停提示中保留对应 SMC 编号。
    init(name: String, index: Int) {
        self.name = name
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: name)
        title.font = .systemFont(ofSize: 10)
        title.textColor = .secondaryLabelColor
        value.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        value.lineBreakMode = .byTruncatingTail
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toolTip = "\(name)的当前实际转速，来自只读 AppleSMC F\(index)Ac。"
        let stack = NSStackView(views: [title, value])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        title.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        value.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    /// 指标仅接受代码初始化。
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 跳过相同转速文本，减少 SMC 更新较慢时的无意义重绘。
    func update(_ text: String) {
        if value.stringValue != text { value.stringValue = text }
    }
}
