import AppKit

/// 磁盘趋势下方的应用排行，实时读写与时段写入各有一张独立表格。
final class DiskPanelController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    /// 固定排行的列及读数口径；两种排行在同一浮层内各自更新。
    enum RankingKind: Equatable {
        /// 读取最新进程快照中的实时读写速度。
        case live
        /// 展示选定趋势时段内的各软件累计写入量。
        case history

        /// 两张表共用软件名称列，数字列按各自的单位预留宽度。
        var columns: [(identifier: String, title: String, width: CGFloat)] {
            switch self {
            case .live: return [("app", "软件 / 进程", 202), ("read", "读取", 84), ("write", "写入", 84)]
            case .history: return [("app", "软件 / 进程", 251), ("write", "累计写入", 120)]
            }
        }
    }

    /// 使用主程序唯一的磁盘模型，不重复读取进程。
    private let monitor: DiskMonitor
    /// 从创建时确定该表属于实时或历史排行，使用对应的数据源和操作。
    private let kind: RankingKind
    /// 安装或更新同一管理员服务，由主程序统一处理系统认证。
    var onAuthorize: (() -> Void)?
    /// 后台记录关闭时跳转到已有设置窗口，由用户决定是否开启。
    var onSettings: (() -> Void)?
    /// 模块名称同时展示当前独立 Top 数量。
    private let titleLabel = NSTextField(labelWithString: "磁盘")
    /// 实时模式显示权限覆盖，时段模式显示覆盖时长和估算提示。
    private let coverageLabel = NSTextField(labelWithString: "正在采样…")
    /// 两种排行都按内核归属到进程的读写统计，包含外接设备。
    private let scopeLabel = NSTextField(labelWithString: "所有磁盘")
    /// 容量不需要授权，按钮仅用于进程读写权限或旧服务升级。
    private let authorizeButton = NSButton(title: "授权…", target: nil, action: nil)
    /// 关闭后台记录时提供与一级弹窗相同的设置入口。
    private let settingsButton = NSButton(title: "设置…", target: nil, action: nil)
    /// 磁盘独立排序，不修改网络的排序选择。
    private let orderControl = NSSegmentedControl(labels: ["合计", "读取", "写入"], trackingMode: .selectOne,
        target: nil, action: nil)
    /// 复用原生列表与已有列宽适配逻辑，读取和写入均完整显示单位。
    private let table = NSTableView()
    /// 每张表独立纵向滚动，较矮的屏幕仍可以查看完整排行。
    private let scroll: RankingScrollView
    /// 按磁盘曲线使用的十进制口径显示累计字节，不附加速度后缀。
    private let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .decimal
        return formatter
    }()
    /// 基线、权限失败和无读写时显示真实状态。
    private let emptyLabel = NSTextField(wrappingLabelWithString: "正在采样…")
    /// 表格快照始终先按应用完整读写排序，再按用户配置截取。
    private var rows: [DiskApplicationUsage] = []
    /// 所选时段的已排序结果，仅在磁盘详情可见时保留。
    private var historySnapshot: DiskWriteHistorySnapshot?
    /// 图标缓存最多五十项，收起后释放。
    private let icons = NSCache<NSString, NSImage>()

    /// 构造共享模型的原生面板，和现有网络排行使用相同视觉尺寸。
    init(monitor: DiskMonitor, kind: RankingKind) {
        self.monitor = monitor
        self.kind = kind
        scroll = RankingScrollView(numberColumnWidths: kind.columns.dropFirst().map { $0.width })
        super.init(nibName: nil, bundle: nil)
        icons.countLimit = RankingPreferences.maximumCount
    }

    /// 磁盘面板仅通过代码创建。
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 构建独立的排行标题、状态和表格，供对应趋势图下方直接摆放。
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 392, height: 208))
        let root = NSStackView()
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 5
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        coverageLabel.font = .systemFont(ofSize: 10); coverageLabel.textColor = .secondaryLabelColor
        coverageLabel.lineBreakMode = .byTruncatingTail
        coverageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        root.addArrangedSubview(titleLabel)
        scopeLabel.font = .systemFont(ofSize: 11); scopeLabel.textColor = .secondaryLabelColor
        scopeLabel.toolTip = "包含所有存储设备，同一 App 的辅助进程合并。受保护进程和短任务可能漏记，系统代办 I/O 会影响归属。"
        orderControl.segmentStyle = .rounded; orderControl.controlSize = .small
        orderControl.target = self; orderControl.action = #selector(changeOrder)
        authorizeButton.bezelStyle = .rounded; authorizeButton.controlSize = .small
        authorizeButton.target = self; authorizeButton.action = #selector(authorize)
        settingsButton.bezelStyle = .rounded; settingsButton.controlSize = .small
        settingsButton.target = self; settingsButton.action = #selector(openSettings)
        let toolbar = NSStackView(views: [scopeLabel, coverageLabel, NSView(), authorizeButton,
                                         kind == .live ? orderControl : settingsButton])
        toolbar.alignment = .centerY; toolbar.spacing = 5; toolbar.detachesHiddenViews = true
        root.addArrangedSubview(toolbar)
        let container = NSView()
        configureTable()
        scroll.documentView = table
        root.addArrangedSubview(container)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 76),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        emptyLabel.font = .systemFont(ofSize: 11); emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center; emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: 10),
            emptyLabel.widthAnchor.constraint(equalTo: container.widthAnchor, constant: -24)
        ])
        for child in root.arrangedSubviews { child.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        switch kind {
        case .live: refresh()
        case .history: showWriteHistoryLoading()
        }
    }

    /// 两张排行表采用相同的行高和 App 单元格，累计写入与读写速度使用各自的数字列布局。
    private func configureTable() {
        table.backgroundColor = .clear; table.rowHeight = 25
        table.intercellSpacing = NSSize(width: 5, height: 1)
        table.selectionHighlightStyle = .none
        table.allowsColumnReordering = false; table.allowsColumnResizing = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        for (id, title, width) in kind.columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title; column.minWidth = 0; column.width = width; column.resizingMask = []
            column.headerCell.font = .systemFont(ofSize: 10, weight: .medium)
            if id != "app" { column.headerCell.alignment = .center }
            table.addTableColumn(column)
        }
        table.dataSource = self; table.delegate = self
    }

    /// 更新当前快照和独立 Top 数量；权限未完整启用时保留容量但不伪造进程速度。
    func refresh() {
        guard isViewLoaded, kind == .live else { return }
        let count = RankingPreferences.count(for: .disk)
        titleLabel.stringValue = "实时读写排行 · 前 \(count)"
        coverageLabel.stringValue = monitor.isRankingStale ? "结果已过期" : monitor.collectionStatus.summary
            ?? (monitor.deniedProcesses > 0 ? "\(monitor.deniedProcesses) 个受保护" : "管理员采集")
        coverageLabel.textColor = monitor.isRankingStale || monitor.collectionStatus.preservesResult
            ? .systemOrange : .secondaryLabelColor
        coverageLabel.toolTip = "\(monitor.rankingStatus)\n最近成功读取 \(monitor.readableProcesses) 个进程；权限受限 \(monitor.deniedProcesses) 个，退出或暂不可读 \(monitor.skippedProcesses) 个。\(SamplingPreferences.interval) 秒采样。"
        refreshAuthorization()
        orderControl.selectedSegment = monitor.order.rawValue
        let previousCount = rows.count
        rows = Array(monitor.sortedApplications.prefix(count))
        if previousCount != rows.count { table.reloadData() }
        else { table.updateExistingRankingCells { [self] cell, row, column in update(cell, column: column, row: row) } }
        emptyLabel.stringValue = monitor.rankingStatus; emptyLabel.isHidden = !rows.isEmpty
    }

    /// 时间档切换时清除旧范围，避免异步查询期间把旧排行误当成所选时段。
    func showWriteHistoryLoading() {
        guard isViewLoaded, kind == .history else { return }
        historySnapshot = nil
        titleLabel.stringValue = "时段写入排行 · 前 \(RankingPreferences.count(for: .disk))"
        coverageLabel.stringValue = "读取中…"
        coverageLabel.textColor = .secondaryLabelColor
        coverageLabel.toolTip = nil
        settingsButton.isHidden = DiskWriteHistoryPreferences.isEnabled
        refreshAuthorization()
        table.reloadData()
        emptyLabel.stringValue = "正在读取所选时段的写入量…"
        emptyLabel.isHidden = false
    }

    /// 展示已采集的写入量及覆盖时间，区分确实没有写入和缺少采样记录。
    func showWriteHistory(_ snapshot: DiskWriteHistorySnapshot, range: TrendRange) {
        guard isViewLoaded, kind == .history else { return }
        let previousCount = historySnapshot?.rows.count ?? 0
        historySnapshot = snapshot
        let enabled = DiskWriteHistoryPreferences.isEnabled
        let duration = Self.coverageText(snapshot.coveredSeconds)
        let scope = snapshot.estimated ? " · 含估算" : ""
        titleLabel.stringValue = "时段写入排行 · 前 \(RankingPreferences.count(for: .disk))"
        coverageLabel.stringValue = snapshot.error == nil
            ? "已采样 \(duration) / \(range.title)\(scope)" : "记录读取受限"
        coverageLabel.textColor = snapshot.error == nil ? .secondaryLabelColor : .systemOrange
        let estimateNote = snapshot.estimated ? "跨越时间边界的写入按重叠时长估算。" : ""
        let coverageNote = "覆盖 \(duration)，所选时段 \(range.title)。未采集的时段没有计入。"
        coverageLabel.toolTip = [snapshot.error, coverageNote, estimateNote].compactMap { $0 }
            .filter { !$0.isEmpty }.joined(separator: "\n")
        settingsButton.isHidden = enabled
        refreshAuthorization()
        if previousCount != snapshot.rows.count { table.reloadData() }
        else {
            table.updateExistingRankingCells { [self] cell, row, column in
                update(cell, column: column, row: row)
            }
        }
        if let error = snapshot.error { emptyLabel.stringValue = error }
        else if snapshot.coveredSeconds > 0 { emptyLabel.stringValue = "已采集的时段内没有记录到写入" }
        else if !enabled { emptyLabel.stringValue = "可在设置中开启「后台记录磁盘写入」" }
        else if !authorizeButton.isHidden { emptyLabel.stringValue = "需要管理员采集权限来记录写入量" }
        else { emptyLabel.stringValue = "所选时段暂无采集记录" }
        emptyLabel.isHidden = !snapshot.rows.isEmpty
    }

    /// 覆盖时长取整秒；及时区分首次样本的不足一秒和确实未采集。
    private static func coverageText(_ duration: TimeInterval) -> String {
        let seconds = Int(max(0, duration).rounded(.down))
        if seconds >= 3600 { return "\(seconds / 3600)小时\(seconds % 3600 / 60)分" }
        if seconds >= 60 { return "\(seconds / 60)分\(seconds % 60)秒" }
        if seconds == 0 && duration > 0 { return "<1秒" }
        return "\(seconds)秒"
    }

    /// 保留原有管理员授权入口，仅在确实缺少权限或兼容性需要更新时显示。
    private func refreshAuthorization() {
        let installed = CPUPrivilege.isInstalled
        authorizeButton.isHidden = installed && !monitor.collectionStatus.requiresAuthorization
        authorizeButton.title = installed ? "更新 / 授权…" : "授权…"
    }

    /// 收起后释放表格和图标缓存，后台不保存完整进程排行。
    func releaseRanking() {
        let hadSnapshot = !rows.isEmpty || historySnapshot != nil
        rows = []; historySnapshot = nil; icons.removeAllObjects()
        if isViewLoaded, hadSnapshot { table.reloadData() }
    }

    /// 只返回用户配置截取后的显示行数。
    func numberOfRows(in tableView: NSTableView) -> Int {
        if kind == .history { return historySnapshot?.rows.count ?? 0 }
        return rows.count
    }

    /// 复用应用名称单元格和数字样式，按表格区分实时速度与累计字节。
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard (0..<numberOfRows(in: tableView)).contains(row), let column = tableColumn else { return nil }
        if column.identifier.rawValue == "app" {
            let cell = tableView.makeView(withIdentifier: column.identifier, owner: self) as? ApplicationCell ?? ApplicationCell(frame: .zero)
            cell.identifier = column.identifier
            update(cell, column: column, row: row)
            return cell
        }
        let cell = tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = column.identifier
        if cell.textField == nil {
            let label = NSTextField(labelWithString: "")
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.alignment = .right; label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label); cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        update(cell, column: column, row: row)
        return cell
    }

    /// 原位覆盖已有行；时段排行显示写入字节，实时排行保留速度和辅助进程数量。
    private func update(_ cell: NSTableCellView, column: NSTableColumn, row: Int) {
        if kind == .history {
            guard let snapshot = historySnapshot, snapshot.rows.indices.contains(row) else { return }
            let app = snapshot.rows[row]
            if let cell = cell as? ApplicationCell {
                updateApplication(cell, name: app.name, path: app.bundlePath, detail: "")
            } else {
                let value = byteFormatter.string(fromByteCount: Int64(clamping: app.bytes))
                cell.updateRankingValue(value)
            }
            return
        }
        guard rows.indices.contains(row) else { return }
        let app = rows[row]
        if let cell = cell as? ApplicationCell {
            updateApplication(cell, name: app.name, path: app.bundlePath,
                detail: app.processes > 1 ? "×\(app.processes)" : "")
        } else {
            cell.updateRankingValue(SpeedText.string(column.identifier.rawValue == "read" ? app.read : app.write))
        }
    }

    /// 相同图标在当前表格更新时复用，退出后的 App 仍用记录中的名称和路径显示。
    private func updateApplication(_ cell: ApplicationCell, name: String, path: String?, detail: String) {
        cell.update(name: name, detail: detail, toolTip: name + (path.map { "\n\($0)" } ?? ""),
            iconKey: path.map { "app:\($0)" } ?? "terminal") { [self] in
                guard let path else { return ApplicationCell.terminalIcon }
                if let image = icons.object(forKey: path as NSString) { return image }
                let image = NSWorkspace.shared.icon(forFile: path); image.size = NSSize(width: 22, height: 22)
                icons.setObject(image, forKey: path as NSString); return image
            }
    }

    /// 跳转到现有设置页开启或关闭记录，排行面板不直接改变采集策略。
    @objc private func openSettings() { onSettings?() }

    /// 排序设置即时更新当前列表，保持原采样窗口。
    @objc private func changeOrder() { monitor.order = DiskRankingOrder(rawValue: orderControl.selectedSegment) ?? .combined }

    /// 管理员安装通过主应用和系统认证窗口完成。
    @objc private func authorize() { onAuthorize?() }
}
