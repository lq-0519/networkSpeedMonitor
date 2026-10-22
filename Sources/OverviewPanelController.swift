import AppKit

/// 一级弹窗固定展示电源、风扇和四类资源概览；排行榜由悬浮触发的唯一二级浮层承载。
final class OverviewPanelController: NSViewController {
    /// 电源指标独立刷新，不重建网络或 CPU 列表。
    private let powerPanel: PowerPanelController
    /// 电量历史随电源详情按需读取系统数据库，直接显示在功率趋势上方，不参与实时功率采样。
    private let powerHistoryPanel: PowerHistoryPanelController
    /// 风扇指标与电源共用快照通知，无风扇机型由子控制器自动折叠。
    private let fanPanel: FanPanelController
    /// 网络详情仅接收网络模型更新，CPU 刷新不会重建网络列表。
    private let networkPanel: PanelController
    /// CPU 详情保留排行版本控制，网络刷新不会重建 CPU 列表。
    private let cpuPanel: CPUPanelController
    /// 内存概览与趋势共享整机读取，软件排行继续复用 CPU 进程快照。
    private let memoryPanel: MemoryPanelController
    /// 磁盘容量与趋势共享轻量读取，应用排行继续使用 CPU 进程快照。
    private let diskPanel: DiskPanelController
    /// 四类一级概览只读取现有模型快照，不持有定时器或进程采集器。
    private let resourceOverview: ResourceOverviewController
    /// 单一二级浮层复用资源详情控制器，并管理跨窗口悬浮通道。
    private lazy var detailCoordinator = ResourceDetailCoordinator(controllers: trendPanels.mapValues { $0 as NSViewController })
    /// 每类资源共用趋势包装器，原排行作为子控制器继续保留自己的滚动与授权入口。
    private let trendPanels: [ResourceSection: ResourceTrendController]
    /// 设置操作由主程序协调关闭弹窗和停止详情采样。
    var onSettings: (() -> Void)?
    /// CPU 管理员授权继续通过系统安装流程完成。
    var onAuthorize: (() -> Void)?
    /// 跳转到系统活动监视器前，由主程序关闭弹窗并停止详情采集。
    var onActivityMonitor: ((URL) -> Void)?
    /// 可见内容高度变化时通知主程序同步弹窗，不再提供手动拖动高度入口。
    var onContentSizeChange: ((NSSize) -> Void)?
    /// 不含滚动容器或空白占位的内容栈，按实际可见模块计算自然高度。
    private let contentStack = NSStackView()
    /// 最近发布的尺寸，转速数值刷新而行数不变时不会重复调整窗口。
    private var lastContentSize: NSSize?
    /// 系统应用位置按 Bundle ID 解析，图标与实际打开目标使用同一个 URL。
    private let activityMonitorURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor")
    /// 一级概览沿用 420pt 宽度，高度完全由可见内容和必要边距决定。
    static let panelWidth: CGFloat = 420
    /// 内容顶部与浮层边界的固定间距。
    private static let topInset: CGFloat = 12
    /// 底部操作栏与浮层边界的固定间距，不再为拖动横条预留区域。
    private static let bottomInset: CGFloat = 14
    /// 最后一个可见模块与底部操作栏之间的间距。
    private static let footerGap: CGFloat = 12
    /// 设置、活动监视器和退出按钮占用的固定操作栏高度。
    private static let footerHeight: CGFloat = 24

    /// 直接使用内容栈的 Auto Layout 自然高度，隐藏模块不会保留高度或滚动空间。
    var fittingContentSize: NSSize {
        _ = view
        let height = ceil(contentStack.fittingSize.height + Self.topInset + Self.footerGap
            + Self.footerHeight + Self.bottomInset)
        return NSSize(width: Self.panelWidth, height: height)
    }

    /// 组合现有采集模型，不额外创建定时器或采样器。
    init(network: NetworkMonitor, cpu: CPUMonitor, power: PowerMonitor, memory: MemoryMonitor, disk: DiskMonitor,
         history: TrendHistoryStore) {
        powerPanel = PowerPanelController(monitor: power)
        fanPanel = FanPanelController(monitor: power)
        let powerHistoryPanel = PowerHistoryPanelController()
        self.powerHistoryPanel = powerHistoryPanel
        let networkPanel = PanelController(monitor: network)
        let cpuPanel = CPUPanelController(monitor: cpu)
        let memoryPanel = MemoryPanelController(monitor: memory)
        let diskPanel = DiskPanelController(monitor: disk)
        self.networkPanel = networkPanel; self.cpuPanel = cpuPanel
        self.memoryPanel = memoryPanel; self.diskPanel = diskPanel
        resourceOverview = ResourceOverviewController(network: network, cpu: cpu, memory: memory, disk: disk)
        trendPanels = [
            .network: ResourceTrendController(section: .network, history: history, ranking: networkPanel),
            .cpu: ResourceTrendController(section: .cpu, history: history, ranking: cpuPanel),
            .memory: ResourceTrendController(section: .memory, history: history, ranking: memoryPanel),
            .disk: ResourceTrendController(section: .disk, history: history, ranking: diskPanel),
            .power: ResourceTrendController(section: .power, history: history, batteryHistory: powerHistoryPanel),
            .fan: ResourceTrendController(section: .fan, history: history)
        ]
        super.init(nibName: nil, bundle: nil)
    }

    /// 统一面板完全使用代码布局。
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 一级顺序为 CPU/内存、网络、电源、磁盘、风扇；直接布局，不创建一级滚动或拖动区域。
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 0))
        addChild(powerPanel)
        addChild(fanPanel)
        addChild(resourceOverview)
        fanPanel.onLayoutChange = { [weak self] in self?.updateContentSize() }
        cpuPanel.onAuthorize = { [weak self] in self?.onAuthorize?() }
        memoryPanel.onAuthorize = { [weak self] in self?.onAuthorize?() }
        diskPanel.onAuthorize = { [weak self] in self?.onAuthorize?() }
        powerPanel.onEnter = { [weak self] anchor in
            guard let self else { return }
            detailCoordinator.present(.power, anchoredTo: anchor, relativeTo: view)
        }
        powerPanel.onExit = { [weak self] _ in self?.detailCoordinator.scheduleDismiss() }
        powerPanel.onActivate = { [weak self] anchor in
            guard let self else { return }
            detailCoordinator.present(.power, anchoredTo: anchor, relativeTo: view, activate: true)
        }
        fanPanel.onEnter = { [weak self] anchor in
            guard let self else { return }
            detailCoordinator.present(.fan, anchoredTo: anchor, relativeTo: view)
        }
        fanPanel.onExit = { [weak self] _ in self?.detailCoordinator.scheduleDismiss() }
        fanPanel.onActivate = { [weak self] anchor in
            guard let self else { return }
            detailCoordinator.present(.fan, anchoredTo: anchor, relativeTo: view, activate: true)
        }
        resourceOverview.onEnter = { [weak self] section, anchor in
            guard let self else { return }
            detailCoordinator.present(section, anchoredTo: anchor, relativeTo: view)
        }
        resourceOverview.onExit = { [weak self] _, _ in self?.detailCoordinator.scheduleDismiss() }
        resourceOverview.onActivate = { [weak self] section, anchor in
            guard let self else { return }
            detailCoordinator.present(section, anchoredTo: anchor, relativeTo: view, activate: true)
        }
        detailCoordinator.onPresent = { [weak self] section in self?.refreshDetail(section) }
        detailCoordinator.onDismiss = { [weak self] section in self?.releaseDetail(section) }
        detailCoordinator.onPinChange = { [weak self] section in
            self?.resourceOverview.setPinnedSection(section)
            self?.powerPanel.setPinned(section == .power)
            self?.fanPanel.setPinned(section == .fan)
        }
        let resourceDivider = NSBox(); resourceDivider.boxType = .separator
        let diskDivider = NSBox(); diskDivider.boxType = .separator
        let settings = NSButton(title: "设置…", target: self, action: #selector(openSettings))
        settings.bezelStyle = .rounded
        settings.controlSize = .small
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "设置")
        settings.imagePosition = .imageLeading
        let activityMonitor = NSButton(title: "", target: self, action: #selector(openActivityMonitor))
        activityMonitor.isBordered = false
        activityMonitor.imagePosition = .imageOnly
        activityMonitor.imageScaling = .scaleProportionallyDown
        activityMonitor.toolTip = "打开活动监视器"
        activityMonitor.setAccessibilityLabel("打开活动监视器")
        activityMonitor.isEnabled = activityMonitorURL != nil
        if let url = activityMonitorURL {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 22, height: 22)
            activityMonitor.image = icon
        }
        NSLayoutConstraint.activate([
            activityMonitor.widthAnchor.constraint(equalToConstant: 24),
            activityMonitor.heightAnchor.constraint(equalToConstant: 24)
        ])
        let quit = NSButton(title: "退出", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.bezelStyle = .rounded
        quit.controlSize = .small
        let footer = NSStackView(views: [settings, activityMonitor, NSView(), quit])
        footer.alignment = .centerY; footer.spacing = 10
        let root = contentStack
        for module in [resourceOverview.view, resourceDivider, powerPanel.view, diskDivider,
                       resourceOverview.diskView, fanPanel.view] { root.addArrangedSubview(module) }
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 5
        root.detachesHiddenViews = true
        root.translatesAutoresizingMaskIntoConstraints = false
        footer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root); view.addSubview(footer)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: Self.topInset),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Self.bottomInset),
            resourceDivider.heightAnchor.constraint(equalToConstant: 1),
            diskDivider.heightAnchor.constraint(equalToConstant: 1),
            footer.heightAnchor.constraint(equalToConstant: Self.footerHeight)
        ])
        for child in root.arrangedSubviews { child.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        let size = fittingContentSize
        view.setFrameSize(size); lastContentSize = size
    }

    /// 仅在风扇显隐或行数改变时重新计算尺寸；同步窗口后重新定位已经打开的二级浮窗。
    private func updateContentSize() {
        guard isViewLoaded else { return }
        let size = fittingContentSize
        guard size != lastContentSize else { return }
        lastContentSize = size
        onContentSizeChange?(size)
        view.layoutSubtreeIfNeeded()
        detailCoordinator.reposition()
    }

    /// 刷新一级网络概览；仅当网络详情可见时才重建其表格。
    func refreshNetwork() {
        guard isViewLoaded else { return }
        resourceOverview.refreshNetwork()
        if detailCoordinator.visibleSection == .network { networkPanel.refresh() }
    }

    /// 刷新一级 CPU 概览；隐藏的 CPU 排行不解析图标或重建 outline。
    func refreshCPU() {
        guard isViewLoaded else { return }
        resourceOverview.refreshCPU()
        if detailCoordinator.visibleSection == .cpu { cpuPanel.refresh() }
    }

    /// 刷新一级内存概览；内存详情只消费已经采集好的当前快照。
    func refreshMemory() {
        guard isViewLoaded else { return }
        resourceOverview.refreshMemory()
        if detailCoordinator.visibleSection == .memory { memoryPanel.refresh() }
    }

    /// 电源更新只触达固定指标区域，菜单栏与四类排行均不受影响。
    func refreshPower() { guard isViewLoaded else { return }; powerPanel.refresh() }

    /// 风扇更新只刷新紧凑转速区域，并按实际硬件数量控制显示。
    func refreshFans() { guard isViewLoaded else { return }; fanPanel.refresh() }

    /// 刷新一级磁盘概览；隐藏的磁盘排行不产生表格渲染成本。
    func refreshDisk() {
        guard isViewLoaded else { return }
        resourceOverview.refreshDisk()
        if detailCoordinator.visibleSection == .disk { diskPanel.refresh() }
    }

    /// 历史样本仅交给当前可见二级页面，后台和其他资源不整理曲线或重绘。
    func receiveTrend(_ sample: TrendSample) {
        guard isViewLoaded, let section = detailCoordinator.visibleSection else { return }
        trendPanels[section]?.receive(sample)
    }

    /// 立即关闭二级浮层，供 Escape、一级关闭和外部操作统一调用。
    func closeDetail() { detailCoordinator.dismiss() }

    /// Escape 优先关闭已经显示的二级详情；返回 false 时调用方再关闭一级弹窗。
    func closeDetailIfVisible() -> Bool {
        guard detailCoordinator.visibleSection != nil else { return false }
        detailCoordinator.dismiss()
        return true
    }

    /// 判断事件窗口是否为当前二级浮层，避免详情交互被一级的外部点击逻辑关闭。
    func ownsDetailWindow(_ window: NSWindow?) -> Bool { detailCoordinator.owns(window: window) }

    /// 收起一级时释放四类排行、图标和可见曲线缓存，后台只保留精简整机采样。
    func releaseRanking() {
        guard isViewLoaded else { return }
        detailCoordinator.dismiss()
        trendPanels.values.forEach { $0.resetRange() }
        networkPanel.releaseRanking(); cpuPanel.releaseRanking()
        memoryPanel.releaseRanking(); diskPanel.releaseRanking()
    }

    /// 二级浮层刚展示时按资源类型刷新已有快照，不修改任何模型的可见性。
    private func refreshDetail(_ section: ResourceSection) {
        trendPanels[section]?.setVisible(true)
        switch section {
        case .network: networkPanel.refresh()
        case .cpu: cpuPanel.refresh()
        case .memory: memoryPanel.refresh()
        case .disk: diskPanel.refresh()
        case .power, .fan: break
        }
    }

    /// 详情被隐藏或替换时只释放对应视图缓存，模型中的有界排行继续随一级采样更新。
    private func releaseDetail(_ section: ResourceSection) {
        trendPanels[section]?.setVisible(false)
        switch section {
        case .network: networkPanel.releaseRanking()
        case .cpu: cpuPanel.releaseRanking()
        case .memory: memoryPanel.releaseRanking()
        case .disk: diskPanel.releaseRanking()
        case .power, .fan: break
        }
    }

    /// 将唯一设置入口交给主应用，保持授权与登录项状态一致。
    @objc private func openSettings() { onSettings?() }

    /// 复用加载图标时已解析的系统应用路径；不启动额外采集或定时任务。
    @objc private func openActivityMonitor() {
        guard let url = activityMonitorURL else { return }
        onActivityMonitor?(url)
    }
}
