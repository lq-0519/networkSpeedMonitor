import AppKit
import Darwin
import Network
import SystemConfiguration

/// 可选择的物理网络接口；自动汇总只使用硬件接口，排除 VPN、回环和桥接造成的双计数。
struct NetworkInterface {
    /// 系统 BSD 接口名，例如 en0。
    let name: String
    /// 用户可读的本地化名称，例如 Wi-Fi。
    let title: String
}

/// 常驻配置；使用固定 Bundle ID 对应的 UserDefaults，仅在用户修改时持久化。
final class Preferences {
    /// 主程序的固定配置域。
    private let defaults = UserDefaults.standard
    /// 网络总量与排行读取全应用的统一间隔；CPU 和电源使用同一个持久化值。
    var interval: Int {
        get { SamplingPreferences.interval }
        set { SamplingPreferences.interval = newValue }
    }
    /// 空字符串表示自动汇总物理接口，其他值为用户选择的 BSD 名称。
    var interface: String {
        get { defaults.string(forKey: "networkInterface") ?? "" }
        set { defaults.set(newValue, forKey: "networkInterface") }
    }
    /// 用户选择的排行榜排序方向。
    var order: RankingOrder {
        get { RankingOrder(rawValue: defaults.integer(forKey: "rankingOrder")) ?? .combined }
        set { defaults.set(newValue.rawValue, forKey: "rankingOrder") }
    }
}

/// 根据进程实际可执行文件定位最外层 App bundle，将浏览器和 Electron 辅助进程合并。
final class ApplicationResolver {
    /// 缓存以可执行文件路径为键，避免 PID 重用时误归属；关闭排行即释放。
    private var cache: [String: (key: String, name: String, bundle: String?)] = [:]

    /// 获取进程归属；不能确认 App 时保留系统进程名称，不猜测代理背后的真实来源。
    func resolve(pid: Int32, fallback: String) -> (key: String, name: String, bundle: String?) {
        // Darwin 的 PROC_PIDPATHINFO_MAXSIZE 是 4 * MAXPATHLEN，宏不能被当前 Swift SDK 导入。
        var buffer = [CChar](repeating: 0, count: 4096)
        let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard count > 0 else { return ("process:\(pid)", fallback, nil) }
        let path = String(cString: buffer)
        return resolve(path: path, pid: pid, fallback: fallback)
    }

    /// CPU 管理员采集器已读取路径时直接复用归类规则，避免主程序重复查询系统进程。
    func resolve(path: String, pid: Int32, fallback: String) -> (key: String, name: String, bundle: String?) {
        guard !path.isEmpty else { return ("process:\(pid)", fallback, nil) }
        if let result = cache[path] { return result }
        var result: (key: String, name: String, bundle: String?) = ("executable:\(path)", fallback, nil)
        let components = (path as NSString).pathComponents
        if let index = components.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) {
            let bundlePath = NSString.path(withComponents: Array(components[...index]))
            let bundle = Bundle(path: bundlePath)
            let title = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? URL(fileURLWithPath: bundlePath).deletingPathExtension().lastPathComponent
            result = (bundlePath, title, bundlePath)
        }
        if cache.count > 2048 { cache.removeAll(keepingCapacity: true) }
        cache[path] = result
        return result
    }

    /// 停止排行时释放应用元数据，避免后台长期保留不再使用的信息。
    func clear() { cache.removeAll() }
}

/// 应用的主线程状态模型，协调总量采集、按需排行、网络变化和睡眠生命周期。
final class NetworkMonitor {
    /// 仅普通总量的实际采样帧触发历史通知，不把排行刷新或接口配置变化当作新样本。
    var onSystemSample: ((Double?, Double?, Date, String, Int) -> Void)?
    /// 网络来源或差分窗口重置后的稳定分段，避免跨接口和休眠连线。
    private var historySegment = UUID().uuidString
    /// UI 和诊断入口订阅的数据更新回调。
    var onUpdate: (() -> Void)?
    /// 持久化的用户偏好。
    let preferences = Preferences()
    /// 当前物理接口目录，供设置页选择。
    private(set) var interfaces: [NetworkInterface] = []
    /// 普通网络与设备直连的完整周期总下载速度；nil 表示尚无可靠数据。
    private(set) var download: Double?
    /// 普通网络与设备直连的完整周期总上传速度；nil 不等于零流量。
    private(set) var upload: Double?
    /// 设备直连的接收速度；作为总量的子集单独展示，nil 表示尚无可靠采样。
    private(set) var directDownload: Double?
    /// 设备直连连接的发送速度，不能视为纯文件有效载荷或无线链路速率。
    private(set) var directUpload: Double?
    /// 系统直连采集本周期报告的接口；空列表可能只是当前没有 AWDL 连接。
    private(set) var directInterfaces: [String] = []
    /// 直连采集沿用总量生命周期；成功的空帧为零，启动中或采集失败保持 nil。
    private(set) var directStatus = "正在采样…"
    /// 临时直连条目随系统 AWDL 帧判断活动及短暂停顿；关闭弹窗后仍更新菜单栏总量。
    private(set) var directActivity = DirectTrafficActivity()
    /// 设备直连接口白名单；连接计数按真实接口归属，不包含 en0、桥接或 VPN 隧道。
    static let directInterfaceNames: Set<String> = ["awdl0", "llw0", "nan0"]
    /// 总量采集的用户可读状态。
    private(set) var status = "正在采样…"
    /// 排行采集的用户可读状态。
    private(set) var rankingStatus = "正在采样…"
    /// 合并后的应用流量，只在排行面板打开期间保存。
    private(set) var applications: [AppTraffic] = []
    /// 当前总量帧实际包含的物理接口。
    private(set) var activeInterfaces: [String] = []
    /// 最近可靠总量帧的单调时间，诊断可据此确认数据新鲜度。
    private(set) var lastSampleTime: TimeInterval?
    /// 是否正在展示排行榜。
    private(set) var rankingVisible = false
    /// 是否因休眠、锁屏或切换用户而暂停。
    private(set) var suspended = false
    /// 低成本普通根路由采集器；与直连使用互斥接口集合，避免重复计入总量。
    private let routeCollector = NettopCollector()
    /// 具有系统网络统计权限的 AWDL 采集路径；普通权限直接订阅 QUIC 可能成功却不返回连接。
    private let directCollector = NettopCollector()
    /// 进程采集器，只在排行榜可见时存在子进程。
    private let appCollector = NettopCollector()
    /// App 归属缓存，避免每次刷新重复读取 bundle。
    private let resolver = ApplicationResolver()
    /// 事件驱动监听网络变化，不通过高频轮询检测接口切换。
    private let pathMonitor = NWPathMonitor()
    /// 首次和后续网络路径的简短签名，避免相同路径通知反复重启采集。
    private var pathSignature: String?
    /// 最近有效普通接口速率，与独立直连速率相加；首次及错误保持 nil，不能当成零流量。
    private var ordinarySpeeds: (download: Double, upload: Double)?
    /// 普通采集的独立状态，防止直连回调覆盖普通采集故障。
    private var ordinaryStatus = "正在采样…"
    /// 仅在弹窗可见时缓存最近应用字节帧；直连故障或恢复时重新归类，避免短暂漏行或双计。
    /// 帧只含进程标签和接口合计，不含连接端点；关闭弹窗、重启或应用采集故障立即释放。
    private var latestApplicationFrame: TrafficFrame?

    /// 连接采集回调并读取本机接口目录；所有外部调用须来自主线程。
    init() {
        refreshInterfaces()
        routeCollector.onFrame = { [weak self] frame in self?.receiveRoutes(frame) }
        routeCollector.onStatus = { [weak self] message in
            guard let self, !self.suspended else { return }
            self.ordinaryStatus = message ?? "正在采样…"
            self.ordinarySpeeds = nil
            self.publishSpeeds()
        }
        directCollector.onFrame = { [weak self] frame in self?.receiveDirect(frame) }
        directCollector.onStatus = { [weak self] message in
            guard let self, !self.suspended else { return }
            let wasAvailable = self.directDownload != nil
            self.directDownload = nil; self.directUpload = nil; self.directInterfaces = []
            self.directStatus = message ?? "正在采样…"
            self.directActivity.reset()
            if wasAvailable, let frame = self.latestApplicationFrame { self.receiveApplications(frame, notify: false) }
            self.publishSpeeds()
        }
        appCollector.onFrame = { [weak self] frame in self?.receiveApplications(frame) }
        appCollector.onStatus = { [weak self] message in
            guard let self, self.rankingVisible, !self.suspended else { return }
            self.rankingStatus = message ?? "正在采样…"
            self.applications = []; self.latestApplicationFrame = nil
            self.onUpdate?()
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let signature = "\(path.status)-" + path.availableInterfaces.map(\.name).sorted().joined(separator: ",")
            DispatchQueue.main.async {
                guard let self, self.pathSignature != signature else { return }
                let previous = self.pathSignature
                self.pathSignature = signature
                self.refreshInterfaces()
                if previous != nil { self.restart() }
            }
        }
    }

    /// 启动事件监听及总量采集；不开启应用排行子进程。
    func start() {
        pathMonitor.start(queue: DispatchQueue(label: "com.local.NetworkSpeedMonitor.path", qos: .utility))
        restart()
    }

    /// 同步释放本程序的采集任务，适用于应用退出和诊断进程结束。
    func shutdown() {
        pathMonitor.cancel()
        routeCollector.shutdown(); directCollector.shutdown(); appCollector.shutdown()
    }

    /// 展开时重新采样排行，关闭时停止它并释放进程元数据。
    func setRankingVisible(_ visible: Bool) {
        guard rankingVisible != visible else { return }
        rankingVisible = visible
        applications = []; latestApplicationFrame = nil; rankingStatus = "正在采样…"
        if visible && !suspended {
            appCollector.start(mode: .applications, interval: preferences.interval)
        } else { appCollector.stop(); resolver.clear() }
        onUpdate?()
    }

    /// 屏幕关闭或系统休眠时停止所有采集；恢复时首帧重新建立基线，避免唤醒速度尖峰。
    func setSuspended(_ value: Bool) {
        guard value != suspended else { return }
        suspended = value
        restart()
    }

    /// 在设置或网络变化时重新建立采样，不把旧周期计数套用到新刷新间隔。
    func restart() {
        historySegment = UUID().uuidString
        download = nil; upload = nil; lastSampleTime = nil
        ordinarySpeeds = nil; ordinaryStatus = "正在采样…"
        directDownload = nil; directUpload = nil; directInterfaces = []
        directActivity.reset()
        applications = []; latestApplicationFrame = nil; activeInterfaces = []
        rankingStatus = "正在采样…"
        if suspended {
            status = "已暂停"
            routeCollector.stop(); directCollector.stop(); appCollector.stop()
        } else {
            status = "正在采样…"
            routeCollector.start(mode: .routes, interval: preferences.interval)
            directCollector.start(mode: .direct, interval: preferences.interval)
            if rankingVisible { appCollector.start(mode: .applications, interval: preferences.interval) }
        }
        directStatus = status
        onUpdate?()
    }

    /// 根据用户指定的下载、上传或合计速度排序；相同速度使用名称稳定排序以减少跳动。
    var sortedApplications: [AppTraffic] {
        applications.filter { $0.download + $0.upload > 0 }.sorted {
            let left = $0.value(for: preferences.order), right = $1.value(for: preferences.order)
            return left == right ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : left > right
        }
    }

    /// 显示实际统计接口，让 VPN 下的物理传输量与 App 连接流量口径可区分。
    var sourceDescription: String {
        let names = activeInterfaces.map { name in
            interfaces.first(where: { $0.name == name }).map { "\($0.title) (\(name))" } ?? name
        }
        let sources = names + (directActivity.isVisible ? ["设备直连"] : [])
        return sources.isEmpty ? "网络总量" : sources.joined(separator: " + ") + " · 网络总量"
    }

    /// 向悬停提示和诊断提供实际直连接口；该统计可能包含隔空投送之外的设备间通信。
    var directSourceDescription: String {
        let names = directInterfaces.joined(separator: " + ")
        return names.isEmpty ? "设备直连 · 连接流量" : "设备直连（\(names)）· 连接流量"
    }

    /// 读取硬件接口类型；不会把 utun、loopback 或桥接设备纳入自动总量。
    func refreshInterfaces() {
        let all = (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? []
        interfaces = all.compactMap { interface in
            guard let name = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let type = SCNetworkInterfaceGetInterfaceType(interface) as String?,
                  [kSCNetworkInterfaceTypeEthernet as String, kSCNetworkInterfaceTypeIEEE80211 as String,
                   kSCNetworkInterfaceTypeWWAN as String].contains(type),
                  !name.hasPrefix("bridge") else { return nil }
            let title = (SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?) ?? name
            return NetworkInterface(name: name, title: title)
        }.sorted { $0.name < $1.name }
    }

    /// 读取普通网络速率；即使原生模式回退为连接明细，也排除独立采集的直连和虚拟接口。
    private func receiveRoutes(_ frame: TrafficFrame) {
        guard !suspended else { return }
        let selected = preferences.interface
        // 普通接口和直连接口是两个互斥集合，直连始终覆盖，不受普通网卡选择影响。
        let allowed = Set(selected.isEmpty ? interfaces.map(\.name) : [selected]).subtracting(Self.directInterfaceNames)
        let result = Self.interfaceTotal(frame, allowed: allowed)
        activeInterfaces = result.interfaces
        ordinarySpeeds = (Double(result.bytes.received) / frame.duration, Double(result.bytes.sent) / frame.duration)
        ordinaryStatus = result.interfaces.isEmpty ? "所选网络未连接" : "实时"
        publishSpeeds()
        onSystemSample?(download, upload, Date(), historySegment, preferences.interval)
    }

    /// 按真实接口合计系统 AWDL 连接，包含 TCP、UDP、QUIC；健康空帧明确表示当前没有传输。
    private func receiveDirect(_ frame: TrafficFrame) {
        guard !suspended else { return }
        let wasUnavailable = directDownload == nil
        let direct = Self.interfaceTotal(frame, allowed: Self.directInterfaceNames)
        directInterfaces = direct.interfaces
        directDownload = Double(direct.bytes.received) / frame.duration
        directUpload = Double(direct.bytes.sent) / frame.duration
        directStatus = "实时"
        let now = ProcessInfo.processInfo.systemUptime
        directActivity.consume(download: directDownload, upload: directUpload, at: now, interval: preferences.interval)
        if wasUnavailable, let cached = latestApplicationFrame { receiveApplications(cached, notify: false) }
        // 缓存最新直连合计，由普通总量周期通知 UI，避免两个采集器每轮各触发一次总量刷新。
        publishSpeeds(notify: false)
    }

    /// 两路分别按实际帧间隔求速率后相加；都就绪才提供总量，普通周期或故障才通知 UI。
    private func publishSpeeds(notify: Bool = true) {
        if let ordinarySpeeds, let directDownload, let directUpload {
            download = ordinarySpeeds.download + directDownload
            upload = ordinarySpeeds.upload + directUpload
            status = activeInterfaces.isEmpty && !directActivity.isVisible ? "所选网络未连接" : "实时"
            if notify { lastSampleTime = ProcessInfo.processInfo.systemUptime }
        } else {
            download = nil; upload = nil; lastSampleTime = nil
            status = ordinarySpeeds == nil ? ordinaryStatus : directStatus
        }
        if notify { onUpdate?() }
    }

    /// 纯统计函数：排除子路由行、回环及未选中的虚拟接口，便于对重复统计边界做验证。
    static func routeTotal(_ rows: [String: ByteCount], allowed: Set<String>) -> (bytes: ByteCount, interfaces: [String]) {
        var total = ByteCount(), present = Set<String>()
        for (label, bytes) in rows {
            let parts = label.components(separatedBy: " -> ")
            guard parts.count >= 2, allowed.contains(parts[1]), parts[1] != "lo0" else { continue }
            total.add(bytes); present.insert(parts[1])
        }
        return (total, present.sorted())
    }

    /// 对两种采集格式提供一致的接口归属；兼容帧的进程汇总行永不参与总量相加。
    static func interfaceTotal(_ frame: TrafficFrame, allowed: Set<String>) -> (bytes: ByteCount, interfaces: [String]) {
        guard let interfaces = frame.interfaceTotals else { return routeTotal(frame.rows, allowed: allowed) }
        var bytes = ByteCount(), present: [String] = []
        for (name, count) in interfaces where allowed.contains(name) && name != "lo0" {
            bytes.add(count); present.append(name)
        }
        return (bytes, present.sorted())
    }

    /// 合并主进程和 helper；直连状态改变时可只重算缓存帧，由总量统一通知 UI，防止短暂双计。
    private func receiveApplications(_ frame: TrafficFrame, notify: Bool = true) {
        guard rankingVisible, !suspended else { return }
        latestApplicationFrame = frame
        var grouped: [String: AppTraffic] = [:]
        for (label, count) in frame.rows {
            let direct = directDownload == nil ? ByteCount() : (frame.directApplications[label] ?? ByteCount())
            // 直连通道健康时扣除独立条目；采集失败时保留原始应用流量，避免 sharingd 也消失。
            let bytes = ByteCount(received: count.received - min(count.received, direct.received),
                                  sent: count.sent - min(count.sent, direct.sent))
            guard bytes.received > 0 || bytes.sent > 0,
                  let dot = label.lastIndex(of: "."),
                  let pid = Int32(label[label.index(after: dot)...]) else { continue }
            let app = resolver.resolve(pid: pid, fallback: String(label[..<dot]))
            var traffic = grouped[app.key] ?? AppTraffic(key: app.key, name: app.name, bundlePath: app.bundle,
                                                       download: 0, upload: 0, processes: 0)
            traffic.download += Double(bytes.received) / frame.duration
            traffic.upload += Double(bytes.sent) / frame.duration
            traffic.processes += 1
            grouped[app.key] = traffic
        }
        applications = Array(grouped.values)
        rankingStatus = applications.isEmpty ? "当前没有活跃的对外连接" : "实时"
        if notify { onUpdate?() }
    }
}
