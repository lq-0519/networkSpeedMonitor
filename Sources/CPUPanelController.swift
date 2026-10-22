import AppKit

/// 原生 outline 节点，使用稳定软件键保持刷新时的展开状态。
final class CPUOutlineItem: NSObject {
    /// 软件行保存聚合信息；进程子行保持 nil。
    var application: CPUApplicationUsage?
    /// 进程行保存当前窗口的整机占比；软件行保持 nil。
    var process: CPUProcessUsage?
    /// 软件下的进程节点，按当前占用降序排列。
    var children: [CPUOutlineItem] = []

    /// 创建软件或进程节点，数据可随下一轮采样更新。
    init(application: CPUApplicationUsage? = nil, process: CPUProcessUsage? = nil) {
        self.application = application; self.process = process
    }

    /// 按 PID 和启动时间复用进程节点；返回顺序或成员是否变化，纯占用变化无需重载 outline 子树。
    func updateProcesses(_ processes: [CPUProcessUsage]) -> Bool {
        let unchanged = children.count == processes.count && zip(children, processes).allSatisfy { node, usage in
            node.process?.process.pid == usage.process.pid && node.process?.process.started == usage.process.started
        }
        if unchanged {
            for (node, usage) in zip(children, processes) { node.process = usage }
            return false
        }
        let existing = Dictionary(children.compactMap { node in node.process.map { ($0.process.pid, node) } },
                                  uniquingKeysWith: { _, new in new })
        children = processes.map { usage in
            let node: CPUOutlineItem
            if let previous = existing[usage.process.pid], previous.process?.process.started == usage.process.started { node = previous }
            else { node = CPUOutlineItem() }
            node.process = usage
            return node
        }
        return true
    }
}

/// CPU 应用排行按独立 Top 配置展示，展开子进程仍最多十项，汇总总量包含全部进程。
final class CPUPanelController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    /// 与菜单栏共用的 CPU 模型，避免建立第二套采样定时器。
    private let monitor: CPUMonitor
    /// 首次安装或升级管理员采集服务的回调。
    var onAuthorize: (() -> Void)?
    /// 整机占用主数字，详情中保留百分号解释数值含义。
    private let totalLabel = NSTextField(labelWithString: "—")
    /// 用户态、系统态和刷新周期摘要。
    private let summaryLabel = NSTextField(labelWithString: "正在采样…")
    /// 已验证的采集权限及覆盖数量。
    private let coverageLabel = NSTextField(labelWithString: "")
    /// 首次采样或失败时在列表中央显示的信息。
    private let emptyLabel = NSTextField(wrappingLabelWithString: "正在采样…")
    /// 应用行可以展开到每个进程，无需额外采样。
    private let outline = NSOutlineView()
    /// 按需授权入口，管理员快照正常时隐藏。
    private let authorizeButton = NSButton(title: "授权完整采集…", target: nil, action: nil)
    /// 当前根节点，用于数据源回调。
    private var roots: [CPUOutlineItem] = []
    /// 用户展开的软件键，刷新时保持选择。
    private var expanded = Set<String>()
    /// 上次呈现的排行版本，整机百分比变化时复用现有表格。
    private var lastRankingRevision = -1
    /// 数量设置变化也需要刷新列表，不能被未变的采样版本拦截。
    private var lastTopCount = -1
    /// CPU 标题随独立 Top 偏好更新，不使用固定十项文案。
    private let titleLabel = NSTextField(labelWithString: "CPU")
    /// 对图标设置数量上限，收起面板后清空。
    private let icons = NSCache<NSString, NSImage>()

    /// 创建共享模型的原生面板。
    init(monitor: CPUMonitor) {
        self.monitor = monitor
        super.init(nibName: nil, bundle: nil)
        icons.countLimit = RankingPreferences.maximumCount
    }

    /// 所有界面由代码创建。
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 布局保持固定尺寸，空态放在滚动容器外避免覆盖表头。
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 392, height: 208))
        let root = NSStackView()
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 5
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 0),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: 0),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 0),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: 0)
        ])
        let title = titleLabel
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        totalLabel.font = .monospacedDigitSystemFont(ofSize: 18, weight: .semibold)
        let heading = NSStackView(views: [title, NSView(), totalLabel])
        heading.alignment = .centerY
        root.addArrangedSubview(heading); heading.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        summaryLabel.font = .systemFont(ofSize: 11); summaryLabel.textColor = .secondaryLabelColor
        coverageLabel.font = .systemFont(ofSize: 10); coverageLabel.textColor = .secondaryLabelColor
        coverageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        authorizeButton.bezelStyle = .rounded; authorizeButton.controlSize = .small
        authorizeButton.font = .systemFont(ofSize: 11)
        authorizeButton.target = self; authorizeButton.action = #selector(authorize)
        let coverage = NSStackView(views: [summaryLabel, NSView(), coverageLabel, authorizeButton])
        coverage.alignment = .centerY
        root.addArrangedSubview(coverage); coverage.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        let container = NSView(), scroll = RankingScrollView(numberColumnWidths: [72])
        outline.backgroundColor = .clear; outline.rowHeight = 25
        outline.selectionHighlightStyle = .none; outline.indentationPerLevel = 13
        outline.intercellSpacing = NSSize(width: 6, height: 1)
        outline.allowsColumnReordering = false; outline.allowsColumnResizing = false
        outline.columnAutoresizingStyle = .noColumnAutoresizing
        for (id, title, width) in [("app", "软件 / 进程", 282.0), ("cpu", "整机占比", 72.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title; column.minWidth = 0; column.width = width
            column.resizingMask = []
            column.headerCell.font = .systemFont(ofSize: 11)
            outline.addTableColumn(column)
            if id == "app" { outline.outlineTableColumn = column }
        }
        outline.dataSource = self; outline.delegate = self
        scroll.documentView = outline
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)
        root.addArrangedSubview(container)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalTo: root.widthAnchor),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 115),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        emptyLabel.font = .systemFont(ofSize: 12); emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center; emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: 10),
            emptyLabel.widthAnchor.constraint(equalTo: container.widthAnchor, constant: -28)
        ])
        title.toolTip = "按整机核心数归一化。软件占用包含全部进程；展开后展示最活跃的十个进程。采样期间已退出的短进程可能未列出。"
    }

    /// 仅在面板可见时更新；保留同软件的节点对象与展开状态。
    func refresh() {
        guard isViewLoaded else { return }
        let topCount = RankingPreferences.count(for: .cpu)
        titleLabel.stringValue = "CPU · 前 \(topCount)"
        totalLabel.stringValue = monitor.usage.map { String(format: "%.0f%%", $0.total) } ?? "—"
        summaryLabel.stringValue = monitor.usage.map {
            String(format: "用户 %.1f%% · 系统 %.1f%%", $0.user, $0.system)
        } ?? "正在采样…"
        summaryLabel.toolTip = "整机 CPU · \(monitor.interval) 秒刷新"
        coverageLabel.stringValue = monitor.isRankingStale ? "结果已过期" : monitor.collectionStatus.summary
            ?? (monitor.privileged ? (monitor.deniedProcesses > 0 ? "\(monitor.deniedProcesses) 个受保护" : "已授权")
                : "部分进程")
        coverageLabel.textColor = monitor.isRankingStale || monitor.collectionStatus.preservesResult
            ? .systemOrange : .secondaryLabelColor
        coverageLabel.toolTip = "\(monitor.rankingStatus)\n最近成功读取 \(monitor.readableProcesses) 个进程；列表按完整软件占用排序。"
        authorizeButton.isHidden = CPUPrivilege.isInstalled && !monitor.collectionStatus.requiresAuthorization
        authorizeButton.title = CPUPrivilege.isInstalled ? "重新授权…" : "授权…"
        guard lastRankingRevision != monitor.rankingRevision || lastTopCount != topCount else { return }
        lastRankingRevision = monitor.rankingRevision
        lastTopCount = topCount
        let previousKeys = roots.compactMap { $0.application?.key }
        var changedChildren: [CPUOutlineItem] = []
        let existing = Dictionary(roots.compactMap { node in node.application.map { ($0.key, node) } }, uniquingKeysWith: { _, new in new })
        roots = monitor.applications.prefix(topCount).map { application in
            let node = existing[application.key] ?? CPUOutlineItem()
            node.application = application
            if node.updateProcesses(Array(application.processes.prefix(10))) { changedChildren.append(node) }
            return node
        }
        // 仅根节点结构变化才整表重载；子进程变化只重载对应软件，纯数值变化直接复用单元格。
        let keepExpanded = expanded
        if previousKeys != roots.compactMap({ $0.application?.key }) { outline.reloadData() }
        else { for node in changedChildren { outline.reloadItem(node, reloadChildren: true) } }
        for node in roots where keepExpanded.contains(node.application?.key ?? "") && !outline.isItemExpanded(node) {
            outline.expandItem(node)
        }
        expanded = keepExpanded.intersection(Set(monitor.applications.map(\.key)))
        outline.updateExistingRankingCells { [self] cell, row, _ in
            if let node = outline.item(atRow: row) as? CPUOutlineItem { update(cell, node: node) }
        }
        emptyLabel.stringValue = monitor.rankingStatus
        emptyLabel.isHidden = !roots.isEmpty
    }

    /// 面板关闭时释放完整进程列表和图标，保留轻量的展开偏好。
    func releaseRanking() { roots = []; lastRankingRevision = -1; icons.removeAllObjects(); outline.reloadData() }

    /// 根节点是软件，第二层为各软件的进程。
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? CPUOutlineItem)?.children.count ?? roots.count
    }

    /// 根据 AppKit 请求返回对应的稳定节点。
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? CPUOutlineItem { return node.children[index] }
        return roots[index]
    }

    /// 软件即便只有一个进程也允许展开，以便查看 PID。
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? CPUOutlineItem)?.children.isEmpty ?? true)
    }

    /// 渲染可复用的名称及占用单元格；图标仅按软件路径缓存。
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? CPUOutlineItem, let column = tableColumn else { return nil }
        if column.identifier.rawValue == "cpu" {
            let cell = outlineView.makeView(withIdentifier: column.identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
            cell.identifier = column.identifier
            if cell.textField == nil {
                let label = NSTextField(labelWithString: "")
                label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); label.alignment = .right
                label.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(label); cell.textField = label
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                    label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            }
            update(cell, node: node)
            return cell
        }
        let cell = outlineView.makeView(withIdentifier: column.identifier, owner: self) as? ApplicationCell ?? ApplicationCell(frame: .zero)
        cell.identifier = column.identifier
        update(cell, node: node)
        return cell
    }

    /// 节点身份和展开状态保持稳定；只修改当前单元格实际变化的内容，隐藏行滚入时使用同一入口。
    private func update(_ cell: NSTableCellView, node: CPUOutlineItem) {
        if let cell = cell as? ApplicationCell {
            let name = node.application?.name ?? node.process?.process.name ?? ""
            let path = node.application?.bundlePath ?? node.process?.process.path
            cell.update(name: name, detail: node.application.map { $0.processCount > 1 ? "×\($0.processCount)" : "" }
                ?? node.process.map { "PID \($0.process.pid)" } ?? "",
                toolTip: name + (path.map { "\n\($0)" } ?? ""),
                iconKey: node.application?.bundlePath.map { "app:\($0)" } ?? "process") { [self] in
                    guard let path = node.application?.bundlePath else { return ApplicationCell.processIcon }
                    if let icon = icons.object(forKey: path as NSString) { return icon }
                    let icon = NSWorkspace.shared.icon(forFile: path); icon.size = NSSize(width: 22, height: 22)
                    icons.setObject(icon, forKey: path as NSString); return icon
                }
        } else {
            cell.updateRankingValue(String(format: "%.1f%%", node.application?.percent ?? node.process?.percent ?? 0))
        }
    }

    /// 记录手动展开，以便每两秒刷新时保留层级。
    func outlineViewItemDidExpand(_ notification: Notification) {
        if let item = notification.userInfo?["NSObject"] as? CPUOutlineItem, let key = item.application?.key { expanded.insert(key) }
    }

    /// 用户折叠的软件在下一次刷新时保持折叠。
    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let item = notification.userInfo?["NSObject"] as? CPUOutlineItem, let key = item.application?.key { expanded.remove(key) }
    }

    /// 交给主应用触发系统管理员授权界面。
    @objc private func authorize() { onAuthorize?() }
}
