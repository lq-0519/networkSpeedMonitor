import AppKit
import CoreGraphics

/// 管理菜单栏、窗口和系统生命周期；主程序不申请辅助功能、录屏或常驻管理员权限。
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    /// 全应用共享一个模型，菜单栏和弹窗不会各自重复采集总量。
    private let monitor = NetworkMonitor()
    /// CPU 与网络共用应用生命周期，详情采样各自按需启停。
    private let cpu = CPUMonitor()
    /// 电源与风扇仅在弹窗展开期间同轮采样，不参与菜单栏内容或常驻刷新。
    private let power = PowerMonitor()
    /// 菜单栏电池独立接收系统电源通知，不带动弹窗功率、风扇或历史读取。
    private let battery = BatteryMonitor()
    /// 内存整机标量与趋势共用读取，进程排行仍仅在弹窗打开时接收 CPU 快照。
    private let memory = MemoryMonitor(systemManagedExternally: true)
    /// 系统盘容量共用后台轻量读取，管理员进程磁盘排行仍按需运行。
    private let disk = DiskMonitor(systemManagedExternally: true)
    /// 全应用共用最近二十四小时的本地精简历史，独立于系统电量 Powerlog。
    private let history = TrendHistoryStore()
    /// 复用 CPU 唤醒周期，后台不枚举进程，不创建额外高频定时器。
    private lazy var trendSampler = TrendSampler(history: history)
    /// 常见速度使用紧凑固定宽度，仅在超长数值时扩展以避免裁切。
    private var statusItem: NSStatusItem?
    /// 接收按钮外观变化；系统生成菜单栏快照时也会临时改变外观，因此通知不直接使绘制缓存失效。
    private var statusAppearanceObservation: NSKeyValueObservation?
    /// 同一轮主队列只安排一次外观刷新，待系统恢复快照的临时外观后，再由内容与最终外观共同去重。
    private var statusAppearanceRefreshPending = false
    /// 合并短时间内的 CPU、网速、电池通知；一次性任务只延后绘图，不改变采样或历史记录时刻。
    private var statusRefreshWork: DispatchWorkItem?
    /// 辅助功能名称只随组件选择变化；外观快照和数值更新不重复提交相同名称。
    private var statusAccessibilityLabel: String?
    /// 原生弹窗，点击外部区域自动关闭。
    private let popover = NSPopover()
    /// 弹窗内容控制器，按首次展开创建。
    private lazy var panel = OverviewPanelController(network: monitor, cpu: cpu, power: power,
                                                     memory: memory, disk: disk, history: history)
    /// 设置窗口，按首次打开创建。
    private lazy var settings = SettingsController(monitor: monitor, cpu: cpu, power: power)
    /// 系统通知观察者，退出时一并移除。
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    /// 屏幕与系统睡眠可能重叠，分别记录以避免过早恢复采集。
    private var sleepReasons = Set<String>()
    /// 状态按钮最近显示的文本，减少空闲时重复绘制。
    private var lastTitle = ""
    /// 记住当前显示配置下曾使用的最大网速列宽；小缓冲被长数字占用后不随数值回落而回缩。
    private var statusNetworkWidth: CGFloat = 0
    /// 安装更新发送 SIGTERM 时走正常退出路径，等待采集进程回收。
    private var terminationSignal: DispatchSourceSignal?
    /// 一级弹窗改为手动管理后，本地事件监听负责 Escape 和应用内外部点击。
    private var localPopoverMonitor: Any?
    /// 点击其他应用时关闭一级与二级浮层；只监听鼠标，不申请全局键盘辅助权限。
    private var globalPopoverMonitor: Any?

    /// 创建状态按钮、连接模型并订阅系统事件；重复启动时只激活已有实例。
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: "com.local.NetworkSpeedMonitor")
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate(options: [.activateIgnoringOtherApps])
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination.setEventHandler { NSApp.terminate(nil) }
        termination.resume()
        terminationSignal = termination
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出网络速度", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem); NSApp.mainMenu = menu
        let item = NSStatusBar.system.statusItem(withLength: 88)
        item.autosaveName = "NetworkSpeedMonitor.Status"
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        item.button?.imagePosition = .imageOnly
        item.button?.imageScaling = .scaleNone
        statusItem = item
        statusAppearanceObservation = item.button?.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            guard let self, !self.statusAppearanceRefreshPending else { return }
            self.statusAppearanceRefreshPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.statusAppearanceRefreshPending = false
                // 快照重绘会先切换再恢复外观；保留缓存，避免同一图像反复赋值后再次触发快照。
                self.refreshStatusItem()
            }
        }
        // 二级浮层中的表格和按钮属于另一个窗口，一级必须手动判断联合区域后再关闭。
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self
        cpu.onSystemSample = { [weak self] usage, time, uptime, interval in
            self?.trendSampler.tick(cpu: usage, at: time, uptime: uptime, interval: interval)
        }
        cpu.onSystemReset = { [weak self] suspended in self?.trendSampler.reset(suspended: suspended) }
        monitor.onSystemSample = { [weak self] down, up, time, segment, interval in
            self?.history.append(time: time, segment: segment, spacing: Double(interval),
                                 values: [TrendValue(metric: .download, value: down), TrendValue(metric: .upload, value: up)])
        }
        power.onSample = { [weak self] snapshot, fans, time, interval in
            self?.trendSampler.receivePower(snapshot, fans: fans, at: time, interval: interval)
        }
        trendSampler.onSystemUpdate = { [weak self] usage, capacity in
            self?.memory.receiveSystem(usage); self?.disk.receiveSystem(capacity)
        }
        history.onAppend = { [weak self] sample in
            guard let self, self.popover.isShown else { return }
            self.panel.receiveTrend(sample)
        }
        monitor.onUpdate = { [weak self] in
            guard let self else { return }
            self.requestStatusItemRefresh()
            if self.popover.isShown { self.panel.refreshNetwork() }
        }
        cpu.onUpdate = { [weak self] in
            guard let self else { return }
            self.requestStatusItemRefresh()
            if self.popover.isShown { self.panel.refreshCPU() }
        }
        power.onUpdate = { [weak self] in
            guard let self, self.popover.isShown else { return }
            self.panel.refreshPower()
            self.panel.refreshFans()
        }
        battery.onUpdate = { [weak self] in self?.requestStatusItemRefresh() }
        cpu.onProcessSnapshot = { [weak self] snapshot, status in
            guard let self else { return }
            self.memory.receive(snapshot, status: status)
            self.disk.receive(snapshot, status: status)
        }
        memory.onUpdate = { [weak self] in
            guard let self, self.popover.isShown else { return }
            self.panel.refreshMemory()
        }
        disk.onUpdate = { [weak self] in
            guard let self, self.popover.isShown else { return }
            self.panel.refreshDisk()
        }
        observeSleep()
        // 安装更新或登录项可能在已有锁屏中启动，不能只依赖启动之后才收到的通知。
        sleepReasons.formUnion(Self.initialPauseReasons(session: CGSessionCopyCurrentDictionary() as? [String: Any]))
        applySleepReasons()
        monitor.start()
        cpu.restart()
        applyMenuBarPreferences()
        if CommandLine.arguments.contains("--show") || CommandLine.arguments.contains("--show-cpu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.togglePanel() }
        }
    }

    /// Finder 再次打开时展示统一面板；已有设置窗口时不在其后额外弹出面板。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 状态栏内部窗口也可能计入 flag，显式检查有标题的设置窗口，避免无法重新打开。
        let settingsVisible = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
        if !settingsVisible && !popover.isShown { togglePanel() }
        return true
    }

    /// 点击桌面或其他应用导致本应用失去激活时，强制关闭一级及其二级子窗口。
    func applicationDidResignActive(_ notification: Notification) {
        closePopover()
    }

    /// 退出时停止所有采集进程，不保留后台工作。
    func applicationWillTerminate(_ notification: Notification) {
        statusRefreshWork?.cancel(); statusRefreshWork = nil
        monitor.shutdown()
        cpu.shutdown()
        power.shutdown()
        trendSampler.shutdown()
        history.shutdown()
        battery.shutdown()
        statusAppearanceObservation?.invalidate(); statusAppearanceObservation = nil
        memory.setVisible(false)
        disk.setVisible(false)
        stopPopoverEventMonitoring()
        panel.closeDetail()
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
    }

    /// 按钮点击打开或关闭排行，确保关闭时没有继续运行应用采集器。
    @objc private func togglePanel() {
        if popover.isShown { closePopover(); return }
        guard sleepReasons.isEmpty else { return }
        guard let button = statusItem?.button else { return }
        panel.onSettings = { [weak self] in
            guard let self else { return }
            self.closePopover()
            self.settings.onCPUAuthorization = { [weak self] in self?.authorizeCPU() }
            self.settings.onMenuBarChange = { [weak self] in self?.applyMenuBarPreferences() }
            self.settings.present()
        }
        panel.onAuthorize = { [weak self] in self?.authorizeCPU() }
        panel.onActivityMonitor = { [weak self] url in self?.openActivityMonitor(at: url) }
        panel.onContentSizeChange = { [weak self] size in self?.resizePanel(to: size) }
        popover.contentViewController = panel
        resizePanel(to: panel.fittingContentSize)
        history.flush()
        trendSampler.setDetailsVisible(true)
        // 点击菜单栏后立即启动全部既有详情采样；悬浮只决定哪张快照被渲染。
        memory.setVisible(true)
        disk.setVisible(true)
        monitor.setRankingVisible(true)
        cpu.setRankingVisible(true)
        power.setVisible(true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        guard popover.isShown else {
            monitor.setRankingVisible(false); cpu.setRankingVisible(false)
            power.setVisible(false); memory.setVisible(false); disk.setVisible(false)
            trendSampler.setDetailsVisible(false)
            return
        }
        startPopoverEventMonitoring()
        panel.refreshNetwork(); panel.refreshCPU(); panel.refreshMemory()
        panel.refreshPower(); panel.refreshFans(); panel.refreshDisk()
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// 按可见内容的自然尺寸更新一级窗口，不读取旧的拖动高度，不重启采样或创建滚动区域。
    private func resizePanel(to size: NSSize) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        if popover.contentSize != size { popover.contentSize = size }
    }

    /// 统一面板关闭时停止详细采样与全部排行，释放辅助连接；后台整机趋势恢复低频读取。
    func popoverDidClose(_ notification: Notification) {
        guard !popover.isShown else { return }
        stopPopoverEventMonitoring()
        panel.closeDetail()
        monitor.setRankingVisible(false); cpu.setRankingVisible(false)
        power.setVisible(false)
        trendSampler.setDetailsVisible(false)
        memory.setVisible(false)
        disk.setVisible(false)
        panel.releaseRanking()
    }

    /// 手动管理一级与二级的联合点击区域，既保留详情控件交互，也恢复点击外部自动关闭。
    private func startPopoverEventMonitoring() {
        stopPopoverEventMonitoring()
        localPopoverMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                if !self.panel.closeDetailIfVisible() { self.closePopover() }
                return nil
            }
            if event.type != .keyDown {
                let primaryWindow = self.popover.contentViewController?.view.window
                let statusWindow = self.statusItem?.button?.window
                if event.window !== primaryWindow,
                   event.window !== statusWindow,
                   !self.panel.ownsDetailWindow(event.window) {
                    self.closePopover()
                }
            }
            return event
        }
        globalPopoverMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.closePopover() }
        }
    }

    /// 先关闭二级子窗口再关闭 applicationDefined popover，避免子窗口阻挡外部点击收起流程。
    private func closePopover() {
        guard popover.isShown else { return }
        panel.closeDetail()
        popover.performClose(nil)
    }

    /// 移除仅在一级可见期间存在的事件监听，避免关闭后继续观察系统点击。
    private func stopPopoverEventMonitoring() {
        if let localPopoverMonitor {
            NSEvent.removeMonitor(localPopoverMonitor)
            self.localPopoverMonitor = nil
        }
        if let globalPopoverMonitor {
            NSEvent.removeMonitor(globalPopoverMonitor)
            self.globalPopoverMonitor = nil
        }
    }

    /// 关闭详情后打开并激活系统活动监视器；已运行时复用现有实例，失败时展示系统错误。
    private func openActivityMonitor(at url: URL) {
        closePopover()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "无法打开活动监视器"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    /// 系统负责管理员认证和固定签名辅助程序安装；应用不读取或保存密码。
    private func authorizeCPU() {
        closePopover()
        do {
            try CPUPrivilege.install()
            cpu.authorizationChanged()
            settings.present()
            if let window = settings.window { window.orderOut(nil) }
            togglePanel()
        } catch {
            let alert = NSAlert()
            alert.messageText = "系统进程采集尚未启用"
            alert.informativeText = "\(error.localizedDescription)\n整机 CPU 与内存概览仍可正常显示。可以稍后在设置中重新授权。"
            alert.runModal()
        }
    }

    /// 显示偏好只更新菜单栏与轻量电池观察，不重启网络、CPU 或任何弹窗采样。
    private func applyMenuBarPreferences() {
        statusNetworkWidth = 0
        battery.setEnabled(MenuBarPreferences.components.contains(.battery))
        refreshStatusItem()
    }

    /// 首个通知后最多等待 150 毫秒合并相邻更新；后续通知不顺延期限，持续变化也不会饿死刷新。
    private func requestStatusItemRefresh() {
        guard statusRefreshWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.statusRefreshWork = nil
            self.refreshStatusItem()
        }
        statusRefreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150), execute: work)
    }

    /// 在按钮当前外观下生成一张原生位图；设置与外观变化立即应用，并取消已经被覆盖的合并任务。
    private func refreshStatusItem() {
        statusRefreshWork?.cancel(); statusRefreshWork = nil
        guard let button = statusItem?.button else { return }
        let components = MenuBarPreferences.components
        let down = monitor.download.map(SpeedText.string) ?? "—"
        let up = monitor.upload.map(SpeedText.string) ?? "—"
        let cpuValue = cpu.usage.flatMap { $0.total.isFinite ? min(100, max(0, $0.total)) : nil }
        let percent = cpuValue.map { Int($0.rounded()) }
        let cpuText = percent.map(String.init) ?? "—"
        let batteryStatus = battery.snapshot
        let selection = MenuBarComponent.allCases.filter(components.contains)
        let title = [selection.map(\.rawValue).joined(separator: ","), button.effectiveAppearance.name.rawValue,
                     components.contains(.cpu) ? cpuValue.map { String(format: "%.2f", $0) } ?? "—" : "",
                     components.contains(.network) ? "\(down)|\(up)" : "",
                     components.contains(.battery) ? "\(batteryStatus?.percentageText ?? "—")|\(batteryStatus?.secondaryText ?? "—")|\(batteryStatus?.showsLightning == true)" : ""]
            .joined(separator: "|")
        if title != lastTitle {
            if components.contains(.network) {
                statusNetworkWidth = max(statusNetworkWidth, StatusItemImage.networkWidth(download: down, upload: up))
            }
            var image: NSImage?
            button.effectiveAppearance.performAsCurrentDrawingAppearance {
                image = StatusItemImage.make(download: down, upload: up, cpuPercent: cpuValue,
                                             components: components, battery: batteryStatus, minimumNetworkWidth: statusNetworkWidth)
            }
            if let image {
                // 原有按钮两侧各 4pt 留白保持不变，内容整体交给按钮处理非活动和选中状态。
                let width = image.size.width + 8
                if statusItem?.length != width { statusItem?.length = width }
                button.image = image
                lastTitle = title
            }
        }
        let directDown = monitor.directDownload.map(SpeedText.string) ?? "—"
        let directUp = monitor.directUpload.map(SpeedText.string) ?? "—"
        let directDetail = monitor.directActivity.isVisible ? "\n设备直连：接收 \(directDown) · 发送 \(directUp)" : ""
        var details: [String] = []
        if components.contains(.network) {
            details.append("下载 \(down) · 上传 \(up)\(directDetail)\n\(monitor.sourceDescription) · \(monitor.status)")
        }
        if components.contains(.cpu) { details.append("整机 CPU：\(cpuText)% · \(cpu.interval) 秒刷新") }
        if components.contains(.battery) { details.append(batteryStatus?.detailText ?? "电池数据不可用") }
        let detail = details.joined(separator: "\n")
        if button.toolTip != detail {
            button.toolTip = detail
            button.setAccessibilityValue(details.joined(separator: "，"))
        }
        let label = selection.map(\.title).joined(separator: "、")
        if statusAccessibilityLabel != label {
            button.setAccessibilityLabel(label)
            statusAccessibilityLabel = label
        }
    }

    /// 将屏幕、系统睡眠及会话事件转换成暂停原因，所有回调串行进入主线程。
    private func observeSleep() {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification, reason: "sleep", pause: true)
        observe(workspace, NSWorkspace.didWakeNotification, reason: "sleep", pause: false)
        observe(workspace, NSWorkspace.screensDidSleepNotification, reason: "screen", pause: true)
        observe(workspace, NSWorkspace.screensDidWakeNotification, reason: "screen", pause: false)
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification, reason: "session", pause: true)
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification, reason: "session", pause: false)
        // 分布式锁屏通知只作为额外省电信号；基础生命周期依赖公开 NSWorkspace 通知。
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, NSNotification.Name("com.apple.screenIsLocked"), reason: "lock", pause: true)
        observe(distributed, NSNotification.Name("com.apple.screenIsUnlocked"), reason: "lock", pause: false)
    }

    /// 从启动时的当前会话快照补齐暂停原因，避免锁屏中更新后错过过去的通知。
    /// 锁屏键为系统补充字段；缺失时不猜测状态，继续由既有生命周期通知控制，且不保存会话身份。
    static func initialPauseReasons(session: [String: Any]?) -> Set<String> {
        var reasons = Set<String>()
        if session?["CGSSessionScreenIsLocked"] as? Bool == true { reasons.insert("lock") }
        if session?[kCGSessionOnConsoleKey as String] as? Bool == false { reasons.insert("session") }
        return reasons
    }

    /// 启动快照和之后的通知共用同一暂停入口；多个原因重叠时，全部解除后才重新采样。
    private func applySleepReasons() {
        if !sleepReasons.isEmpty { closePopover() }
        monitor.setSuspended(!sleepReasons.isEmpty)
        cpu.setSuspended(!sleepReasons.isEmpty)
        battery.setSuspended(!sleepReasons.isEmpty)
    }

    /// 注册一个成对生命周期通知，记录 token 以便退出时清理。
    private func observe(_ center: NotificationCenter, _ name: Notification.Name, reason: String, pause: Bool) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if pause { self.sleepReasons.insert(reason) }
            else { self.sleepReasons.remove(reason) }
            self.applySleepReasons()
        }
        observers.append((center, token))
    }
}
