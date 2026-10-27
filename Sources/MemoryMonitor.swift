import AppKit
import Darwin

/// macOS 内存压力的公开等级；未知值单独保留，不能误报为正常。
enum MemoryPressureLevel: Int, Codable {
    /// 系统接口不可用或返回未来版本的新值。
    case unknown = 0
    /// 当前可用内存和回收能力充足。
    case normal = 1
    /// 系统正在更积极地压缩或回收内存。
    case warning = 2
    /// 内存资源紧张，应用可能明显受到影响。
    case critical = 4

    /// 面板和诊断共用的简短中文状态。
    var title: String {
        switch self {
        case .normal: return "正常"
        case .warning: return "警告"
        case .critical: return "严重"
        case .unknown: return "—"
        }
    }
}

/// 整机当前内存摘要；已用值与进程 footprint 排行属于不同统计层，不能互相求和校验。
struct MemorySystemUsage: Codable {
    /// 机器安装的物理内存总量，单位为字节。
    let totalBytes: UInt64
    /// 基于 Mach VM 页计数计算的当前已用内存，单位为字节。
    let usedBytes: UInt64
    /// 内核提供的当前内存压力等级。
    let pressure: MemoryPressureLevel
}

/// Mach VM 页统计的最小输入集合；独立计算函数便于验证溢出、回收页和容量边界。
struct MemoryPageCounts {
    /// 最近使用或当前驻留的活跃页。
    let active: UInt64
    /// 当前不活跃但仍驻留的页。
    let inactive: UInt64
    /// 内核尚未确认归类的推测页。
    let speculative: UInt64
    /// 不能换出的有线页。
    let wired: UInt64
    /// 压缩器当前持有的页数。
    let compressed: UInt64
    /// 内核标记为可清理的页数。
    let purgeable: UInt64
    /// 文件映射等外部页数，用于避免将可回收缓存全部计入已用。
    let external: UInt64

    /// 按约定口径计算已用字节，并将异常页计数严格限制在零到物理总量之间。
    func usedBytes(totalBytes: UInt64, pageSize: UInt64) -> UInt64 {
        guard totalBytes > 0, pageSize > 0 else { return 0 }
        let resident = Self.sum([active, inactive, speculative, wired, compressed])
        let reclaimable = Self.sum([purgeable, external])
        let usedPages = resident > reclaimable ? resident - reclaimable : 0
        let multiplied = usedPages.multipliedReportingOverflow(by: pageSize)
        return min(totalBytes, multiplied.overflow ? UInt64.max : multiplied.partialValue)
    }

    /// 对内核累计页数做饱和求和，损坏或未来扩展值不能发生无符号回绕。
    private static func sum(_ values: [UInt64]) -> UInt64 {
        values.reduce(0) { result, value in
            let next = result.addingReportingOverflow(value)
            return next.overflow ? UInt64.max : next.partialValue
        }
    }
}

/// 只读取 Mach VM 统计和当前压力，不启动进程、定时器或管理员服务。
final class MemorySystemReader {
    /// 固定持有一个 host send right，避免每次刷新重复创建 Mach 端口。
    private let host = mach_host_self()

    /// 释放唯一持有的 Mach 端口引用。
    deinit { mach_port_deallocate(mach_task_self_, host) }

    /// 读取当前整机内存；任一核心容量数据失败时返回 nil，不能把失败显示成零使用。
    func sample() -> MemorySystemUsage? {
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &statistics) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        var pageSize: vm_size_t = 0
        guard result == KERN_SUCCESS, host_page_size(host, &pageSize) == KERN_SUCCESS,
              pageSize > 0, ProcessInfo.processInfo.physicalMemory > 0 else { return nil }
        let pages = MemoryPageCounts(
            active: UInt64(statistics.active_count),
            inactive: UInt64(statistics.inactive_count),
            speculative: UInt64(statistics.speculative_count),
            wired: UInt64(statistics.wire_count),
            compressed: UInt64(statistics.compressor_page_count),
            purgeable: UInt64(statistics.purgeable_count),
            external: UInt64(statistics.external_page_count)
        )
        let total = ProcessInfo.processInfo.physicalMemory
        return MemorySystemUsage(totalBytes: total,
            usedBytes: pages.usedBytes(totalBytes: total, pageSize: UInt64(pageSize)),
            pressure: Self.readPressure())
    }

    /// 从内核读取离散压力等级；未知值保持 unknown，避免未来系统值被误判为健康。
    private static func readPressure() -> MemoryPressureLevel {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0 else {
            return .unknown
        }
        return MemoryPressureLevel(rawValue: Int(value)) ?? .unknown
    }
}

/// 已合并到最外层 App 的当前物理内存，子进程明细来自同一瞬时快照。
struct MemoryApplicationUsage {
    /// App 路径或无法确定归属时的稳定系统进程键。
    let key: String
    /// 应用本地化名称或系统进程名。
    let name: String
    /// 只用于按需读取图标，无法确定时保持 nil。
    let bundlePath: String?
    /// 所有可归属进程 footprint 的饱和合计字节数。
    var footprintBytes: UInt64
    /// 聚合所包含的完整进程数，不受子进程明细截取影响。
    var processCount: Int
    /// 当前 footprint 最大的最多十个进程，供面板展开查看 PID。
    var processes: [MemoryProcessCounter]
}

/// 内存字节的紧凑文本格式；使用 1024 进制换算，使物理容量与 macOS 和硬件标称保持一致。
enum MemoryText {
    /// 根据二进制量级选择 B、KB、MB 或 GB；界面沿用用户熟悉的单位文字，不把 48 GB 显示成 51.5 GB。
    static func string(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        let kibibyte = 1024.0
        let mebibyte = kibibyte * 1024
        let gibibyte = mebibyte * 1024
        if value < kibibyte { return "\(bytes) B" }
        if value < mebibyte { return String(format: "%.0f KB", value / kibibyte) }
        if value < gibibyte { return String(format: "%.1f MB", value / mebibyte) }
        return String(format: "%.1f GB", value / gibibyte)
    }
}

/// 弹窗专用内存模型；整机摘要和应用排行都随 CPU 的既有采样周期更新，不新增计时器。
final class MemoryMonitor {
    /// 所有状态均在主线程更新，通知只触发内存区域刷新。
    var onUpdate: (() -> Void)?
    /// 最近一次有效的整机内存摘要。
    private(set) var systemUsage: MemorySystemUsage?
    /// 已按 App 完整合并并排序的有界排行。
    private(set) var applications: [MemoryApplicationUsage] = []
    /// 实际快照是否来自管理员身份；普通身份仍展示当前用户可读的部分排行。
    private(set) var privileged = false
    /// 本轮内存接口成功读取的进程数量。
    private(set) var readableProcesses = 0
    /// 本轮因权限或系统保护未读取的进程数量。
    private(set) var deniedProcesses = 0
    /// 本轮采样期间退出或暂时不可读取的进程数量。
    private(set) var skippedProcesses = 0
    /// 内存字段是否由当前主程序或已安装辅助服务提供。
    private(set) var supported = false
    /// 实时、部分覆盖、旧服务和真实采集错误的短状态。
    private(set) var rankingStatus = "正在采样…"
    /// 共享连接的采集状态；只有实际快照缺少内存字段时才要求更新服务。
    private(set) var collectionStatus: ProcessCollectionStatus = .sampling
    /// 等待或重试时保留的 footprint 是否已过期，不能与当前整机摘要混为实时数据。
    private(set) var isRankingStale = false
    /// 最近成功接收进程快照的单调时刻。
    private(set) var sampleTime: TimeInterval?
    /// 仅在排行内容或状态变化时递增，供 outline 避免无关重建。
    private(set) var rankingRevision = 0
    /// 关闭后拒绝 CPU 已经排队的旧回调。
    private var visible = false
    /// 整机摘要读取器不保留历史计数或定时任务。
    private let systemReader = MemorySystemReader()
    /// GUI 由趋势采集器提供整机标量；独立诊断沿用原有直接读取行为。
    private let systemManagedExternally: Bool
    /// 仅在详情可见时以低优先级执行归类和排序，避免阻塞主线程或持续抢占前台 CPU。
    private let rankingQueue = DispatchQueue(label: "com.local.NetworkSpeedMonitor.memory.ranking", qos: .utility)
    /// 主线程更新的发布世代，关闭、重开或更新采集状态后拒绝旧的后台计算结果。
    private var processingEpoch = UUID()
    /// 复用 CPU 和磁盘相同的最外层 App 归属规则，缓存只在 rankingQueue 访问。
    private let resolver = ApplicationResolver()

    /// 仅 GUI 开启共享整机采集，默认参数保持既有诊断调用兼容。
    init(systemManagedExternally: Bool = false) { self.systemManagedExternally = systemManagedExternally }

    /// 接收后台轻量整机读数，不带动进程枚举，隐藏时仅保留一个最新标量。
    func receiveSystem(_ usage: MemorySystemUsage?) {
        systemUsage = usage
        if visible { onUpdate?() }
    }

    /// 展开时立即读取整机摘要；收起时释放排行、路径归属和旧数值。
    func setVisible(_ value: Bool) {
        guard value != visible else { return }
        visible = value
        if value {
            if !systemManagedExternally { systemUsage = systemReader.sample() }
            clearRanking(.sampling)
        } else {
            if !systemManagedExternally { systemUsage = nil }
            clearRanking(.paused)
        }
        onUpdate?()
    }

    /// 接收 CPU 同轮的进程 rusage；普通权限展示部分结果，旧管理员服务明确要求更新。
    func receive(_ snapshot: CPUProcessSnapshot?, status: ProcessCollectionStatus) {
        guard visible else { return }
        let epoch = UUID(); processingEpoch = epoch
        if !systemManagedExternally { systemUsage = systemReader.sample() }
        guard let snapshot else {
            if status.preservesResult {
                collectionStatus = status
                isRankingStale = !applications.isEmpty
                rankingStatus = isRankingStale ? "最近结果已过期。\(status.message)" : status.message
                rankingRevision += 1
            } else {
                clearRanking(status)
            }
            onUpdate?()
            return
        }
        guard let processes = snapshot.memoryProcesses else {
            rankingQueue.async { [self] in resolver.clear() }
            publish(snapshot, applications: [], epoch: epoch)
            return
        }
        rankingQueue.async { [weak self] in
            guard let self else { return }
            let groups = self.groupedApplications(processes)
            DispatchQueue.main.async { [weak self] in
                self?.publish(snapshot, applications: groups, epoch: epoch)
            }
        }
    }

    /// 后台结果只在对应详情及采集世代仍有效时提交，覆盖信息和排行在同一轮主线程更新中生效。
    private func publish(_ snapshot: CPUProcessSnapshot, applications groups: [MemoryApplicationUsage], epoch: UUID) {
        guard visible, processingEpoch == epoch else { return }
        collectionStatus = .live
        isRankingStale = false
        privileged = snapshot.privileged
        supported = snapshot.memoryProcesses != nil
        readableProcesses = snapshot.memoryProcesses?.count ?? 0
        deniedProcesses = snapshot.memoryDenied ?? 0
        skippedProcesses = snapshot.memorySkipped ?? 0
        sampleTime = snapshot.uptime
        applications = groups
        if snapshot.memoryProcesses == nil {
            collectionStatus = .updateRequired
            rankingStatus = collectionStatus.message
        } else {
            rankingStatus = snapshot.memoryProcesses?.isEmpty == true ? "当前没有可读取的进程" : privileged ? "实时" : "部分进程"
        }
        rankingRevision += 1
        onUpdate?()
    }

    /// 在独立串行队列中完整合并 footprint，再保留有界应用和子进程明细。
    private func groupedApplications(_ processes: [MemoryProcessCounter]) -> [MemoryApplicationUsage] {
        var grouped: [String: MemoryApplicationUsage] = [:]
        for process in processes {
            let app = resolver.resolve(path: process.path, pid: process.pid, fallback: process.name)
            var item = grouped[app.key] ?? MemoryApplicationUsage(key: app.key, name: app.name,
                bundlePath: app.bundle, footprintBytes: 0, processCount: 0, processes: [])
            let total = item.footprintBytes.addingReportingOverflow(process.footprintBytes)
            item.footprintBytes = total.overflow ? UInt64.max : total.partialValue
            item.processCount += 1
            item.processes.append(process)
            grouped[app.key] = item
        }
        let top = grouped.values.sorted {
            $0.footprintBytes == $1.footprintBytes
                ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                : $0.footprintBytes > $1.footprintBytes
        }.prefix(RankingPreferences.maximumCount)
        return top.map { item in
            var result = item
            result.processes = Array(item.processes.sorted {
                $0.footprintBytes == $1.footprintBytes ? $0.pid < $1.pid : $0.footprintBytes > $1.footprintBytes
            }.prefix(10))
            return result
        }
    }

    /// 关闭、确定的校验失败或详情重配时清空排行；暂时延迟通过 receive 保留最近结果。
    private func clearRanking(_ status: ProcessCollectionStatus) {
        processingEpoch = UUID()
        rankingQueue.async { [self] in resolver.clear() }
        applications = []
        privileged = false
        supported = false
        readableProcesses = 0
        deniedProcesses = 0
        skippedProcesses = 0
        sampleTime = nil
        collectionStatus = status
        isRankingStale = false
        rankingStatus = status.message
        rankingRevision += 1
    }
}
