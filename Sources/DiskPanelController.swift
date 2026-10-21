import AppKit

/// 二级浮层中的磁盘应用读写排行；容量与进度只在一级概览展示。
final class DiskPanelController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    /// 使用主程序唯一的磁盘模型，不重复读取进程。
    private let monitor: DiskMonitor
    /// 安装或更新同一管理员服务，由主程序统一处理系统认证。
    var onAuthorize: (() -> Void)?
    /// 模块名称同时展示当前独立 Top 数量。
    private let titleLabel = NSTextField(labelWithString: "磁盘")
    /// 实际权限覆盖状态，详情放在悬停提示中。
    private let coverageLabel = NSTextField(labelWithString: "正在采样…")
    /// 容量不需要授权，按钮仅用于进程读写权限或旧服务升级。
    private let authorizeButton = NSButton(title: "授权…", target: nil, action: nil)
    /// 磁盘独立排序，不修改网络的排序选择。
    private let orderControl = NSSegmentedControl(labels: ["合计", "读取", "写入"], trackingMode: .selectOne,
        target: nil, action: nil)
    /// 复用原生列表与已有列宽适配逻辑，读取和写入均完整显示单位。
    private let table = NSTableView()
    /// 基线、权限失败和无读写时显示真实状态。
    private let emptyLabel = NSTextField(wrappingLabelWithString: "正在采样…")
    /// 表格快照始终先按应用完整读写排序，再按用户配置截取。
    private var rows: [DiskApplicationUsage] = []
    /// 图标缓存最多五十项，收起后释放。
    private let icons = NSCache<NSString, NSImage>()

    /// 构造共享模型的原生面板，和现有网络排行使用相同视觉尺寸。
    init(monitor: DiskMonitor) {
        self.monitor = monitor
        super.init(nibName: nil, bundle: nil)
        icons.countLimit = RankingPreferences.maximumCount
    }

    /// 磁盘面板仅通过代码创建。
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 二级只保留权限、排序和应用列表，避免重复一级已有的容量信息。
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
        let heading = NSStackView(views: [titleLabel, NSView(), coverageLabel])
        heading.alignment = .centerY
        root.addArrangedSubview(heading)
        let note = NSTextField(labelWithString: "应用磁盘 I/O")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        note.toolTip = "按系统归属到进程的磁盘字节统计，包含所有存储设备；同一应用辅助进程合并。缓存命中、系统代办 I/O 和短生命周期进程会影响归属，排行合计不代表整块 SSD 的吞吐量。"
        orderControl.segmentStyle = .rounded; orderControl.controlSize = .small
        orderControl.target = self; orderControl.action = #selector(changeOrder)
        authorizeButton.bezelStyle = .rounded; authorizeButton.controlSize = .small
        authorizeButton.target = self; authorizeButton.action = #selector(authorize)
        let toolbar = NSStackView(views: [note, authorizeButton, NSView(), orderControl])
        toolbar.alignment = .centerY; toolbar.spacing = 5
        root.addArrangedSubview(toolbar)
        let container = NSView(), scroll = RankingScrollView(numberColumnWidths: [84, 84])
        table.backgroundColor = .clear; table.rowHeight = 25
        table.intercellSpacing = NSSize(width: 5, height: 1)
        table.selectionHighlightStyle = .none
        table.allowsColumnReordering = false; table.allowsColumnResizing = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        for (id, title, width) in [("app", "软件 / 进程", 202.0), ("read", "读取", 84.0), ("write", "写入", 84.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title; column.minWidth = 0; column.width = width; column.resizingMask = []
            column.headerCell.font = .systemFont(ofSize: 10, weight: .medium)
            if id != "app" { column.headerCell.alignment = .center }
            table.addTableColumn(column)
        }
        table.dataSource = self; table.delegate = self
        scroll.documentView = table; scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll); root.addArrangedSubview(container)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
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
    }

    /// 更新当前快照和独立 Top 数量；权限未完整启用时保留容量但不伪造进程速度。
    func refresh() {
        guard isViewLoaded else { return }
        let count = RankingPreferences.count(for: .disk)
        titleLabel.stringValue = "磁盘 · 前 \(count)"
        coverageLabel.stringValue = monitor.isRankingStale ? "结果已过期" : monitor.collectionStatus.summary
            ?? (monitor.deniedProcesses > 0 ? "\(monitor.deniedProcesses) 个受保护" : "管理员采集")
        coverageLabel.textColor = monitor.isRankingStale || monitor.collectionStatus.preservesResult
            ? .systemOrange : .secondaryLabelColor
        coverageLabel.toolTip = "\(monitor.rankingStatus)\n最近成功读取 \(monitor.readableProcesses) 个进程；权限受限 \(monitor.deniedProcesses) 个，退出或暂不可读 \(monitor.skippedProcesses) 个。\(SamplingPreferences.interval) 秒采样。"
        authorizeButton.isHidden = CPUPrivilege.isInstalled && !monitor.collectionStatus.requiresAuthorization
        authorizeButton.title = CPUPrivilege.isInstalled ? "更新 / 授权…" : "授权…"
        orderControl.selectedSegment = monitor.order.rawValue
        rows = Array(monitor.sortedApplications.prefix(count))
        table.reloadData()
        emptyLabel.stringValue = monitor.rankingStatus; emptyLabel.isHidden = !rows.isEmpty
    }

    /// 收起后释放表格和图标缓存，后台不保存完整进程排行。
    func releaseRanking() { rows = []; icons.removeAllObjects(); table.reloadData() }

    /// 只返回用户配置截取后的显示行数。
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    /// 复用网络应用名称单元格，分别渲染读取和写入速度。
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let column = tableColumn else { return nil }
        let app = rows[row]
        if column.identifier.rawValue == "app" {
            let cell = tableView.makeView(withIdentifier: column.identifier, owner: self) as? ApplicationCell ?? ApplicationCell(frame: .zero)
            cell.identifier = column.identifier; cell.nameLabel.stringValue = app.name
            cell.detailLabel.stringValue = app.processes > 1 ? "×\(app.processes)" : ""
            cell.toolTip = app.name + (app.bundlePath.map { "\n\($0)" } ?? "")
            if let path = app.bundlePath {
                if let image = icons.object(forKey: path as NSString) { cell.appIcon.image = image }
                else {
                    let image = NSWorkspace.shared.icon(forFile: path); image.size = NSSize(width: 22, height: 22)
                    icons.setObject(image, forKey: path as NSString); cell.appIcon.image = image
                }
            } else { cell.appIcon.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "系统进程") }
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
        cell.textField?.stringValue = SpeedText.string(column.identifier.rawValue == "read" ? app.read : app.write)
        cell.toolTip = cell.textField?.stringValue
        return cell
    }

    /// 排序设置即时更新当前列表，保持原采样窗口。
    @objc private func changeOrder() { monitor.order = DiskRankingOrder(rawValue: orderControl.selectedSegment) ?? .combined }

    /// 管理员安装通过主应用和系统认证窗口完成。
    @objc private func authorize() { onAuthorize?() }
}
