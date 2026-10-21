import AppKit
import ServiceManagement

/// 独立设置窗口，登录启动状态以系统实际登记结果为准，避免开关与系统设置不一致。
final class SettingsController: NSWindowController {
    /// 修改后通知模型重建采样基线。
    private let monitor: NetworkMonitor
    /// 修改统一间隔时重建 CPU 整机与详情基线。
    private let cpu: CPUMonitor
    /// 电源与风扇的可见快速采样随设置更新，后台低频整机采样由趋势采集器管理。
    private let power: PowerMonitor
    /// 管理员授权操作交由主应用处理，窗口不持有系统授权引用。
    var onCPUAuthorization: (() -> Void)?
    /// 显示选项改变后立即刷新菜单栏及电池观察，不重建任何已有采样基线。
    var onMenuBarChange: (() -> Void)?
    /// 管理员采集服务的安装或更新入口。
    private let cpuAuthorization = NSButton(title: "授权系统进程采集…", target: nil, action: nil)
    /// 解释管理员服务同时用于 CPU、内存和磁盘进程统计，不改变自启动开关。
    private let cpuAuthorizationStatus = NSTextField(wrappingLabelWithString: "")
    /// 系统登录启动开关，不使用 UserDefaults 伪造注册状态。
    private let loginToggle = NSButton(checkboxWithTitle: "登录 Mac 后自动启动", target: nil, action: nil)
    /// 系统登记结果或错误信息。
    private let loginStatus = NSTextField(wrappingLabelWithString: "")
    /// 仅在系统要求批准时出现，避免把系统登录项管理误解为另一个自启动开关。
    private let loginApprovalButton = NSButton(title: "前往系统设置批准…", target: nil, action: nil)
    /// 唯一的采样间隔选择框，同时控制网络、CPU、内存、电源、风扇和磁盘。
    private let intervalMenu = NSPopUpButton()
    /// 物理网络接口选择框。
    private let interfaceMenu = NSPopUpButton()
    /// 每项均可独立勾选；最后一个已选控件禁用取消，确保保留可点击的菜单栏入口。
    private let menuBarToggles = Dictionary(uniqueKeysWithValues: MenuBarComponent.allCases.map {
        ($0, NSButton(checkboxWithTitle: $0.title, target: nil, action: nil))
    })
    /// 网络、CPU、内存和磁盘各有独立的输入框与步进按钮，不共用一个显示条数。
    private let countControls = Dictionary(uniqueKeysWithValues: RankingPreferences.Section.allCases.map {
        ($0, RankingCountControl(section: $0))
    })

    /// 使用固定大小原生设置窗口；关闭仅隐藏，不退出菜单栏程序。
    init(monitor: NetworkMonitor, cpu: CPUMonitor, power: PowerMonitor) {
        self.monitor = monitor
        self.cpu = cpu
        self.power = power
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 637),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "监控设置"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        construct()
        window.center()
    }

    /// 本窗口完全由代码构建。
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 展示前重新读取系统状态和网络接口，兼容用户在系统设置里取消登录项。
    func present() {
        refresh()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// 创建偏好控件与简短省电说明。
    private func construct() {
        guard let content = window?.contentView else { return }
        let root = NSStackView()
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 17
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -26),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 25)
        ])
        loginToggle.target = self; loginToggle.action = #selector(changeLogin)
        let loginGroup = NSStackView()
        loginGroup.orientation = .vertical; loginGroup.alignment = .leading; loginGroup.spacing = 7
        root.addArrangedSubview(loginGroup)
        loginGroup.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        loginGroup.addArrangedSubview(loginToggle)
        loginStatus.font = .systemFont(ofSize: 11); loginStatus.textColor = .secondaryLabelColor
        loginGroup.addArrangedSubview(loginStatus)
        loginStatus.widthAnchor.constraint(equalTo: loginGroup.widthAnchor).isActive = true
        loginApprovalButton.target = self; loginApprovalButton.action = #selector(openLoginSettings)
        loginApprovalButton.bezelStyle = .rounded
        loginApprovalButton.isHidden = true
        loginGroup.addArrangedSubview(loginApprovalButton)
        let menuBarControls = NSStackView(views: MenuBarComponent.allCases.compactMap { menuBarToggles[$0] })
        menuBarControls.orientation = .horizontal; menuBarControls.alignment = .centerY; menuBarControls.spacing = 12
        for toggle in menuBarToggles.values {
            toggle.font = .systemFont(ofSize: 12)
            toggle.target = self; toggle.action = #selector(changeMenuBarContents)
            toggle.toolTip = "立即调整菜单栏显示，至少保留一项；不影响弹窗中的资源内容。"
        }
        addRow("菜单栏显示内容", control: menuBarControls, to: root)
        intervalMenu.addItems(withTitles: ["1 秒", "2 秒（推荐）", "5 秒"])
        for (item, value) in zip(intervalMenu.itemArray, [1, 2, 5]) { item.tag = value }
        intervalMenu.target = self; intervalMenu.action = #selector(changeIntervals)
        addRow("采样间隔", control: intervalMenu, to: root)
        intervalMenu.toolTip = "设置网络、CPU、内存和磁盘读写周期；电源与风扇后台至少间隔五秒，容量至少间隔十秒。应用排行仅在弹窗打开时采集。"
        interfaceMenu.target = self; interfaceMenu.action = #selector(changeInterface)
        interfaceMenu.toolTip = "选择普通网速统计的物理网络；设备直连接口独立汇总，不受此选择影响。"
        addRow("统计网络", control: interfaceMenu, to: root)
        for section in RankingPreferences.Section.allCases {
            if let control = countControls[section] { addRow(section.title, control: control, to: root) }
        }
        let separator = NSBox(); separator.boxType = .separator
        root.addArrangedSubview(separator); separator.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        cpuAuthorization.target = self; cpuAuthorization.action = #selector(authorizeCPU)
        cpuAuthorization.bezelStyle = .rounded
        root.addArrangedSubview(cpuAuthorization)
        cpuAuthorizationStatus.font = .systemFont(ofSize: 11); cpuAuthorizationStatus.textColor = .secondaryLabelColor
        root.addArrangedSubview(cpuAuthorizationStatus)
        cpuAuthorizationStatus.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        let note = NSTextField(wrappingLabelWithString: "整机趋势保留最近24小时，范围可选1分钟、10分钟、1小时和24小时。功率与风扇后台低频读取；应用排行仅在弹窗打开时采集，数量分别保存。CPU 与内存展开的子进程最多10个。锁屏、息屏或休眠暂停，缺失区间不补零。")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        root.addArrangedSubview(note); note.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    }

    /// 设置行使用统一对齐，保证文字与控件不互相挤压。
    private func addRow(_ title: String, control: NSView, to root: NSStackView) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        let row = NSStackView(views: [label, NSView(), control])
        row.orientation = .horizontal; row.alignment = .centerY
        root.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        control.widthAnchor.constraint(equalToConstant: 245).isActive = true
    }

    /// 从系统服务状态恢复控件，避免把 requiresApproval 显示成已启用。
    private func refresh() {
        let status = SMAppService.mainApp.status
        loginToggle.state = status == .enabled ? .on : .off
        loginApprovalButton.isHidden = status != .requiresApproval
        switch status {
        case .enabled: loginStatus.stringValue = "已启用，登录后在菜单栏运行。"
        case .requiresApproval: loginStatus.stringValue = "需要系统批准，请前往“登录项”允许网络速度自动启动。"
        default: loginStatus.stringValue = "开启后，每次登录 Mac 都会自动显示菜单栏网速。"
        }
        intervalMenu.selectItem(withTag: monitor.preferences.interval)
        refreshMenuBarControls()
        for control in countControls.values { control.refresh() }
        cpuAuthorization.title = CPUPrivilege.isInstalled ? "更新 / 重新授权系统进程采集…" : "授权系统进程采集…"
        cpuAuthorizationStatus.stringValue = CPUPrivilege.isInstalled
            ? "CPU、内存与磁盘共用管理员服务。仅在弹窗展开时读取，详情关闭后自动退出。"
            : "授权后读取 CPU、内存和磁盘的系统及其他用户进程。管理员密码仅在 macOS 系统窗口输入。"
        monitor.refreshInterfaces()
        interfaceMenu.removeAllItems()
        interfaceMenu.addItem(withTitle: "自动汇总物理网络")
        interfaceMenu.lastItem?.representedObject = ""
        for interface in monitor.interfaces {
            interfaceMenu.addItem(withTitle: "\(interface.title) (\(interface.name))")
            interfaceMenu.lastItem?.representedObject = interface.name
        }
        if !monitor.preferences.interface.isEmpty,
           !monitor.interfaces.contains(where: { $0.name == monitor.preferences.interface }) {
            interfaceMenu.addItem(withTitle: "\(monitor.preferences.interface)（当前不可用）")
            interfaceMenu.lastItem?.representedObject = monitor.preferences.interface
        }
        if let item = interfaceMenu.itemArray.first(where: { ($0.representedObject as? String) == monitor.preferences.interface }) {
            interfaceMenu.select(item)
        }
    }

    /// 从持久化选择恢复三项状态；仅剩一项时禁止取消该项，其他选项仍可继续勾选。
    private func refreshMenuBarControls() {
        let selected = MenuBarPreferences.components
        for (component, toggle) in menuBarToggles {
            toggle.state = selected.contains(component) ? .on : .off
            toggle.isEnabled = selected.count > 1 || !selected.contains(component)
        }
    }

    /// 保存多选内容并立即通知菜单栏；无效空选择恢复原值，不改变其他设置或采样。
    @objc private func changeMenuBarContents() {
        let selected = Set(menuBarToggles.compactMap { $0.value.state == .on ? $0.key : nil })
        let saved = MenuBarPreferences.setComponents(selected)
        refreshMenuBarControls()
        if saved { onMenuBarChange?() }
    }

    /// 由用户显式开关官方登录项，保留系统返回的真实失败原因。
    @objc private func changeLogin() {
        do {
            if loginToggle.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            refresh()
        } catch {
            refresh()
            loginStatus.stringValue = "设置未完成：\(error.localizedDescription)"
        }
    }

    /// 保存统一偏好并重建采样；内存和磁盘随 CPU 同轮更新，隐藏的详情仍保持停止。
    @objc private func changeIntervals() {
        monitor.preferences.interval = intervalMenu.selectedTag()
        monitor.restart()
        cpu.restart()
        power.restart()
    }

    /// 用户点击后触发系统授权，而非在后台自动弹出密码框。
    @objc private func authorizeCPU() { onCPUAuthorization?() }

    /// 切换接口立即清除旧网卡速度，等待新采样基线。
    @objc private func changeInterface() {
        monitor.preferences.interface = interfaceMenu.selectedItem?.representedObject as? String ?? ""
        monitor.restart()
    }

    /// 打开 Apple 提供的登录项面板，处理用户或系统要求的批准状态。
    @objc private func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// 单个模块的 Top 数量控件，支持直接输入和加减，编辑结束时验证并独立保存。
final class RankingCountControl: NSStackView, NSTextFieldDelegate {
    /// 持久化键由模块决定，其他模块的设置不受修改影响。
    private let section: RankingPreferences.Section
    /// 输入值限制为一至五十，非法文字恢复当前设置。
    private let field = NSTextField(string: "")
    /// 原生步进按钮与输入框双向同步，不触发采样重启。
    private let stepper = NSStepper()

    /// 控件和数字范围说明共用一行，保持原设置窗口的对齐方式。
    init(section: RankingPreferences.Section) {
        self.section = section
        super.init(frame: .zero)
        orientation = .horizontal; alignment = .centerY; spacing = 8
        field.delegate = self; field.alignment = .right
        field.target = self; field.action = #selector(commit)
        field.setAccessibilityLabel(section.title)
        field.widthAnchor.constraint(equalToConstant: 62).isActive = true
        stepper.minValue = 1; stepper.maxValue = Double(RankingPreferences.maximumCount)
        stepper.increment = 1; stepper.valueWraps = false
        stepper.target = self; stepper.action = #selector(step)
        let label = NSTextField(labelWithString: "项（1～50）")
        label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor
        addArrangedSubview(NSView()); addArrangedSubview(field)
        addArrangedSubview(stepper); addArrangedSubview(label)
        refresh()
    }

    /// 设置控件仅以代码构造。
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 窗口重新展示时从独立持久化键恢复，不依赖上次界面中的文字。
    func refresh() {
        let value = RankingPreferences.count(for: section)
        field.stringValue = String(value); stepper.integerValue = value
    }

    /// 点击加减后立即保存对应模块的条数。
    @objc private func step() { RankingPreferences.setCount(stepper.integerValue, for: section); refresh() }

    /// 回车和编辑结束采用同一输入校验，防止零、负值或过大的条数进入列表。
    @objc private func commit() {
        let value = Int(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? RankingPreferences.count(for: section)
        RankingPreferences.setCount(value, for: section); refresh()
    }

    /// 点击其他控件或关闭设置窗口时同样提交已输入的条数。
    func controlTextDidEndEditing(_ obj: Notification) { commit() }
}
