import AppKit

/// 固定高度的电源区域，用六个轻量文本指标展示功率与电池信息，更多解释放在悬停提示中。
final class PowerPanelController: NSViewController {
    /// 电源概览复用现有二级浮窗的进入、退出、点击锁定交互，不改变指标布局。
    private let overview = ResourceHistoryOverviewView(frame: .zero)
    /// 指针进入电源区域时由父控制器显示历史详情。
    var onEnter: ((NSView) -> Void)?
    /// 指针离开时由共享协调器处理跨窗口关闭延迟。
    var onExit: ((NSView) -> Void)?
    /// 点击或键盘确认电源区域时锁定历史详情。
    var onActivate: ((NSView) -> Void)?
    /// 生命周期由主程序管理的按需电源模型。
    private let monitor: PowerMonitor
    /// 电量与供电状态共用标题行，避免占用额外说明行。
    private let stateLabel = NSTextField(labelWithString: "正在读取…")
    /// 实际输入功率，不把适配器标称能力当作实测功率。
    private let input = PowerMetric(title: "输入功率")
    /// 整机当前运行消耗，排除充入电池的部分。
    private let system = PowerMetric(title: "系统耗电")
    /// 按电池净功率方向切换标题，插电仍放电时也如实显示。
    private let battery = PowerMetric(title: "电池功率")
    /// 根据供电状态切换预计充满或剩余续航。
    private let remaining = PowerMetric(title: "预计充满")
    /// 外部电源的标称或协商能力。
    private let adapter = PowerMetric(title: "适配器")
    /// 合并展示容量健康估算与循环次数。
    private let health = PowerMetric(title: "健康 / 循环")

    /// 关联共享模型，不创建采样器或独立 UI 计时器。
    init(monitor: PowerMonitor) {
        self.monitor = monitor
        super.init(nibName: nil, bundle: nil)
    }

    /// 电源区域完全由代码布局。
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 两行三列等宽指标与一行状态，固定高度避免挤占排行的伸缩空间。
    override func loadView() {
        view = overview
        overview.frame = NSRect(x: 0, y: 0, width: 392, height: 104)
        overview.onEnter = { [weak self] anchor in self?.onEnter?(anchor) }
        overview.onExit = { [weak self] anchor in self?.onExit?(anchor) }
        overview.onActivate = { [weak self] anchor in self?.onActivate?(anchor) }
        let title = NSTextField(labelWithString: "电源")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        stateLabel.font = .systemFont(ofSize: 11); stateLabel.textColor = .secondaryLabelColor
        let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "电源趋势") ?? NSImage())
        chevron.contentTintColor = .tertiaryLabelColor
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        let header = NSStackView(views: [title, NSView(), stateLabel, chevron]); header.alignment = .centerY
        header.spacing = 6
        let first = NSStackView(views: [input, system, battery])
        let second = NSStackView(views: [remaining, adapter, health])
        first.distribution = .fillEqually; second.distribution = .fillEqually
        first.spacing = 8; second.spacing = 8
        let root = NSStackView(views: [header, first, second])
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 5
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor),
            view.heightAnchor.constraint(equalToConstant: 104)
        ])
        for row in root.arrangedSubviews { row.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        input.toolTip = "实际进入 Mac 的功率，包含系统运行与电池充电；不是插座侧实测功率。"
        system.toolTip = "整机当前耗电，包含 CPU、屏幕等负载；≈ 表示由有效电池功率推算。"
        battery.toolTip = "电池净功率：充入表示充电，放出表示放电。插电时也可能由电池补充供电。"
        remaining.toolTip = "macOS 根据当前负载与充电阶段估算；未提供有效时间时显示估算中。"
        adapter.toolTip = "适配器报告的标称或协商功率，不代表当前实际输入。"
        health.toolTip = "满充容量 / 设计容量的估算值，以及电池循环次数；可能与系统设置的校准值不同。"
    }

    /// 点击锁定历史详情时保持电源概览高亮；关闭一级弹窗后由父控制器清除。
    func setPinned(_ value: Bool) { overview.setPinned(value) }

    /// 单独刷新电源文本，系统没有数据或功率过期时保留破折号，不伪装成零。
    func refresh() {
        guard isViewLoaded else { return }
        guard let value = monitor.snapshot else {
            stateLabel.stringValue = "电源数据不可用"
            for metric in [input, system, battery, remaining, adapter, health] { metric.update("—") }
            overview.setAccessibilityValue("电源数据不可用，可查看电量历史")
            return
        }
        let percent = value.percent.map { "\($0)% · " } ?? ""
        let state = value.charged ? "已充满" : value.optimized ? "优化充电" : !value.external ? "电池供电"
            : value.charging ? "充电中" : "已接通电源"
        stateLabel.stringValue = percent + state
        stateLabel.toolTip = "每 \(monitor.interval) 秒读取，与网络和 CPU 共用采样间隔。" + (value.updatedAt.map {
            "系统电源数据更新于 \(DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .medium))；数值随系统采样更新。"
        } ?? "")
        input.update(powerText(value.inputWatts))
        system.update(powerText(value.systemWatts, estimated: value.estimated))
        battery.title.stringValue = value.batteryWatts.map { $0 < 0 ? "电池放电" : "电池充电" } ?? "电池功率"
        battery.update(powerText(value.batteryWatts.map(abs), estimated: value.estimated))
        battery.value.textColor = value.batteryWatts.map { $0 < 0 ? .systemOrange : .systemGreen } ?? .labelColor
        remaining.title.stringValue = value.external ? "预计充满" : "剩余续航"
        if value.charged && value.external { remaining.update("已充满") }
        else if value.optimized && value.external { remaining.update("已暂停") }
        else if value.external && !value.charging { remaining.update("未充电") }
        else { remaining.update(value.minutes.map(timeText) ?? "估算中") }
        adapter.update(powerText(value.adapterWatts, digits: 0))
        let capacity = value.health.map { "≈\($0)%" } ?? "—"
        health.update(capacity + (value.cycles.map { " · \($0) 次" } ?? ""))
        overview.setAccessibilityValue([stateLabel.stringValue, "输入功率 \(input.value.stringValue)",
            "系统耗电 \(system.value.stringValue)", "\(battery.title.stringValue) \(battery.value.stringValue)",
            "\(remaining.title.stringValue) \(remaining.value.stringValue)"].joined(separator: "，"))
    }

    /// 功率统一显示一位小数，近似计算明确带 ≈；nil 仍显示不可用。
    private func powerText(_ watts: Double?, estimated: Bool = false, digits: Int = 1) -> String {
        guard let watts else { return "—" }
        return (estimated ? "≈" : "") + String(format: "%.*f W", digits, watts)
    }

    /// 分钟估算使用简短小时 / 分钟格式，不制造秒级精度。
    private func timeText(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)时\(minutes % 60)分" : "\(minutes) 分钟"
    }
}

/// 电源与风扇共用的轻量历史入口，统一处理悬浮、键盘确认和点击锁定背景。
final class ResourceHistoryOverviewView: NSView {
    /// 指针进入时把真实视图边界作为二级浮窗锚点。
    var onEnter: ((NSView) -> Void)?
    /// 指针离开只通知共享协调器，不在本视图启动计时器。
    var onExit: ((NSView) -> Void)?
    /// 点击、Return 或空格均进入相同的详情锁定入口。
    var onActivate: ((NSView) -> Void)?
    /// 布局或滚动变化后替换的可见区域跟踪器。
    private var hoverTrackingArea: NSTrackingArea?
    /// 当前指针是否位于电源区域，仅用于绘制背景。
    private var hovering = false
    /// 当前历史详情是否已被用户点击锁定。
    private var pinned = false

    /// 初始化圆角背景、点击识别和辅助功能入口，不添加新的电源采样行为。
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true; layer?.cornerRadius = 6
        setAccessibilityElement(true); setAccessibilityRole(.button)
        setAccessibilityLabel("电源详情")
        setAccessibilityHelp("查看功率趋势和电量历史，点击锁定详情")
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(activate)))
    }

    /// 电源交互容器只通过代码创建。
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 未激活的菜单栏面板也允许一次点击锁定详情。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 允许键盘确认，与其他资源概览交互保持一致。
    override var acceptsFirstResponder: Bool { true }

    /// 按可见边界重建跟踪，滚动一级面板后仍能正确触发详情。
    override func updateTrackingAreas() {
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area); hoverTrackingArea = area
        super.updateTrackingAreas()
    }

    /// 进入电源区域后立即请求历史详情，背景提示当前交互锚点。
    override func mouseEntered(with event: NSEvent) {
        hovering = true; updateLayer(); onEnter?(self)
    }

    /// 离开电源区域只请求延迟关闭，保留跨入二级详情的时间。
    override func mouseExited(with event: NSEvent) {
        hovering = false; updateLayer(); onExit?(self)
    }

    /// Return 或空格锁定详情，Escape 等其余按键继续由现有窗口处理。
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { onActivate?(self) }
        else { super.keyDown(with: event) }
    }

    /// 动态系统色在当前外观下解析，深浅色切换后不会保留旧背景。
    override func updateLayer() {
        layer?.backgroundColor = hovering || pinned
            ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.10).cgColor : NSColor.clear.cgColor
    }

    /// 父协调器统一设置锁定状态，电源视图不自行改变其他详情选择。
    func setPinned(_ value: Bool) { pinned = value; updateLayer() }

    /// 单击先接收键盘焦点，再由父协调器锁定电源历史详情。
    @objc private func activate() { window?.makeFirstResponder(self); onActivate?(self) }
}

/// 可复用的紧凑指标，只保留标签与数字，长内容通过尾部省略和悬停提示处理。
private final class PowerMetric: NSView {
    /// 指标名称，可随充放电模式变化。
    let title: NSTextField
    /// 等宽数字，刷新时不因不同数字宽度发生抖动。
    let value = NSTextField(labelWithString: "—")

    /// 创建约 34pt 高的双行指标；宽度由三列表格等分。
    init(title: String) {
        self.title = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        self.title.font = .systemFont(ofSize: 10); self.title.textColor = .secondaryLabelColor
        value.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        value.lineBreakMode = .byTruncatingTail
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [self.title, value])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        for label in [self.title, value] { label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }

    /// 指标仅接受代码初始化。
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 跳过相同文本，减少采样未更新时的无意义绘制。
    func update(_ text: String) { if value.stringValue != text { value.stringValue = text } }
}
