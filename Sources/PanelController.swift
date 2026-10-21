import AppKit

/// 表格中的 App 名称单元格，复用图标与文本视图，避免刷新时反复创建复杂层级。
final class ApplicationCell: NSTableCellView {
    /// 应用图标，未知进程使用系统通用符号。
    let appIcon = NSImageView()
    /// App 名称，空间不足时尾部省略。
    let nameLabel = NSTextField(labelWithString: "")
    /// 多进程合并的简短说明。
    let detailLabel = NSTextField(labelWithString: "")

    /// 使用固定的轻量布局，所有子视图随 table cell 复用。
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        appIcon.imageScaling = .scaleProportionallyDown
        appIcon.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.font = .systemFont(ofSize: 10)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let labels = NSStackView(views: [nameLabel, detailLabel])
        labels.orientation = .horizontal; labels.alignment = .centerY; labels.spacing = 5
        labels.translatesAutoresizingMaskIntoConstraints = false
        addSubview(appIcon); addSubview(labels)
        NSLayoutConstraint.activate([
            appIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            appIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            appIcon.widthAnchor.constraint(equalToConstant: 18),
            appIcon.heightAnchor.constraint(equalToConstant: 18),
            labels.leadingAnchor.constraint(equalTo: appIcon.trailingAnchor, constant: 5),
            labels.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    /// 本应用不从 nib 反序列化表格单元格。
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// 二级网络详情只展示应用排行、排序和接口来源，总上传下载保留在一级概览。
final class PanelController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    /// 被展示的采集模型，生命周期由 AppDelegate 管理。
    private let monitor: NetworkMonitor
    /// 状态文本，错误和采样状态不会伪装为零速度。
    private let statusLabel = NSTextField(labelWithString: "正在采样…")
    /// 显示物理接口和统计层。
    private let sourceLabel = NSTextField(labelWithString: "物理网络 · IP 流量")
    /// 网络标题随独立的显示数量更新，和 CPU、磁盘使用一致的简短标记。
    private let titleLabel = NSTextField(labelWithString: "网络")
    /// 排行列表按独立的网络 Top 数量展示，上限五十项。
    private let table = NSTableView()
    /// 排行无数据时的说明。
    private let emptyLabel = NSTextField(labelWithString: "正在采样…")
    /// 排序分段按钮，不改变采集源。
    private let orderControl = NSSegmentedControl(labels: ["合计", "下载", "上传"], trackingMode: .selectOne,
                                                   target: nil, action: nil)
    /// 软件 Top 行与可选直连行的统一排序快照；直连不挤占设置中的软件数量。
    private var rows: [NetworkRankingRow] = []
    /// 有界图标缓存，不按每个 PID 存储重复图标。
    private let icons = NSCache<NSString, NSImage>()

    /// 关联模型，创建原生 AppKit 弹出面板。
    init(monitor: NetworkMonitor) {
        self.monitor = monitor
        super.init(nibName: nil, bundle: nil)
        icons.countLimit = 50
    }

    /// 本应用不使用 nib。
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 构建紧凑面板，避免滚动内容改变菜单栏弹窗的整体大小。
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
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        let header = horizontal([title, NSView(), statusLabel])
        root.addArrangedSubview(header); stretch(header, in: root)

        sourceLabel.font = .systemFont(ofSize: 11); sourceLabel.textColor = .secondaryLabelColor
        sourceLabel.lineBreakMode = .byTruncatingTail
        orderControl.segmentStyle = .rounded
        orderControl.controlSize = .small
        orderControl.selectedSegment = monitor.preferences.order.rawValue
        orderControl.target = self; orderControl.action = #selector(changeOrder)
        let toolbar = horizontal([sourceLabel, NSView(), orderControl])
        root.addArrangedSubview(toolbar); stretch(toolbar, in: root)

        let scroll = RankingScrollView(numberColumnWidths: [84, 84])
        table.backgroundColor = .clear
        table.rowHeight = 25; table.intercellSpacing = NSSize(width: 5, height: 1)
        table.selectionHighlightStyle = .none
        table.allowsColumnReordering = false; table.allowsColumnResizing = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        for (id, title, width) in [("app", "软件 / 进程", 202.0), ("down", "下载", 84.0), ("up", "上传", 84.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title; column.minWidth = 0; column.width = width
            column.resizingMask = []
            column.headerCell.font = .systemFont(ofSize: 10, weight: .medium)
            if id != "app" { column.headerCell.alignment = .center }
            table.addTableColumn(column)
        }
        table.dataSource = self; table.delegate = self
        scroll.documentView = table
        // NSScrollView 会自行布局内部子视图；空态作为外层容器的覆盖层，避免被挤到表头。
        let rankingContainer = NSView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        rankingContainer.addSubview(scroll)
        root.addArrangedSubview(rankingContainer); stretch(rankingContainer, in: root)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: rankingContainer.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: rankingContainer.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: rankingContainer.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: rankingContainer.bottomAnchor),
            rankingContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 100)
        ])
        emptyLabel.font = .systemFont(ofSize: 12); emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        rankingContainer.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: rankingContainer.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: rankingContainer.centerYAnchor, constant: 10),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: rankingContainer.widthAnchor, constant: -24)
        ])
        sourceLabel.toolTip = "按对外连接统计。VPN、代理及系统服务可能单独计入，排行合计不等于网卡总量。"
    }

    /// 数据帧到达时更新文本和可见表格，不使用独立 UI 刷新计时器。
    func refresh() {
        guard isViewLoaded else { return }
        titleLabel.stringValue = "网络 · 前 \(RankingPreferences.count(for: .network))"
        statusLabel.stringValue = monitor.status == "实时" ? "● 实时 · \(monitor.preferences.interval)秒" : monitor.status
        statusLabel.textColor = monitor.status == "实时" ? .systemGreen : .secondaryLabelColor
        sourceLabel.stringValue = monitor.sourceDescription.components(separatedBy: " · ").first ?? monitor.sourceDescription
        sourceLabel.toolTip = monitor.sourceDescription + "。包含普通网络和设备直连；排除回环和 VPN 接口的重复总量，软件排行与接口总量的统计层不同。"
        var ranking = monitor.sortedApplications.prefix(RankingPreferences.count(for: .network)).map(NetworkRankingRow.application)
        if monitor.directActivity.isVisible, let down = monitor.directDownload, let up = monitor.directUpload {
            ranking.append(.direct(download: down, upload: up, idle: monitor.directActivity.isIdle))
        }
        rows = NetworkRankingRow.sorted(ranking, by: monitor.preferences.order)
        table.reloadData()
        emptyLabel.stringValue = monitor.rankingStatus
        emptyLabel.isHidden = !rows.isEmpty
        orderControl.selectedSegment = monitor.preferences.order.rawValue
    }

    /// 面板关闭时释放图标及表格快照，保持低常驻内存。
    func releaseRanking() { rows = []; icons.removeAllObjects(); table.reloadData() }

    /// 提供当前采样快照的行数。
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    /// 复用单元格，图标只在第一次出现时解析。
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let column = tableColumn else { return nil }
        let item = rows[row], app = item.application
        if column.identifier.rawValue == "app" {
            let cell = tableView.makeView(withIdentifier: column.identifier, owner: self) as? ApplicationCell
                ?? ApplicationCell(frame: .zero)
            cell.identifier = column.identifier
            if let app {
                cell.nameLabel.stringValue = app.name
                cell.detailLabel.stringValue = app.processes > 1 ? "×\(app.processes)" : ""
                cell.toolTip = app.name + (app.bundlePath.map { "\n\($0)" } ?? "")
                if let path = app.bundlePath {
                    if let image = icons.object(forKey: path as NSString) { cell.appIcon.image = image }
                    else {
                        let image = NSWorkspace.shared.icon(forFile: path)
                        image.size = NSSize(width: 22, height: 22)
                        icons.setObject(image, forKey: path as NSString)
                        cell.appIcon.image = image
                    }
                } else { cell.appIcon.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "系统进程") }
            } else {
                cell.nameLabel.stringValue = item.name
                cell.detailLabel.stringValue = item.isIdle ? "短暂停顿" : "隔空投送等"
                cell.appIcon.image = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right", accessibilityDescription: "设备直连传输")
                cell.toolTip = directDescription
            }
            return cell
        }
        let cell = tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTableCellView
            ?? NSTableCellView()
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
        let speed = column.identifier.rawValue == "down" ? item.download : item.upload
        cell.textField?.stringValue = SpeedText.string(speed)
        cell.toolTip = app == nil ? directDescription : cell.textField?.stringValue
        return cell
    }

    /// 解释临时传输条目的独立统计范围；放在悬停提示中，列表只展示名称与当前速度。
    private var directDescription: String {
        "\(monitor.directSourceDescription) · \(monitor.preferences.interval)秒刷新\n此速度已计入上方及菜单栏总量，包含隔空投送等设备间连接。对应连接不在普通软件行重复展示；不代表纯文件有效载荷。零流量短暂停顿后自动隐藏。"
    }

    /// 排序偏好立即持久化，不重启底层采集。
    @objc private func changeOrder() {
        monitor.preferences.order = RankingOrder(rawValue: orderControl.selectedSegment) ?? .combined
        refresh()
    }

    /// 创建水平布局行，NSView 占位可自动吸收剩余宽度。
    private func horizontal(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = 3
        return stack
    }

    /// 使内容行与根容器保持同宽，避免辅助文本把面板撑宽。
    private func stretch(_ child: NSView, in parent: NSView) {
        child.widthAnchor.constraint(equalTo: parent.widthAnchor).isActive = true
    }
}
