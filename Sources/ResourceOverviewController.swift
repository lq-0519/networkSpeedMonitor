import AppKit

/// 一级弹窗中的资源标识；同一枚举同时用于概览刷新、悬浮切换和二级详情选择。
enum ResourceSection: CaseIterable {
    /// 网络总量与接口状态。
    case network
    /// 整机 CPU 占用与进程采集覆盖。
    case cpu
    /// 整机内存、使用比例与压力。
    case memory
    /// 系统盘容量与进程读写采集覆盖。
    case disk
    /// 系统已维护的可切换范围电量历史，不参与四类进程排行采样。
    case power
    /// 各物理风扇的轻量历史转速曲线。
    case fan

    /// 概览行使用的用户可读名称。
    var title: String {
        switch self {
        case .network: return "网络"
        case .cpu: return "CPU"
        case .memory: return "内存"
        case .disk: return "磁盘"
        case .power: return "电源"
        case .fan: return "风扇"
        }
    }

    /// 使用系统符号帮助快速区分资源，不引入额外图片资源。
    var symbolName: String {
        switch self {
        case .network: return "network"
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .disk: return "internaldrive"
        case .power: return "battery.100percent"
        case .fan: return "fan"
        }
    }
}

/// 可悬浮和点击的单个资源概览行；只呈现调用方提供的文本，不读取模型或触发采样。
final class ResourceOverviewRow: NSView {
    /// 指针进入时立即请求展示对应二级详情。
    var onEnter: ((ResourceOverviewRow) -> Void)?
    /// 指针离开时请求延迟关闭；真正的延迟由跨窗口协调器统一管理。
    var onExit: ((ResourceOverviewRow) -> Void)?
    /// 点击或键盘确认时展示详情，作为悬浮之外的辅助入口。
    var onActivate: ((ResourceOverviewRow) -> Void)?
    /// 当前行代表的资源类型，供父控制器选择详情页。
    let section: ResourceSection
    /// 标题右侧的短状态，例如实时、已授权或内存压力。
    private let stateLabel = NSTextField(labelWithString: "正在采样…")
    /// 当前资源最重要的数值。
    private let primaryLabel = NSTextField(labelWithString: "—")
    /// 与主数值同一行的补充数值。
    private let secondaryLabel = NSTextField(labelWithString: "")
    /// 接口、刷新周期和覆盖范围等补充信息。
    private let detailLabel = NSTextField(labelWithString: "正在采样…")
    /// CPU、内存与磁盘使用的比例条；网络行隐藏该控件。
    private let progress = NSLevelIndicator()
    /// 跟踪区域在布局变化后重建，确保滚动容器中的可见部分仍能正确响应。
    private var hoverTrackingArea: NSTrackingArea?
    /// 记录当前悬浮状态，用于动态系统颜色切换时恢复背景。
    private var hovering = false
    /// 点击锁定当前详情后保持选中背景，直到一级弹窗关闭。
    private var pinned = false

    /// 创建固定高度的宽松概览行，并设置点击、键盘和辅助功能入口。
    init(section: ResourceSection) {
        self.section = section
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(section.title)详情")

        let symbol = NSImage(systemSymbolName: section.symbolName, accessibilityDescription: section.title)
            ?? NSImage()
        let icon = NSImageView(image: symbol)
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        icon.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: section.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        stateLabel.font = .systemFont(ofSize: 11, weight: .medium)
        stateLabel.textColor = .secondaryLabelColor
        let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.right",
                                                 accessibilityDescription: "查看详情") ?? NSImage())
        chevron.contentTintColor = .tertiaryLabelColor
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        chevron.translatesAutoresizingMaskIntoConstraints = false
        let header = NSStackView(views: [icon, title, NSView(), stateLabel, chevron])
        header.alignment = .centerY
        header.spacing = 6

        primaryLabel.font = .monospacedDigitSystemFont(ofSize: section == .network ? 20 : 14,
                                                        weight: .semibold)
        primaryLabel.lineBreakMode = .byTruncatingTail
        primaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        secondaryLabel.font = section == .network
            ? .monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
            : .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        secondaryLabel.textColor = section == .network ? .labelColor : .secondaryLabelColor
        secondaryLabel.lineBreakMode = .byTruncatingTail
        secondaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let values = section == .network
            ? NSStackView(views: [primaryLabel, secondaryLabel])
            : NSStackView(views: [primaryLabel, NSView(), secondaryLabel])
        values.alignment = .firstBaseline
        values.spacing = 8
        if section == .network { values.distribution = .fillEqually }

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.maximumNumberOfLines = 1
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        progress.levelIndicatorStyle = .continuousCapacity
        progress.minValue = 0
        progress.maxValue = 100
        progress.warningValue = 80
        progress.criticalValue = 95
        progress.isHidden = section == .network
        progress.translatesAutoresizingMaskIntoConstraints = false

        let root = NSStackView(views: [header, values, detailLabel, progress])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 4
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: section == .network ? 88 : 96),
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            root.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            root.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            chevron.widthAnchor.constraint(equalToConstant: 10),
            chevron.heightAnchor.constraint(equalToConstant: 14),
            progress.heightAnchor.constraint(equalToConstant: 5)
        ])
        for child in root.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(activate)))
        updateLayer()
    }

    /// 概览行完全由代码创建。
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 允许点击未激活的菜单栏弹窗时直接打开详情，不要求先激活应用。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 概览行可接收 Return、空格和 Escape 等键盘事件。
    override var acceptsFirstResponder: Bool { true }

    /// 布局或滚动可见区域变化后重建跟踪范围，保证进入事件没有人工延迟。
    override func updateTrackingAreas() {
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
        super.updateTrackingAreas()
    }

    /// 指针进入即通知协调器显示详情，并使用轻量背景明确当前锚点。
    override func mouseEntered(with event: NSEvent) {
        hovering = true
        updateLayer()
        onEnter?(self)
    }

    /// 指针离开只发出关闭请求，允许协调器为跨窗口间隙保留短暂通道。
    override func mouseExited(with event: NSEvent) {
        hovering = false
        updateLayer()
        onExit?(self)
    }

    /// Return 或空格触发与鼠标点击相同的详情入口，其余按键交回系统处理。
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 {
            onActivate?(self)
        } else {
            super.keyDown(with: event)
        }
    }

    /// 外观变化时重新解析动态系统色，避免深浅色切换后保留旧 CGColor。
    override func updateLayer() {
        layer?.backgroundColor = hovering || pinned
            ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.10).cgColor
            : NSColor.clear.cgColor
    }

    /// 同步当前会话的详情锁定状态，仅影响概览背景，不改变采样或数据。
    func setPinned(_ value: Bool) {
        guard pinned != value else { return }
        pinned = value
        updateLayer()
    }

    /// 更新当前快照文本和可选比例；nil 比例隐藏进度条，不把缺失数据显示为零。
    func update(primary: String, secondary: String, detail: String, state: String,
                stateColor: NSColor = .secondaryLabelColor, percent: Double? = nil) {
        primaryLabel.stringValue = primary
        secondaryLabel.stringValue = secondary
        detailLabel.stringValue = detail
        detailLabel.toolTip = detail
        stateLabel.stringValue = state
        stateLabel.textColor = stateColor
        progress.isHidden = percent == nil
        if let percent, percent.isFinite {
            progress.doubleValue = min(100, max(0, percent))
            progress.toolTip = String(format: "已使用 %.1f%%", percent)
        }
        setAccessibilityValue([primary, secondary, state, detail].filter { !$0.isEmpty }.joined(separator: "，"))
    }

    /// 点击识别器只负责转发，不改变模型可见性或启动任何采样器。
    @objc private func activate() {
        window?.makeFirstResponder(self)
        onActivate?(self)
    }
}

/// CPU 与内存共用的圆形占用图；只绘制当前比例，不保存历史曲线或创建动画计时器。
private final class ResourceUsagePieView: NSView {
    /// 圆环中心显示整数百分比，避免用户在图形和文字之间来回寻找主数值。
    private let percentLabel = NSTextField(labelWithString: "—")
    /// 当前占用比例，绘制时限制在零到一百。
    private var percent: Double?
    /// CPU 和内存使用不同系统色，两个并列图仍可快速区分。
    private var accentColor: NSColor = .systemGreen

    /// 创建固定 78pt 的圆形图，并把百分比文本稳定居中。
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        percentLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        percentLabel.alignment = .center
        percentLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(percentLabel)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 78),
            heightAnchor.constraint(equalToConstant: 78),
            percentLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            percentLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            percentLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -12)
        ])
    }

    /// 圆形图完全使用代码创建。
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 更新比例和强调色；nil 显示不可用状态，而不是绘制零占用。
    func update(percent: Double?, color: NSColor) {
        self.percent = percent.map { min(100, max(0, $0)) }
        accentColor = color
        percentLabel.stringValue = self.percent.map { String(format: "%.0f%%", $0) } ?? "—"
        needsDisplay = true
    }

    /// 绘制背景圆环和当前占用弧线，线宽固定避免数字变化引起布局抖动。
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let circle = bounds.insetBy(dx: 8, dy: 8)
        let background = NSBezierPath(ovalIn: circle)
        background.lineWidth = 8
        NSColor.tertiaryLabelColor.withAlphaComponent(0.35).setStroke()
        background.stroke()
        guard let percent, percent > 0 else { return }
        let radius = circle.width / 2
        let progress = NSBezierPath()
        progress.appendArc(withCenter: NSPoint(x: bounds.midX, y: bounds.midY),
                           radius: radius, startAngle: 90,
                           endAngle: 90 - 360 * percent / 100, clockwise: true)
        progress.lineWidth = 8
        progress.lineCapStyle = .round
        accentColor.setStroke()
        progress.stroke()
    }
}

/// CPU 或内存的半宽概览块；两个块在同一行并列，各自保留独立悬浮详情入口。
private final class ResourceUsageTile: NSView {
    /// 指针进入时立即展示该资源的二级详情。
    var onEnter: ((ResourceUsageTile) -> Void)?
    /// 指针离开后交给二级协调器执行跨窗口延迟。
    var onExit: ((ResourceUsageTile) -> Void)?
    /// 点击或键盘确认时展示并激活详情。
    var onActivate: ((ResourceUsageTile) -> Void)?
    /// 当前半宽块对应 CPU 或内存。
    let section: ResourceSection
    /// 圆形占用图承担该资源的第一视觉层级。
    private let pie = ResourceUsagePieView(frame: .zero)
    /// 标题右侧显示授权或压力等短状态。
    private let stateLabel = NSTextField(labelWithString: "正在采样…")
    /// 第一行关键数值，例如整机占用或已用内存。
    private let primaryLabel = NSTextField(labelWithString: "—")
    /// 第二行补充用户态 / 系统态或物理总量。
    private let secondaryLabel = NSTextField(labelWithString: "—")
    /// 最后一行展示采样周期与覆盖范围。
    private let detailLabel = NSTextField(labelWithString: "正在采样…")
    /// 视图在窗口内移动后需要更新的指针跟踪区域。
    private var hoverTrackingArea: NSTrackingArea?
    /// 当前悬浮状态用于绘制轻量背景。
    private var hovering = false
    /// 当前详情被点击锁定后保持选中背景。
    private var pinned = false

    /// 创建半宽资源块，使用系统符号和统一文字层级。
    init(section: ResourceSection) {
        self.section = section
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(section.title)详情")

        let icon = NSImageView(image: NSImage(systemSymbolName: section.symbolName,
                                              accessibilityDescription: section.title) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        icon.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: section.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        stateLabel.font = .systemFont(ofSize: 10, weight: .medium)
        stateLabel.textColor = .secondaryLabelColor
        stateLabel.lineBreakMode = .byTruncatingTail
        stateLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.right",
                                                 accessibilityDescription: "查看详情") ?? NSImage())
        chevron.contentTintColor = .tertiaryLabelColor
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        chevron.translatesAutoresizingMaskIntoConstraints = false
        let header = NSStackView(views: [icon, title, NSView(), stateLabel, chevron])
        header.alignment = .centerY
        header.spacing = 5

        primaryLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        secondaryLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        secondaryLabel.textColor = .secondaryLabelColor
        detailLabel.font = .systemFont(ofSize: 10)
        detailLabel.textColor = .secondaryLabelColor
        for label in [primaryLabel, secondaryLabel, detailLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        for label in [primaryLabel, secondaryLabel, detailLabel] {
            label.alignment = .center
        }
        let labels = NSStackView(views: [primaryLabel, secondaryLabel, detailLabel])
        labels.orientation = .vertical
        labels.alignment = .centerX
        labels.spacing = 3
        for label in labels.arrangedSubviews {
            label.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true
        }
        let root = NSStackView(views: [header, pie, labels])
        root.orientation = .vertical
        root.alignment = .centerX
        root.spacing = 6
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 184),
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            root.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            root.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
            icon.widthAnchor.constraint(equalToConstant: 15),
            icon.heightAnchor.constraint(equalToConstant: 15),
            chevron.widthAnchor.constraint(equalToConstant: 9),
            chevron.heightAnchor.constraint(equalToConstant: 13),
            header.widthAnchor.constraint(equalTo: root.widthAnchor),
            labels.widthAnchor.constraint(equalTo: root.widthAnchor)
        ])
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(activate)))
        updateLayer()
    }

    /// 半宽资源块完全使用代码创建。
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 未激活的菜单栏弹窗也可一次点击打开详情。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 支持键盘确认详情。
    override var acceptsFirstResponder: Bool { true }

    /// 资源块尺寸变化后重建指针跟踪区域。
    override func updateTrackingAreas() {
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
        super.updateTrackingAreas()
    }

    /// 指针进入时立即打开 CPU 或内存详情。
    override func mouseEntered(with event: NSEvent) {
        hovering = true
        updateLayer()
        onEnter?(self)
    }

    /// 指针离开时启动跨窗口关闭延迟。
    override func mouseExited(with event: NSEvent) {
        hovering = false
        updateLayer()
        onExit?(self)
    }

    /// Return 或空格触发详情，其余按键保留系统默认行为。
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 {
            onActivate?(self)
        } else {
            super.keyDown(with: event)
        }
    }

    /// 深浅色或悬浮状态变化时更新动态背景。
    override func updateLayer() {
        layer?.backgroundColor = hovering || pinned
            ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.10).cgColor
            : NSColor.clear.cgColor
    }

    /// 同步当前会话的详情锁定状态，仅改变选中外观。
    func setPinned(_ value: Bool) {
        guard pinned != value else { return }
        pinned = value
        updateLayer()
    }

    /// 同步圆形比例、三行摘要和状态色，不触发任何底层采样。
    func update(percent: Double?, primary: String, secondary: String, detail: String,
                state: String, stateColor: NSColor, accentColor: NSColor) {
        pie.update(percent: percent, color: accentColor)
        primaryLabel.stringValue = primary
        secondaryLabel.stringValue = secondary
        detailLabel.stringValue = detail
        detailLabel.toolTip = detail
        stateLabel.stringValue = state
        stateLabel.textColor = stateColor
        setAccessibilityValue([primary, secondary, state, detail].joined(separator: "，"))
    }

    /// 点击识别器转发当前资源，不改变模型可见性。
    @objc private func activate() {
        window?.makeFirstResponder(self)
        onActivate?(self)
    }
}

/// 一级弹窗的资源概览控制器；CPU/内存与网络位于顶部，磁盘由总面板放在电源与风扇之间。
final class ResourceOverviewController: NSViewController {
    /// 网络总量和接口信息来自全应用唯一的网络模型。
    private let network: NetworkMonitor
    /// CPU 整机数据和采集覆盖来自全应用唯一的 CPU 模型。
    private let cpu: CPUMonitor
    /// 内存整机数据和进程覆盖来自 CPU 同轮快照。
    private let memory: MemoryMonitor
    /// 磁盘容量和进程覆盖来自 CPU 同轮快照。
    private let disk: DiskMonitor
    /// 网络上传与下载使用同字号的等宽双列概览。
    private let networkRow = ResourceOverviewRow(section: .network)
    /// CPU 半宽概览以圆形占用图展示整机比例。
    private let cpuTile = ResourceUsageTile(section: .cpu)
    /// 内存半宽概览与 CPU 并列展示已用比例。
    private let memoryTile = ResourceUsageTile(section: .memory)
    /// 磁盘继续使用完整宽度，以容纳总量和剩余容量。
    private let diskRow = ResourceOverviewRow(section: .disk)
    /// 磁盘排在电源之后、风扇之前，因此由总面板单独插入对应位置。
    var diskView: NSView { diskRow }
    /// 指针进入概览行时立即展示对应详情。
    var onEnter: ((ResourceSection, NSView) -> Void)?
    /// 指针离开概览行时开始跨窗口关闭延迟。
    var onExit: ((ResourceSection, NSView) -> Void)?
    /// 点击或键盘确认时展示并激活对应详情。
    var onActivate: ((ResourceSection, NSView) -> Void)?

    /// 创建四类概览行并保存模型引用；初始化不会触发采样。
    init(network: NetworkMonitor, cpu: CPUMonitor, memory: MemoryMonitor, disk: DiskMonitor) {
        self.network = network
        self.cpu = cpu
        self.memory = memory
        self.disk = disk
        super.init(nibName: nil, bundle: nil)
    }

    /// 概览完全使用代码布局。
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 使用网络、CPU/内存双饼和磁盘三段式布局，减少纵向占用并强化信息层级。
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 392, height: 273))
        networkRow.onEnter = { [weak self] row in self?.onEnter?(.network, row) }
        networkRow.onExit = { [weak self] row in self?.onExit?(.network, row) }
        networkRow.onActivate = { [weak self] row in self?.onActivate?(.network, row) }
        diskRow.onEnter = { [weak self] row in self?.onEnter?(.disk, row) }
        diskRow.onExit = { [weak self] row in self?.onExit?(.disk, row) }
        diskRow.onActivate = { [weak self] row in self?.onActivate?(.disk, row) }
        cpuTile.onEnter = { [weak self] tile in self?.onEnter?(.cpu, tile) }
        cpuTile.onExit = { [weak self] tile in self?.onExit?(.cpu, tile) }
        cpuTile.onActivate = { [weak self] tile in self?.onActivate?(.cpu, tile) }
        memoryTile.onEnter = { [weak self] tile in self?.onEnter?(.memory, tile) }
        memoryTile.onExit = { [weak self] tile in self?.onExit?(.memory, tile) }
        memoryTile.onActivate = { [weak self] tile in self?.onActivate?(.memory, tile) }

        let middleDivider = NSBox()
        middleDivider.boxType = .separator
        let usageRow = NSStackView(views: [cpuTile, memoryTile])
        usageRow.orientation = .horizontal
        usageRow.alignment = .top
        usageRow.spacing = 1
        usageRow.distribution = .fillEqually
        middleDivider.translatesAutoresizingMaskIntoConstraints = false
        usageRow.addSubview(middleDivider)
        NSLayoutConstraint.activate([
            middleDivider.centerXAnchor.constraint(equalTo: usageRow.centerXAnchor),
            middleDivider.topAnchor.constraint(equalTo: usageRow.topAnchor),
            middleDivider.bottomAnchor.constraint(equalTo: usageRow.bottomAnchor),
            middleDivider.widthAnchor.constraint(equalToConstant: 1)
        ])

        let firstDivider = NSBox()
        firstDivider.boxType = .separator
        let root = NSStackView(views: [usageRow, firstDivider, networkRow])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        for child in root.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            firstDivider.heightAnchor.constraint(equalToConstant: 1),
            usageRow.heightAnchor.constraint(equalToConstant: 184),
            view.heightAnchor.constraint(equalToConstant: 273)
        ])
    }

    /// 点击锁定详情时保持对应概览高亮；nil 在一级弹窗关闭后清除全部锁定状态。
    func setPinnedSection(_ section: ResourceSection?) {
        cpuTile.setPinned(section == .cpu)
        memoryTile.setPinned(section == .memory)
        networkRow.setPinned(section == .network)
        diskRow.setPinned(section == .disk)
    }

    /// 更新网络速度、活动接口、实时状态和统一采样周期。
    func refreshNetwork() {
        guard isViewLoaded else { return }
        let statusColor: NSColor = network.status == "实时" ? .systemGreen : .secondaryLabelColor
        let source = network.sourceDescription.components(separatedBy: " · ").first
            ?? network.sourceDescription
        networkRow.update(
            primary: "↓ 下载  \(network.download.map(SpeedText.string) ?? "—")",
            secondary: "↑ 上传  \(network.upload.map(SpeedText.string) ?? "—")",
            detail: source,
            state: network.status == "实时" ? "● 实时" : network.status,
            stateColor: statusColor
        )
    }

    /// 更新整机 CPU、用户态、系统态、采样周期和实际进程覆盖。
    func refreshCPU() {
        guard isViewLoaded else { return }
        let privilege = cpu.isRankingStale ? "结果已过期" : cpu.collectionStatus.summary
            ?? (cpu.privileged ? "已授权" : "部分进程")
        guard let usage = cpu.usage else {
            cpuTile.update(percent: nil, primary: "整体占用 —", secondary: "用户 — · 系统 —",
                           detail: privilege,
                           state: cpu.rankingStatus, stateColor: .secondaryLabelColor,
                           accentColor: .systemTeal)
            return
        }
        let coverage = cpu.isRankingStale ? "最近结果已过期，正在恢复采集"
            : cpu.collectionStatus.summary ?? (cpu.readableProcesses > 0 ? "已读 \(cpu.readableProcesses) 个进程" : privilege)
        cpuTile.update(
            percent: usage.total,
            primary: String(format: "整体占用 %.0f%%", usage.total),
            secondary: String(format: "用户 %.1f%% · 系统 %.1f%%", usage.user, usage.system),
            detail: coverage,
            state: privilege,
            stateColor: cpu.isRankingStale || cpu.collectionStatus.preservesResult ? .systemOrange
                : cpu.privileged ? .systemGreen : .secondaryLabelColor,
            accentColor: .systemTeal
        )
    }

    /// 更新已用和物理总量、使用比例、内存压力与排行覆盖状态。
    func refreshMemory() {
        guard isViewLoaded else { return }
        let coverage = memoryCoverage
        guard let usage = memory.systemUsage, usage.totalBytes > 0 else {
            memoryTile.update(percent: nil, primary: "已用 —", secondary: "总量 —",
                              detail: coverage,
                              state: "压力 —", stateColor: .secondaryLabelColor,
                              accentColor: .systemOrange)
            return
        }
        let percent = Double(usage.usedBytes) / Double(usage.totalBytes) * 100
        let pressureColor: NSColor
        switch usage.pressure {
        case .normal: pressureColor = .systemGreen
        case .warning: pressureColor = .systemOrange
        case .critical: pressureColor = .systemRed
        case .unknown: pressureColor = .secondaryLabelColor
        }
        memoryTile.update(
            percent: percent,
            primary: "已用 \(MemoryText.string(usage.usedBytes))",
            secondary: "总量 \(MemoryText.string(usage.totalBytes))",
            detail: coverage,
            state: "压力 \(usage.pressure.title)",
            stateColor: pressureColor,
            accentColor: .systemOrange
        )
    }

    /// 更新系统盘已用、总量、剩余、容量比例与进程读写覆盖状态。
    func refreshDisk() {
        guard isViewLoaded else { return }
        let coverage = diskCoverage
        guard let capacity = disk.capacity else {
            diskRow.update(primary: "已用 — / 总量 —", secondary: "剩余 —",
                           detail: coverage,
                           state: "容量暂不可用")
            return
        }
        diskRow.update(
            primary: "已用 \(DiskCapacity.text(capacity.used)) / 总量 \(DiskCapacity.text(capacity.total))",
            secondary: "剩余 \(DiskCapacity.text(capacity.free))",
            detail: String(format: "已使用 %.1f%%", capacity.usedPercent),
            state: coverage,
            stateColor: disk.isRankingStale || disk.collectionStatus.preservesResult ? .systemOrange
                : disk.privileged && disk.supported ? .systemGreen : .secondaryLabelColor,
            percent: capacity.usedPercent
        )
    }

    /// 将内存快照的实际能力整理成一级可读短语，不根据安装文件猜测当前权限。
    private var memoryCoverage: String {
        if memory.isRankingStale { return "最近结果已过期，正在恢复采集" }
        if let summary = memory.collectionStatus.summary { return summary }
        if memory.privileged {
            return memory.deniedProcesses > 0 ? "\(memory.deniedProcesses) 个受保护" : "管理员采集"
        }
        return "部分进程"
    }

    /// 将磁盘快照的授权和协议状态整理成一级可读短语。
    private var diskCoverage: String {
        if disk.isRankingStale { return "结果已过期" }
        if let summary = disk.collectionStatus.summary { return summary }
        return disk.deniedProcesses > 0 ? "\(disk.deniedProcesses) 个受保护" : "管理员采集"
    }
}
