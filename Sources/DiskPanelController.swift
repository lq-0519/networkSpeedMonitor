import AppKit

/// 磁盘趋势下方的应用排行，可在所选时段的写入量和实时读写速度之间切换。
final class DiskPanelController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    /// 使用主程序唯一的磁盘模型，不重复读取进程。
    private let monitor: DiskMonitor
    /// 安装或更新同一管理员服务，由主程序统一处理系统认证。
    var onAuthorize: (() -> Void)?
    /// 后台记录关闭时跳转到已有设置窗口，由用户决定是否开启。
    var onSettings: (() -> Void)?
    /// 用户切换实时和时段排行时通知父控制器同步时间窗口。
    var onModeChange: (() -> Void)?
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
    /// 时段写入和实时读写可随时切换，初始模式跟随后台记录开关。
    private let modeControl = NSSegmentedControl(labels: ["实时", "时段写入"], trackingMode: .selectOne,
        target: nil, action: nil)
    /// 磁盘独立排序，不修改网络的排序选择。
    private let orderControl = NSSegmentedControl(labels: ["合计", "读取", "写入"], trackingMode: .selectOne,
        target: nil, action: nil)
    /// 复用原生列表与已有列宽适配逻辑，读取和写入均完整显示单位。
    private let table = NSTableView()
    /// 时段排行仅显示应用和累计写入列，格式独立于实时速度列。
    private let historyTable = NSTableView()
    /// 实时排行滚动区域，切换到时段模式时整体隐藏。
    private let liveScroll = RankingScrollView(numberColumnWidths: [84, 84])
    /// 写入历史滚动区域，为大单位数值保留固定宽度。
    private let historyScroll = RankingScrollView(numberColumnWidths: [120])
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
    /// 只在记录偏好改变时自动切换默认模式，普通重开仍保留用户上次手动选择。
    private var lastHistoryPreference = DiskWriteHistoryPreferences.isEnabled
    /// 图标缓存最多五十项，收起后释放。
    private let icons = NSCache<NSString, NSImage>()

    /// 详情首次加载前也可由趋势控制器判断是否需要读取排行。
    private(set) var showsWriteHistory = DiskWriteHistoryPreferences.isEnabled

    /// 构造共享模型的原生面板，和现有网络排行使用相同视觉尺寸。
    init(monitor: DiskMonitor) {
        self.monitor = monitor
        super.init(nibName: nil, bundle: nil)
        icons.countLimit = RankingPreferences.maximumCount
    }

    /// 磁盘面板仅通过代码创建。
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 同一区域按模式显示实时读写或时段写入，容量由上方趋势图呈现。
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
        modeControl.segmentStyle = .rounded; modeControl.controlSize = .small
        modeControl.selectedSegment = showsWriteHistory ? 1 : 0
        modeControl.target = self; modeControl.action = #selector(changeRankingMode)
        modeControl.setAccessibilityLabel("磁盘排行模式")
        let heading = NSStackView(views: [titleLabel, NSView(), modeControl])
        heading.alignment = .centerY
        root.addArrangedSubview(heading)
        scopeLabel.font = .systemFont(ofSize: 11); scopeLabel.textColor = .secondaryLabelColor
        scopeLabel.toolTip = "包含所有存储设备，同一 App 的辅助进程合并。受保护进程和短任务可能漏记，系统代办 I/O 会影响归属。"
        orderControl.segmentStyle = .rounded; orderControl.controlSize = .small
        orderControl.target = self; orderControl.action = #selector(changeOrder)
        authorizeButton.bezelStyle = .rounded; authorizeButton.controlSize = .small
        authorizeButton.target = self; authorizeButton.action = #selector(authorize)
        settingsButton.bezelStyle = .rounded; settingsButton.controlSize = .small
        settingsButton.target = self; settingsButton.action = #selector(openSettings)
        let toolbar = NSStackView(views: [scopeLabel, coverageLabel, NSView(), settingsButton, authorizeButton, orderControl])
        toolbar.alignment = .centerY; toolbar.spacing = 5; toolbar.detachesHiddenViews = true
        root.addArrangedSubview(toolbar)
        let container = NSView()
        configureTable(table, columns: [("app", "软件 / 进程", 202), ("read", "读取", 84), ("write", "写入", 84)])
        configureTable(historyTable, columns: [("app", "软件 / 进程", 251), ("write", "累计写入", 120)])
        liveScroll.documentView = table
        historyScroll.documentView = historyTable
        root.addArrangedSubview(container)
        container.heightAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        for scroll in [liveScroll, historyScroll] {
            scroll.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(scroll)
            NSLayoutConstraint.activate([
                scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                scroll.topAnchor.constraint(equalTo: container.topAnchor),
                scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
        }
        emptyLabel.font = .systemFont(ofSize: 11); emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center; emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: 10),
            emptyLabel.widthAnchor.constraint(equalTo: container.widthAnchor, constant: -24)
        ])
        for child in root.arrangedSubviews { child.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        applyMode()
    }

    /// 两张排行表采用相同的行高和 App 单元格，累计写入与读写速度使用各自的数字列布局。
    private func configureTable(_ table: NSTableView, columns: [(String, String, CGFloat)]) {
        table.backgroundColor = .clear; table.rowHeight = 25
        table.intercellSpacing = NSSize(width: 5, height: 1)
        table.selectionHighlightStyle = .none
        table.allowsColumnReordering = false; table.allowsColumnResizing = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title; column.minWidth = 0; column.width = width; column.resizingMask = []
            column.headerCell.font = .systemFont(ofSize: 10, weight: .medium)
            if id != "app" { column.headerCell.alignment = .center }
            table.addTableColumn(column)
        }
        table.dataSource = self; table.delegate = self
    }

    /// 为当前模式显示对应列表和操作，历史查询由父控制器统一协调。
    private func applyMode() {
        liveScroll.isHidden = showsWriteHistory
        historyScroll.isHidden = !showsWriteHistory
        orderControl.isHidden = showsWriteHistory
        if showsWriteHistory {
            showWriteHistoryLoading()
        } else {
            settingsButton.isHidden = true
            refresh()
        }
    }

    /// 从设置返回时启用历史就直接显示写入量，停用后优先显示原有实时速度。
    func prepareForPresentation() {
        let enabled = DiskWriteHistoryPreferences.isEnabled
        guard enabled != lastHistoryPreference else { return }
        lastHistoryPreference = enabled
        showsWriteHistory = enabled
        modeControl.selectedSegment = showsWriteHistory ? 1 : 0
        if isViewLoaded { applyMode() }
    }

    /// 更新当前快照和独立 Top 数量；权限未完整启用时保留容量但不伪造进程速度。
    func refresh() {
        guard isViewLoaded, !showsWriteHistory else { return }
        let count = RankingPreferences.count(for: .disk)
        titleLabel.stringValue = "磁盘 · 前 \(count)"
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
        else { table.updateExistingRankingCells { [self] cell, row, column in update(cell, in: table, column: column, row: row) } }
        emptyLabel.stringValue = monitor.rankingStatus; emptyLabel.isHidden = !rows.isEmpty
    }

    /// 时间档切换时清除旧范围，避免异步查询期间把旧排行误当成所选时段。
    func showWriteHistoryLoading() {
        guard isViewLoaded, showsWriteHistory else { return }
        historySnapshot = nil
        titleLabel.stringValue = "写入排行 · 前 \(RankingPreferences.count(for: .disk))"
        coverageLabel.stringValue = "读取中…"
        coverageLabel.textColor = .secondaryLabelColor
        coverageLabel.toolTip = nil
        settingsButton.isHidden = DiskWriteHistoryPreferences.isEnabled
        refreshAuthorization()
        historyTable.reloadData()
        emptyLabel.stringValue = "正在读取所选时段的写入量…"
        emptyLabel.isHidden = false
    }

    /// 展示已采集的写入量及覆盖时间，区分确实没有写入和缺少采样记录。
    func showWriteHistory(_ snapshot: DiskWriteHistorySnapshot, range: TrendRange) {
        guard isViewLoaded, showsWriteHistory else { return }
        let previousCount = historySnapshot?.rows.count ?? 0
        historySnapshot = snapshot
        let enabled = DiskWriteHistoryPreferences.isEnabled
        let duration = Self.coverageText(snapshot.coveredSeconds)
        let scope = snapshot.estimated ? " · 含估算" : ""
        titleLabel.stringValue = "写入排行 · 前 \(RankingPreferences.count(for: .disk))"
        coverageLabel.stringValue = snapshot.error == nil
            ? "已采样 \(duration) / \(range.title)\(scope)" : "记录读取受限"
        coverageLabel.textColor = snapshot.error == nil ? .secondaryLabelColor : .systemOrange
        let estimateNote = snapshot.estimated ? "跨越时间边界的写入按重叠时长估算。" : ""
        let coverageNote = "覆盖 \(duration)，所选时段 \(range.title)。未采集的时段没有计入。"
        coverageLabel.toolTip = [snapshot.error, coverageNote, estimateNote].compactMap { $0 }
            .filter { !$0.isEmpty }.joined(separator: "\n")
        settingsButton.isHidden = enabled
        refreshAuthorization()
        if previousCount != snapshot.rows.count { historyTable.reloadData() }
        else {
            historyTable.updateExistingRankingCells { [self] cell, row, column in
                update(cell, in: historyTable, column: column, row: row)
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
        rows = []; historySnapshot = nil; icons.removeAllObjects()
        if isViewLoaded { table.reloadData(); historyTable.reloadData() }
    }

    /// 只返回用户配置截取后的显示行数。
    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === historyTable { return historySnapshot?.rows.count ?? 0 }
        return rows.count
    }

    /// 复用应用名称单元格和数字样式，按表格区分实时速度与累计字节。
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard (0..<numberOfRows(in: tableView)).contains(row), let column = tableColumn else { return nil }
        if column.identifier.rawValue == "app" {
            let cell = tableView.makeView(withIdentifier: column.identifier, owner: self) as? ApplicationCell ?? ApplicationCell(frame: .zero)
            cell.identifier = column.identifier
            update(cell, in: tableView, column: column, row: row)
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
        update(cell, in: tableView, column: column, row: row)
        return cell
    }

    /// 原位覆盖已有行；时段排行显示写入字节，实时排行保留速度和辅助进程数量。
    private func update(_ cell: NSTableCellView, in source: NSTableView, column: NSTableColumn, row: Int) {
        if source === historyTable, let snapshot = historySnapshot {
            let app = snapshot.rows[row]
            if let cell = cell as? ApplicationCell {
                updateApplication(cell, name: app.name, path: app.bundlePath, detail: "")
            } else {
                let value = byteFormatter.string(fromByteCount: Int64(clamping: app.bytes))
                cell.updateRankingValue(value)
            }
            return
        }
        let app = rows[row]
        if let cell = cell as? ApplicationCell {
            updateApplication(cell, name: app.name, path: app.bundlePath,
                detail: app.processes > 1 ? "×\(app.processes)" : "")
        } else {
            cell.updateRankingValue(SpeedText.string(column.identifier.rawValue == "read" ? app.read : app.write))
        }
    }

    /// 实时和时段排行复用同一图标缓存，退出后的 App 仍用记录中的名称和路径显示。
    private func updateApplication(_ cell: ApplicationCell, name: String, path: String?, detail: String) {
        cell.update(name: name, detail: detail, toolTip: name + (path.map { "\n\($0)" } ?? ""),
            iconKey: path.map { "app:\($0)" } ?? "terminal") { [self] in
                guard let path else { return ApplicationCell.terminalIcon }
                if let image = icons.object(forKey: path as NSString) { return image }
                let image = NSWorkspace.shared.icon(forFile: path); image.size = NSSize(width: 22, height: 22)
                icons.setObject(image, forKey: path as NSString); return image
            }
    }

    /// 标记用户选中的排行模式，父控制器可立即读取当前时间窗口。
    @objc private func changeRankingMode() {
        showsWriteHistory = modeControl.selectedSegment == 1
        applyMode()
        onModeChange?()
    }

    /// 跳转到现有设置页开启或关闭记录，排行面板不直接改变采集策略。
    @objc private func openSettings() { onSettings?() }

    /// 排序设置即时更新当前列表，保持原采样窗口。
    @objc private func changeOrder() { monitor.order = DiskRankingOrder(rawValue: orderControl.selectedSegment) ?? .combined }

    /// 管理员安装通过主应用和系统认证窗口完成。
    @objc private func authorize() { onAuthorize?() }
}
