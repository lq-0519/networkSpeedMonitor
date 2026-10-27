import AppKit

/// 系统盘所在文件系统的容量，APFS 同容器的共享空间只读取一次。
struct DiskCapacity: Codable {
    /// 文件系统报告的实际容量，包含容器共享空间，不是 SSD 商品标称容量。
    let total: Int64
    /// 未计入可清理缓存的当前空闲字节数。
    let free: Int64
    /// 已占用空间按总容量减空闲空间计算，包含系统和快照占用。
    var used: Int64 { total - free }
    /// 用于容量条的百分比，不受十进制展示精度影响。
    var usedPercent: Double { Double(used) / Double(total) * 100 }

    /// 每次创建新的 URL，避免 URL resourceValues 的缓存让容量一直停留在首次读取值。
    static func read() -> DiskCapacity? {
        let url = URL(fileURLWithPath: "/", isDirectory: true)
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
              let total = values.volumeTotalCapacity, let free = values.volumeAvailableCapacity,
              total > 0, free >= 0, free <= total else { return nil }
        return DiskCapacity(total: Int64(total), free: Int64(free))
    }

    /// 容量使用十进制 GB，与当前速度单位及 macOS 磁盘容量习惯一致。
    static func text(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(bytes) / 1_000_000_000) }
}

/// 磁盘排行持久化的三个排序方向，和网络排序分别保存。
enum DiskRankingOrder: Int {
    /// 默认按读写速度合计查找当前最活跃的应用。
    case combined = 0
    /// 优先查看读取较多的应用。
    case read = 1
    /// 优先查看写入较多的应用。
    case write = 2
}

/// 已合并最外层 App 的磁盘速度，汇总所有成功差分的进程后才截取排行榜。
struct DiskApplicationUsage {
    /// App 路径或无法确定应用归属的系统进程键。
    let key: String
    /// 应用本地化名称或系统进程名。
    let name: String
    /// 只用于按需读取图标，无法确定时保持 nil。
    let bundlePath: String?
    /// 本采样窗口中所有可归属进程的读取字节每秒。
    var read: Double
    /// 本采样窗口中所有可归属进程的写入字节每秒。
    var write: Double
    /// 参与差分的完整进程数，包含本周期零读写的辅助进程。
    var processes: Int

    /// 根据独立的磁盘排序方向选取排序值。
    func value(for order: DiskRankingOrder) -> Double {
        switch order {
        case .combined: return read + write
        case .read: return read
        case .write: return write
        }
    }
}

/// 弹窗专用磁盘模型；复用 CPU 的进程快照和计时器，不新增常驻采集进程或管理员服务。
final class DiskMonitor {
    /// 所有状态均在主线程更新，通知只触发磁盘区域刷新。
    var onUpdate: (() -> Void)?
    /// 当前系统盘容量，接口不可用时保持 nil，不能把失败显示成空盘。
    private(set) var capacity: DiskCapacity?
    /// 已按 App 归属合并的完整结果，只在弹窗展开期间保留。
    private(set) var applications: [DiskApplicationUsage] = []
    /// 实际采集快照的 root 身份，不能仅凭安装文件存在声称完整权限。
    private(set) var privileged = false
    /// 本轮磁盘接口成功读取的进程数量。
    private(set) var readableProcesses = 0
    /// 本轮磁盘接口因权限失败的进程数，管理员下仍可能受到系统保护。
    private(set) var deniedProcesses = 0
    /// 采样中已退出或暂时不可读取的进程数量。
    private(set) var skippedProcesses = 0
    /// 磁盘字段是否由实际服务提供，旧版服务明确要求升级。
    private(set) var supported = false
    /// 首次基线、权限不足和真实采集错误的短状态。
    private(set) var rankingStatus = "正在采样…"
    /// 共享连接的采集状态；暂时延迟不会覆盖已验证的权限或协议能力。
    private(set) var collectionStatus: ProcessCollectionStatus = .sampling
    /// 当前展示的读写速度是否属于延迟或重新建立基线前的过期结果。
    private(set) var isRankingStale = false
    /// 最新成功快照的单调时刻，诊断用于确认数据新鲜度。
    private(set) var sampleTime: TimeInterval?
    /// 关闭后拒绝 CPU 已经排队的旧回调。
    private var visible = false
    /// 按需差分和 App 元数据读取在低优先级队列串行执行，不阻塞界面或持续抢占前台 CPU。
    private let rankingQueue = DispatchQueue(label: "com.local.NetworkSpeedMonitor.disk.ranking", qos: .utility)
    /// 主线程上的结果世代；状态变化和关闭后拒绝已经排队的旧排行。
    private var processingEpoch = UUID()
    /// 磁盘和 CPU 采用各自的差分器，仅由 rankingQueue 访问，互不改变统计窗口。
    private let accumulator = DiskUsageAccumulator()
    /// 复用现有 App 合并规则，缓存仅在详情可见期间保留，并且只在 rankingQueue 访问。
    private let resolver = ApplicationResolver()
    /// GUI 容量由共享轻量采集器读取；诊断默认继续自行读取。
    private let systemManagedExternally: Bool

    /// 启用共享整机容量时避免每次进程快照重复查询文件系统。
    init(systemManagedExternally: Bool = false) { self.systemManagedExternally = systemManagedExternally }

    /// 最新容量与历史复用同一次读取，不要求进程采集成功或管理员授权。
    func receiveSystem(_ value: DiskCapacity?) {
        capacity = value
        if visible { onUpdate?() }
    }

    /// 修改排序只重新排序当前快照，不改变采样或基线。
    var order: DiskRankingOrder {
        get { DiskRankingOrder(rawValue: UserDefaults.standard.integer(forKey: "diskRankingOrder")) ?? .combined }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "diskRankingOrder"); onUpdate?() }
    }

    /// 排除当前无活动的应用并稳定排序；读写列始终分别显示。
    var sortedApplications: [DiskApplicationUsage] {
        let selected = order
        return applications.filter { $0.read + $0.write > 0 }.sorted {
            let left = $0.value(for: selected), right = $1.value(for: selected)
            return left == right ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : left > right
        }
    }

    /// 展开立即读取容量；收起同时清空进程数据、图标归属和差分基线。
    func setVisible(_ value: Bool) {
        guard value != visible else { return }
        visible = value
        clear(value ? .sampling : .paused)
        if !systemManagedExternally { capacity = value ? DiskCapacity.read() : nil }
        onUpdate?()
    }

    /// 接收同一轮管理员 CPU/磁盘快照；不显示普通权限的局部磁盘排行冒充完整覆盖。
    func receive(_ snapshot: CPUProcessSnapshot?, status: ProcessCollectionStatus) {
        guard visible else { return }
        let epoch = UUID(); processingEpoch = epoch
        if !systemManagedExternally { capacity = DiskCapacity.read() }
        guard let snapshot else {
            if status.preservesResult {
                collectionStatus = status
                isRankingStale = !applications.isEmpty
                rankingStatus = isRankingStale ? "最近结果已过期。\(status.message)" : status.message
            } else {
                clear(status)
            }
            onUpdate?()
            return
        }
        rankingQueue.async { [weak self] in
            guard let self else { return }
            let groups: [DiskApplicationUsage]?
            if snapshot.privileged && snapshot.diskProcesses != nil {
                groups = self.accumulator.consume(snapshot).map { self.groupedApplications($0) }
            } else {
                self.accumulator.reset(); self.resolver.clear()
                groups = nil
            }
            DispatchQueue.main.async { [weak self] in
                self?.publish(snapshot, applications: groups, epoch: epoch)
            }
        }
    }

    /// 同时提交采样时间、覆盖信息和排行；过期任务不能覆盖更新后的状态或重新打开的面板。
    private func publish(_ snapshot: CPUProcessSnapshot, applications groups: [DiskApplicationUsage]?, epoch: UUID) {
        guard visible, processingEpoch == epoch else { return }
        collectionStatus = .live
        privileged = snapshot.privileged
        supported = snapshot.diskProcesses != nil
        readableProcesses = snapshot.diskProcesses?.count ?? 0
        deniedProcesses = snapshot.diskDenied ?? 0
        skippedProcesses = snapshot.diskSkipped ?? 0
        sampleTime = snapshot.uptime
        guard privileged else { reject(.authorizationRequired); return }
        guard supported else { reject(.updateRequired); return }
        guard let groups else {
            isRankingStale = !applications.isEmpty
            rankingStatus = isRankingStale ? "最近结果已过期，正在重新采样。" : "正在采样…"
            onUpdate?()
            return
        }
        applications = groups
        isRankingStale = false
        rankingStatus = applications.contains { $0.read + $0.write > 0 } ? "实时" : "当前没有活跃的磁盘读写"
        onUpdate?()
    }

    /// 后台完整聚合读写速度，主线程仍按用户设置对最终应用排行排序。
    private func groupedApplications(_ values: [DiskProcessUsage]) -> [DiskApplicationUsage] {
        var grouped: [String: DiskApplicationUsage] = [:]
        for value in values {
            let process = value.process
            let app = resolver.resolve(path: process.path, pid: process.pid, fallback: process.name)
            var item = grouped[app.key] ?? DiskApplicationUsage(key: app.key, name: app.name,
                bundlePath: app.bundle, read: 0, write: 0, processes: 0)
            item.read += value.read; item.write += value.write; item.processes += 1
            grouped[app.key] = item
        }
        return Array(grouped.values)
    }

    /// 权限或旧协议不能继续显示上次成功的冻结数值，但保留本轮实际覆盖信息。
    private func reject(_ status: ProcessCollectionStatus) {
        applications = []
        collectionStatus = status; isRankingStale = false
        rankingStatus = status.message; onUpdate?()
    }

    /// 关闭、确定的校验失败或重配时释放排行；暂时超时不会清除数据与差分基线。
    private func clear(_ status: ProcessCollectionStatus) {
        processingEpoch = UUID()
        rankingQueue.async { [self] in accumulator.reset(); resolver.clear() }
        applications = []
        privileged = false; supported = false; readableProcesses = 0
        deniedProcesses = 0; skippedProcesses = 0; sampleTime = nil
        collectionStatus = status; isRankingStale = false; rankingStatus = status.message
    }
}
