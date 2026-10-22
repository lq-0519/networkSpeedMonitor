import AppKit

/// 内存排行的原生 outline 节点；稳定软件键用于在周期刷新时保持展开状态。
final class MemoryOutlineItem: NSObject {
    /// 软件行保存 footprint 聚合信息；进程子行保持 nil。
    var application: MemoryApplicationUsage?
    /// 进程行保存当前 footprint；软件行保持 nil。
    var process: MemoryProcessCounter?
    /// 软件下 footprint 最大的进程节点，最多十项。
    var children: [MemoryOutlineItem] = []

    /// 创建可在后续快照中复用的软件节点或瞬时进程节点。
    init(application: MemoryApplicationUsage? = nil, process: MemoryProcessCounter? = nil) {
        self.application = application
        self.process = process
    }

    /// 按 PID 和启动时间保留现有节点；单纯 footprint 改变只更新数值，不重载进程子树。
    func updateProcesses(_ processes: [MemoryProcessCounter]) -> Bool {
        let unchanged = children.count == processes.count && zip(children, processes).allSatisfy { node, process in
            node.process?.pid == process.pid && node.process?.started == process.started
        }
        if unchanged {
            for (node, process) in zip(children, processes) { node.process = process }
            return false
        }
        let existing = Dictionary(children.compactMap { node in node.process.map { ($0.pid, node) } },
                                  uniquingKeysWith: { _, new in new })
        children = processes.map { process in
            let node: MemoryOutlineItem
            if let previous = existing[process.pid], previous.process?.started == process.started { node = previous }
            else { node = MemoryOutlineItem() }
            node.process = process
            return node
        }
        return true
    }
}

/// 弹窗中的整机内存摘要与软件排行；只渲染 CPU 同轮快照，不持有采样计时器。
final class MemoryPanelController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    /// 使用主程序唯一的内存模型，避免重复枚举进程。
    private let monitor: MemoryMonitor
    /// 安装或更新同一管理员服务，由主程序统一处理系统认证。
    var onAuthorize: (() -> Void)?
    /// 模块名称同时展示当前独立 Top 数量。
    private let titleLabel = NSTextField(labelWithString: "内存")
    /// 概览只显示当前已用和物理总量。
    private let usageLabel = NSTextField(labelWithString: "— / —")
    /// 内核内存压力等级，和已用字节保持独立口径。
    private let pressureLabel = NSTextField(labelWithString: "内存压力 —")
    /// 实际进程权限覆盖状态，详情放在悬停提示中。
    private let coverageLabel = NSTextField(labelWithString: "正在采样…")
    /// 普通权限可显示部分进程，按钮用于启用完整覆盖或更新旧服务。
    private let authorizeButton = NSButton(title: "授权…", target: nil, action: nil)
    /// 应用行可以展开到进程和 PID，不需要额外采样。
    private let outline = NSOutlineView()
    /// 首次采样、旧服务和失败状态显示在列表中央。
    private let emptyLabel = NSTextField(wrappingLabelWithString: "正在采样…")
    /// 当前软件根节点，仅包含用户配置的可见 Top 数量。
    private var roots: [MemoryOutlineItem] = []
    /// 用户展开的软件键在定时刷新后继续保持。
    private var expanded = Set<String>()
    /// 上次呈现的模型版本，避免摘要刷新时无条件重建 outline。
    private var lastRankingRevision = -1
    /// 独立 Top 设置改变时，即使采样版本未变也要重建可见行。
    private var lastTopCount = -1
    /// 软件图标最多缓存五十项，面板关闭后释放。
    private let icons = NSCache<NSString, NSImage>()

    /// 创建共享模型的紧凑原生面板。
    init(monitor: MemoryMonitor) {
        self.monitor = monitor
        super.init(nibName: nil, bundle: nil)
        icons.countLimit = RankingPreferences.maximumCount
    }

    /// 内存面板完全使用代码布局。
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 摘要占两行，其余高度用于可展开排行，并保持与 CPU、磁盘区域等高。
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 392, height: 208))
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 5
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        usageLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        usageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let heading = NSStackView(views: [titleLabel, NSView(), usageLabel])
        heading.alignment = .centerY
        root.addArrangedSubview(heading)

        pressureLabel.font = .systemFont(ofSize: 11, weight: .medium)
        coverageLabel.font = .systemFont(ofSize: 10)
        coverageLabel.textColor = .secondaryLabelColor
        coverageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        authorizeButton.bezelStyle = .rounded
        authorizeButton.controlSize = .small
        authorizeButton.font = .systemFont(ofSize: 11)
        authorizeButton.target = self
        authorizeButton.action = #selector(authorize)
        let summary = NSStackView(views: [pressureLabel, NSView(), coverageLabel, authorizeButton])
        summary.alignment = .centerY
        summary.spacing = 5
        root.addArrangedSubview(summary)

        let container = NSView()
        let scroll = RankingScrollView(numberColumnWidths: [90])
        outline.backgroundColor = .clear
        outline.rowHeight = 25
        outline.selectionHighlightStyle = .none
        outline.indentationPerLevel = 13
        outline.intercellSpacing = NSSize(width: 6, height: 1)
        outline.allowsColumnReordering = false
        outline.allowsColumnResizing = false
        outline.columnAutoresizingStyle = .noColumnAutoresizing
        for (id, title, width) in [("app", "软件 / 进程", 264.0), ("memory", "内存占用", 90.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.minWidth = 0
            column.width = width
            column.resizingMask = []
            column.headerCell.font = .systemFont(ofSize: 11)
            outline.addTableColumn(column)
            if id == "app" { outline.outlineTableColumn = column }
        }
        outline.dataSource = self
        outline.delegate = self
        scroll.documentView = outline
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)
        root.addArrangedSubview(container)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 115),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: 10),
            emptyLabel.widthAnchor.constraint(equalTo: container.widthAnchor, constant: -28)
        ])
        for child in root.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
        titleLabel.toolTip = "软件排行使用进程物理 footprint；辅助进程合并到最外层 App。排行合计不等于整机已用内存。"
        usageLabel.toolTip = "已用内存根据 Mach VM 页计数计算；总量为机器物理内存。"
    }

    /// 更新整机摘要和覆盖状态；模型版本或 Top 设置变化后，只对结构改变的排行层级进行重载。
    func refresh() {
        guard isViewLoaded else { return }
        let topCount = RankingPreferences.count(for: .memory)
        titleLabel.stringValue = "内存 · 前 \(topCount)"
        if let usage = monitor.systemUsage {
            usageLabel.stringValue = "已用 \(MemoryText.string(usage.usedBytes)) / 总量 \(MemoryText.string(usage.totalBytes))"
            pressureLabel.stringValue = "内存压力 \(usage.pressure.title)"
            switch usage.pressure {
            case .normal: pressureLabel.textColor = .systemGreen
            case .warning: pressureLabel.textColor = .systemOrange
            case .critical: pressureLabel.textColor = .systemRed
            case .unknown: pressureLabel.textColor = .secondaryLabelColor
            }
        } else {
            usageLabel.stringValue = "已用 — / 总量 —"
            pressureLabel.stringValue = "内存压力 —"
            pressureLabel.textColor = .secondaryLabelColor
        }
        coverageLabel.stringValue = monitor.isRankingStale ? "结果已过期" : monitor.collectionStatus.summary
            ?? (monitor.privileged ? (monitor.deniedProcesses > 0 ? "\(monitor.deniedProcesses) 个受保护" : "管理员采集")
                : "部分进程")
        coverageLabel.textColor = monitor.isRankingStale || monitor.collectionStatus.preservesResult
            ? .systemOrange : .secondaryLabelColor
        coverageLabel.toolTip = "\(monitor.rankingStatus)\n最近成功读取 \(monitor.readableProcesses) 个进程；权限受限 \(monitor.deniedProcesses) 个，退出或暂不可读 \(monitor.skippedProcesses) 个。\(SamplingPreferences.interval) 秒采样。"
        authorizeButton.isHidden = CPUPrivilege.isInstalled && !monitor.collectionStatus.requiresAuthorization
        authorizeButton.title = CPUPrivilege.isInstalled ? "更新 / 授权…" : "授权…"
        guard lastRankingRevision != monitor.rankingRevision || lastTopCount != topCount else { return }
        lastRankingRevision = monitor.rankingRevision
        lastTopCount = topCount
        let previousKeys = roots.compactMap { $0.application?.key }
        var changedChildren: [MemoryOutlineItem] = []
        let existing = Dictionary(roots.compactMap { node in
            node.application.map { ($0.key, node) }
        }, uniquingKeysWith: { _, new in new })
        roots = monitor.applications.prefix(topCount).map { application in
            let node = existing[application.key] ?? MemoryOutlineItem()
            node.application = application
            if node.updateProcesses(Array(application.processes.prefix(10))) { changedChildren.append(node) }
            return node
        }
        let keepExpanded = expanded
        if previousKeys != roots.compactMap({ $0.application?.key }) { outline.reloadData() }
        else { for node in changedChildren { outline.reloadItem(node, reloadChildren: true) } }
        for node in roots where keepExpanded.contains(node.application?.key ?? "") && !outline.isItemExpanded(node) {
            outline.expandItem(node)
        }
        expanded = keepExpanded.intersection(Set(monitor.applications.map(\.key)))
        outline.updateExistingRankingCells { [self] cell, row, _ in
            if let node = outline.item(atRow: row) as? MemoryOutlineItem { update(cell, node: node) }
        }
        emptyLabel.stringValue = monitor.rankingStatus
        emptyLabel.isHidden = !roots.isEmpty
    }

    /// 面板关闭时释放进程节点和图标缓存，保留轻量的展开偏好。
    func releaseRanking() {
        roots = []
        lastRankingRevision = -1
        icons.removeAllObjects()
        outline.reloadData()
    }

    /// 根节点为软件，第二层为该软件当前 footprint 最大的进程。
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? MemoryOutlineItem)?.children.count ?? roots.count
    }

    /// 根据 AppKit 请求返回稳定的软件节点或当前进程节点。
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? MemoryOutlineItem { return node.children[index] }
        return roots[index]
    }

    /// 软件即使只有一个进程也允许展开，便于查看 PID 和独立 footprint。
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? MemoryOutlineItem)?.children.isEmpty ?? true)
    }

    /// 渲染名称和内存值；软件图标按 bundle 路径缓存，进程行不重复解析图标。
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? MemoryOutlineItem, let column = tableColumn else { return nil }
        if column.identifier.rawValue == "memory" {
            let cell = outlineView.makeView(withIdentifier: column.identifier, owner: self) as? NSTableCellView
                ?? NSTableCellView()
            cell.identifier = column.identifier
            if cell.textField == nil {
                let label = NSTextField(labelWithString: "")
                label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                label.alignment = .right
                label.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(label)
                cell.textField = label
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                    label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            }
            update(cell, node: node)
            return cell
        }
        let cell = outlineView.makeView(withIdentifier: column.identifier, owner: self) as? ApplicationCell
            ?? ApplicationCell(frame: .zero)
        cell.identifier = column.identifier
        update(cell, node: node)
        return cell
    }

    /// 软件与子进程沿用同一轻量渲染路径；视图、约束和相同身份的图标随数值更新持续复用。
    private func update(_ cell: NSTableCellView, node: MemoryOutlineItem) {
        if let cell = cell as? ApplicationCell {
            let name = node.application?.name ?? node.process?.name ?? ""
            let path = node.application?.bundlePath ?? node.process?.path
            cell.update(name: name, detail: node.application.map { $0.processCount > 1 ? "×\($0.processCount)" : "" }
                ?? node.process.map { "PID \($0.pid)" } ?? "",
                toolTip: name + (path.map { "\n\($0)" } ?? ""),
                iconKey: node.application?.bundlePath.map { "app:\($0)" } ?? "process") { [self] in
                    guard let path = node.application?.bundlePath else { return ApplicationCell.processIcon }
                    if let icon = icons.object(forKey: path as NSString) { return icon }
                    let icon = NSWorkspace.shared.icon(forFile: path); icon.size = NSSize(width: 22, height: 22)
                    icons.setObject(icon, forKey: path as NSString); return icon
                }
        } else {
            cell.updateRankingValue(MemoryText.string(node.application?.footprintBytes ?? node.process?.footprintBytes ?? 0))
        }
    }

    /// 记录用户手动展开的软件，使下一轮即时快照不折叠当前查看位置。
    func outlineViewItemDidExpand(_ notification: Notification) {
        if let item = notification.userInfo?["NSObject"] as? MemoryOutlineItem,
           let key = item.application?.key {
            expanded.insert(key)
        }
    }

    /// 用户主动折叠的软件在之后刷新中继续保持折叠。
    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let item = notification.userInfo?["NSObject"] as? MemoryOutlineItem,
           let key = item.application?.key {
            expanded.remove(key)
        }
    }

    /// 交给主应用触发现有的系统管理员授权或辅助服务更新流程。
    @objc private func authorize() { onAuthorize?() }
}
