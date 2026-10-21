import Foundation

/// 主程序与管理员采集器共享的固定身份；连接两端都验证证书和可执行文件标识。
enum CPUServiceIdentity {
    /// launchd 服务名、辅助程序签名标识和安装文件名保持一致。
    static let label = "com.local.NetworkSpeedMonitor.CPUHelper"
    /// 已安装工具的唯一位置，由系统的特权工具安装服务管理。
    static let installedPath = "/Library/PrivilegedHelperTools/" + label
    /// 只接受本机既有固定签名，不使用任意同名程序。
    static let certificate = "659A2CD838DF7ADCB88F313BDE6572A223C4923C"
    /// 辅助服务只允许本工具请求只读统计。
    static let clientRequirement = "identifier \"com.local.NetworkSpeedMonitor\" and certificate root = H\"\(certificate)\""
    /// 主程序同样校验服务身份，拒绝其他程序伪装成采集器。
    static let helperRequirement = "identifier \"\(label)\" and certificate root = H\"\(certificate)\""
    /// 采样协议版本；不兼容时要求更新采集器，而非误读旧字段。
    static let protocolVersion = 1
}

/// 本地 XPC 只暴露一次全量只读快照，不接受命令、文件路径或修改系统状态的参数。
@objc(CPUServiceProtocol) protocol CPUServiceProtocol {
    /// 异步返回有版本号的 JSON 快照；错误通过独立字符串返回，不伪造零占用。
    func readSnapshot(withReply reply: @escaping (Data?, String?) -> Void)
}

/// 单个进程的累计 CPU 时间，进程启动时间用于识别 PID 重用。
struct CPUProcessCounter: Codable {
    /// 系统进程标识，包含内核进程 PID 0。
    let pid: Int32
    /// 进程创建时刻，单位为 Unix 微秒。
    let started: UInt64
    /// 用户态与内核态累计 CPU 时间，单位为 Mach absolute ticks。
    let ticks: UInt64
    /// 内核提供的显示名称，不依赖主程序能否读取受限进程元数据。
    let name: String
    /// 可执行文件路径，无法读取时为空并保留独立进程归属。
    let path: String
    /// PID 与创建时刻联合构成稳定采样身份。
    var identity: String { "\(pid):\(started)" }
}

/// 一轮进程统计的完整结果，包含权限覆盖范围和换算所需的系统信息。
struct CPUProcessSnapshot: Codable {
    /// 用于检测安装后新旧辅助程序是否兼容。
    let version: Int
    /// 快照时间使用单调时钟，不受系统日期调整影响。
    let uptime: TimeInterval
    /// 整机逻辑核心数，所有排行统一除以此值。
    let cores: Int
    /// Mach tick 到秒的转换因子，避免 Apple Silicon 上出现时间单位误差。
    let secondsPerTick: Double
    /// 服务实际有效用户是否为 root，主程序据此报告权限状态。
    let privileged: Bool
    /// 因权限或保护策略无法读取的进程数。
    let denied: Int
    /// 采样中已退出或暂时不可读的进程数。
    let skipped: Int
    /// 成功获取 CPU 计数的进程集合，包含本周期没有 CPU 活动的进程。
    let processes: [CPUProcessCounter]
    /// 新版服务在同一次 PID 枚举中读取磁盘计数；可选字段保证旧服务的 CPU 快照仍能解码。
    var diskProcesses: [DiskProcessCounter]? = nil
    /// 磁盘接口独立统计权限失败；不能使用 CPU 接口的覆盖数量代替。
    var diskDenied: Int? = nil
    /// 磁盘采样期间退出或暂时不可读的进程数，和权限失败分别记录。
    var diskSkipped: Int? = nil
    /// 新版服务在同一次 rusage 查询中返回进程物理占用；可选字段使旧服务继续提供 CPU 和磁盘数据。
    var memoryProcesses: [MemoryProcessCounter]? = nil
    /// 内存接口因权限或系统保护未能读取的进程数，不能用 CPU 接口覆盖数代替。
    var memoryDenied: Int? = nil
    /// 内存采样期间退出或暂时不可读的进程数，与权限失败分别展示。
    var memorySkipped: Int? = nil
}

/// 内核归属到单个进程的当前物理内存占用；使用 footprint 避免把共享页和虚拟地址空间直接相加。
struct MemoryProcessCounter: Codable {
    /// 本轮进程标识；与启动时刻联合用于区分 PID 重用。
    let pid: Int32
    /// rusage 同一次查询返回的启动时刻，单位为 Mach absolute ticks。
    let started: UInt64
    /// 内核统计的物理 footprint 字节数，适合按应用合并展示当前占用。
    let footprintBytes: UInt64
    /// 可读进程名，路径缺失时仍保留独立系统进程。
    let name: String
    /// 用于复用主应用的最外层 App 归属规则。
    let path: String
    /// 防止退出进程的 PID 被新进程重用后错误保留旧身份。
    var identity: String { "\(pid):\(started)" }
}

/// 内核归属到单个进程的累计磁盘 I/O，包含该进程在所有存储设备上的读写。
struct DiskProcessCounter: Codable {
    /// 本轮进程标识；差分时必须同时比较启动时刻。
    let pid: Int32
    /// rusage 同一次查询返回的启动时刻，单位为 Mach absolute ticks。
    let started: UInt64
    /// 内核累计归属的磁盘读取字节数，不能把累计首帧显示成实时速度。
    let readBytes: UInt64
    /// 内核累计归属的磁盘写入字节数，不等同于应用文件大小或文件写入调用次数。
    let writtenBytes: UInt64
    /// 可读进程名，路径缺失时仍保留独立系统进程。
    let name: String
    /// 用于复用主应用的最外层 App 归属规则。
    let path: String
    /// 防止退出进程的 PID 被新进程重用后串接累计读写。
    var identity: String { "\(pid):\(started)" }
}

/// 一个可靠差分窗口内的进程读写速度；均以字节每秒表示。
struct DiskProcessUsage {
    /// 最新样本的进程身份及应用归属元数据。
    let process: DiskProcessCounter
    /// 实际采样间隔中的平均磁盘读取速度。
    let read: Double
    /// 实际采样间隔中的平均磁盘写入速度。
    let write: Double
}

/// 对磁盘累计计数做独立差分；旧服务、权限变化、暂停和计数回退均不能产生虚假速度。
final class DiskUsageAccumulator {
    /// 只保留相邻的一轮快照，关闭详情后释放。
    private var previous: CPUProcessSnapshot?

    /// 关闭、采集失败或修改间隔后重新建立基线。
    func reset() { previous = nil }

    /// 首轮返回 nil；新进程及回退计数跳过，合法的零增量保留为零速度。
    func consume(_ snapshot: CPUProcessSnapshot) -> [DiskProcessUsage]? {
        let old = previous
        previous = snapshot
        guard let processes = snapshot.diskProcesses, let old, let oldProcesses = old.diskProcesses,
              snapshot.privileged == old.privileged else { return nil }
        let duration = snapshot.uptime - old.uptime
        guard duration.isFinite, duration >= 0.1, duration <= 30 else { return nil }
        let counters = Dictionary(oldProcesses.map { ($0.identity, $0) }, uniquingKeysWith: { _, new in new })
        return processes.compactMap { process in
            guard let before = counters[process.identity], process.readBytes >= before.readBytes,
                  process.writtenBytes >= before.writtenBytes else { return nil }
            return DiskProcessUsage(process: process,
                read: Double(process.readBytes - before.readBytes) / duration,
                write: Double(process.writtenBytes - before.writtenBytes) / duration)
        }
    }
}

/// 两次采样间的进程整机占比；保留对应身份信息供应用归类。
struct CPUProcessUsage {
    /// 最新一轮的进程身份与元数据。
    let process: CPUProcessCounter
    /// 占整机 CPU 的百分比，范围为 0 到 100。
    let percent: Double
}

/// 差分计算器独立于采集权限；首次、长时间暂停及 PID 重用均重新建立基线。
final class CPUUsageAccumulator {
    /// 前一轮快照仅保存在内存里，关闭详情即释放。
    private var previous: CPUProcessSnapshot?

    /// 丢弃旧累计值，防止跨休眠、权限变化或刷新间隔变化出现尖峰。
    func reset() { previous = nil }

    /// 用真实采样时长和逻辑核心数计算整机占比，忽略新建进程的累计首帧。
    func consume(_ snapshot: CPUProcessSnapshot) -> [CPUProcessUsage]? {
        let old = previous
        previous = snapshot
        guard let old, snapshot.cores == old.cores, snapshot.privileged == old.privileged else { return nil }
        let duration = snapshot.uptime - old.uptime
        guard duration >= 0.1, duration <= 30, snapshot.cores > 0,
              snapshot.secondsPerTick > 0, snapshot.secondsPerTick.isFinite else { return nil }
        let counters = Dictionary(old.processes.map { ($0.identity, $0.ticks) }, uniquingKeysWith: { _, new in new })
        return snapshot.processes.compactMap { process in
            guard let before = counters[process.identity], process.ticks >= before else { return nil }
            let percent = Double(process.ticks - before) * snapshot.secondsPerTick / duration / Double(snapshot.cores) * 100
            guard percent.isFinite else { return nil }
            return CPUProcessUsage(process: process, percent: min(100, max(0, percent)))
        }
    }
}
