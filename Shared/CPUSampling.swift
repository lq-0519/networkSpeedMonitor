import Foundation
import Darwin

/// 读取系统已维护的计数器；无抓取线程、无历史日志、无外部命令。
final class CPUProcessReader {
    /// 以 PID 和启动时间缓存可执行路径，只为新进程查询路径。
    private var paths: [String: String] = [:]
    /// 本机 absolute tick 的换算因子，仅初始化一次。
    private let secondsPerTick: Double

    /// 从内核读取时间基准，不硬编码 Intel 或 Apple Silicon 时钟频率。
    init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        secondsPerTick = Double(info.numer) / Double(info.denom) / 1_000_000_000
    }

    /// 单次枚举 PID 后读取 CPU 及共享的 rusage 计数；磁盘和内存复用同一查询，不增加系统调用。
    func snapshot() -> CPUProcessSnapshot {
        let capacity = min(131_072, max(1024, Int(proc_listallpids(nil, 0)) + 256))
        var pids = [Int32](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes { Int(proc_listallpids($0.baseAddress, Int32($0.count))) }
        var processes: [CPUProcessCounter] = [], nextPaths: [String: String] = [:]
        var denied = 0, skipped = 0, diskDenied = 0, diskSkipped = 0
        var memoryDenied = 0, memorySkipped = 0
        var diskProcesses: [DiskProcessCounter] = []
        var memoryProcesses: [MemoryProcessCounter] = []
        for pid in pids.prefix(max(0, min(count, capacity))) {
            var info = proc_taskallinfo()
            let size = Int32(MemoryLayout<proc_taskallinfo>.size)
            let received = proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info, size)
            let cpuReadable = received == size
            if !cpuReadable {
                if errno == EPERM || errno == EACCES { denied += 1 } else { skipped += 1 }
            }
            var usage = rusage_info_v2()
            let rusageReadable = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) == 0 }
            }
            if !rusageReadable {
                if errno == EPERM || errno == EACCES {
                    diskDenied += 1
                    memoryDenied += 1
                } else {
                    diskSkipped += 1
                    memorySkipped += 1
                }
            }
            guard cpuReadable || rusageReadable else { continue }
            let start = info.pbsd.pbi_start_tvsec * 1_000_000 + info.pbsd.pbi_start_tvusec
            let identity = rusageReadable ? "rusage:\(pid):\(usage.ri_proc_start_abstime)" : "cpu:\(pid):\(start)"
            let name: String
            if cpuReadable {
                name = withUnsafePointer(to: &info.pbsd.pbi_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: 32) { String(cString: $0) }
                }
            } else {
                var buffer = [CChar](repeating: 0, count: 1024)
                name = proc_name(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : ""
            }
            let path: String
            if let cached = paths[identity] { path = cached }
            else {
                var buffer = [CChar](repeating: 0, count: 4096)
                path = proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : ""
            }
            nextPaths[identity] = path
            let title = name.isEmpty ? (pid == 0 ? "kernel_task" : "进程 \(pid)") : name
            if cpuReadable {
                processes.append(CPUProcessCounter(pid: pid, started: start,
                    ticks: info.ptinfo.pti_total_user &+ info.ptinfo.pti_total_system, name: title, path: path))
            }
            if rusageReadable {
                diskProcesses.append(DiskProcessCounter(pid: pid, started: usage.ri_proc_start_abstime,
                    readBytes: usage.ri_diskio_bytesread, writtenBytes: usage.ri_diskio_byteswritten, name: title, path: path))
                memoryProcesses.append(MemoryProcessCounter(pid: pid, started: usage.ri_proc_start_abstime,
                    footprintBytes: usage.ri_phys_footprint, name: title, path: path))
            }
        }
        paths = nextPaths
        return CPUProcessSnapshot(version: CPUServiceIdentity.protocolVersion,
            uptime: ProcessInfo.processInfo.systemUptime, cores: ProcessInfo.processInfo.activeProcessorCount,
            secondsPerTick: secondsPerTick, privileged: geteuid() == 0,
            denied: denied, skipped: skipped, processes: processes,
            diskProcesses: diskProcesses, diskDenied: diskDenied, diskSkipped: diskSkipped,
            memoryProcesses: memoryProcesses, memoryDenied: memoryDenied, memorySkipped: memorySkipped)
    }

    /// 关闭详情时回收进程元数据，不在常驻状态保存完整进程表。
    func reset() { paths.removeAll() }
}

/// 整机 CPU 的本周期占比，用户态与系统态均已按全部核心归一化。
struct CPUSystemUsage {
    /// 全部非空闲 CPU 时间占比。
    let total: Double
    /// 用户态 CPU 时间占比，包含 nice 状态。
    let user: Double
    /// 系统态 CPU 时间占比。
    let system: Double
}

/// 只读取四个整机计数；菜单栏关闭详情后仍可极低成本更新。
final class CPUSystemReader {
    /// 固定持有一个 host send right，避免每次刷新重复分配 Mach 端口。
    private let host = mach_host_self()
    /// 前一次四种 CPU 状态计数，首次采样仅建立基线。
    private var previous: [UInt32]?

    /// 释放唯一持有的 Mach 端口引用。
    deinit { mach_port_deallocate(mach_task_self_, host) }

    /// 暂停或刷新间隔变化后重新建立统计窗口。
    func reset() { previous = nil }

    /// 读取系统计数并差分；无效或首次样本返回 nil，不能伪装为 0%。
    func sample() -> CPUSystemUsage? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { previous = nil; return nil }
        let values = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
        let old = previous; previous = values
        guard let old else { return nil }
        let delta = zip(values, old).map { Double($0 &- $1) }
        let all = delta.reduce(0, +)
        guard all > 0 else { return nil }
        return CPUSystemUsage(total: (all - delta[2]) / all * 100,
                              user: (delta[0] + delta[3]) / all * 100, system: delta[1] / all * 100)
    }
}
