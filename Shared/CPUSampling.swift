import Foundation
import Darwin

/// 读取系统已维护的计数器；无抓取线程、无历史日志、无外部命令。
final class CPUProcessReader {
    /// 以 PID 缓存元数据，并同时验证启动时刻和可执行映像，避免 PID 重用或 exec 后错误归属。
    private var metadata: [Int32: ProcessMetadata] = [:]
    /// 本机 absolute tick 的换算因子；rusage 与 task 回退均使用同一时间单位。
    private let secondsPerTick: Double

    /// 不随每轮占用变化的进程元数据；映像 UUID 变化时重新查询名称和路径。
    private struct ProcessMetadata {
        /// rusage 提供的进程启动时刻，用于检测 PID 重用。
        let started: UInt64
        /// 当前可执行映像的 UUID，用于检测原 PID 上的 exec。
        let executable: UUID
        /// 内核提供的进程名称，失败时保留可读的 PID 文本。
        let name: String
        /// 可执行路径；受保护进程可为空，不猜测应用归属。
        let path: String
    }

    /// 从内核读取时间基准，不硬编码 Intel 或 Apple Silicon 时钟频率。
    init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        secondsPerTick = Double(info.numer) / Double(info.denom) / 1_000_000_000
    }

    /// CPU、磁盘和内存复用一次 rusage 查询；正常路径不再逐进程读取需要汇总线程的 TASKALLINFO。
    func snapshot() -> CPUProcessSnapshot {
        let began = ProcessInfo.processInfo.systemUptime
        let capacity = min(131_072, max(1024, Int(proc_listallpids(nil, 0)) + 256))
        var pids = [Int32](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes { Int(proc_listallpids($0.baseAddress, Int32($0.count))) }
        var processes: [CPUProcessCounter] = [], nextMetadata: [Int32: ProcessMetadata] = [:]
        var denied = 0, skipped = 0, diskDenied = 0, diskSkipped = 0
        var memoryDenied = 0, memorySkipped = 0
        var diskProcesses: [DiskProcessCounter] = []
        var memoryProcesses: [MemoryProcessCounter] = []
        for pid in pids.prefix(max(0, min(count, capacity))) {
            var usage = rusage_info_v2()
            let rusageReadable = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) == 0 }
            }
            if !rusageReadable {
                // 先保存 rusage 的权限状态，后续 CPU 回退查询会改变 errno。
                if errno == EPERM || errno == EACCES {
                    diskDenied += 1
                    memoryDenied += 1
                } else {
                    diskSkipped += 1
                    memorySkipped += 1
                }
                // kernel_task 等不支持 rusage 的进程仍沿用原 CPU 接口，不减少原有 CPU 覆盖范围。
                if let process = fallbackCPU(pid: pid) { processes.append(process) }
                else if errno == EPERM || errno == EACCES { denied += 1 }
                else { skipped += 1 }
                continue
            }
            let executable = UUID(uuid: usage.ri_uuid)
            let item: ProcessMetadata
            if let cached = metadata[pid], cached.started == usage.ri_proc_start_abstime,
               cached.executable == executable {
                item = cached
            } else {
                var buffer = [CChar](repeating: 0, count: 1024)
                let name = proc_name(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : ""
                var pathBuffer = [CChar](repeating: 0, count: 4096)
                let path = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 ? String(cString: pathBuffer) : ""
                item = ProcessMetadata(started: usage.ri_proc_start_abstime, executable: executable,
                    name: name.isEmpty ? (pid == 0 ? "kernel_task" : "进程 \(pid)") : name, path: path)
            }
            nextMetadata[pid] = item
            let total = usage.ri_user_time.addingReportingOverflow(usage.ri_system_time)
            processes.append(CPUProcessCounter(pid: pid, started: item.started,
                ticks: total.overflow ? UInt64.max : total.partialValue, name: item.name, path: item.path))
            diskProcesses.append(DiskProcessCounter(pid: pid, started: item.started,
                readBytes: usage.ri_diskio_bytesread, writtenBytes: usage.ri_diskio_byteswritten, name: item.name, path: item.path))
            memoryProcesses.append(MemoryProcessCounter(pid: pid, started: item.started,
                footprintBytes: usage.ri_phys_footprint, name: item.name, path: item.path))
        }
        metadata = nextMetadata
        let completed = ProcessInfo.processInfo.systemUptime
        return CPUProcessSnapshot(version: CPUServiceIdentity.protocolVersion,
            uptime: completed, cores: ProcessInfo.processInfo.activeProcessorCount,
            secondsPerTick: secondsPerTick, privileged: geteuid() == 0,
            denied: denied, skipped: skipped, processes: processes,
            diskProcesses: diskProcesses, diskDenied: diskDenied, diskSkipped: diskSkipped,
            memoryProcesses: memoryProcesses, memoryDenied: memoryDenied, memorySkipped: memorySkipped,
            collectionDuration: completed - began)
    }

    /// 仅为 rusage 失败的进程回退；两种接口均返回 Mach ticks，不能将累计值误当成纳秒。
    private func fallbackCPU(pid: Int32) -> CPUProcessCounter? {
        var info = proc_taskallinfo()
        let size = Int32(MemoryLayout<proc_taskallinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info, size) == size else { return nil }
        let name = withUnsafePointer(to: &info.pbsd.pbi_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: 32) { String(cString: $0) }
        }
        var buffer = [CChar](repeating: 0, count: 4096)
        let path = proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : ""
        let ticks = info.ptinfo.pti_total_user.addingReportingOverflow(info.ptinfo.pti_total_system)
        return CPUProcessCounter(pid: pid,
            started: info.pbsd.pbi_start_tvsec * 1_000_000 + info.pbsd.pbi_start_tvusec,
            ticks: ticks.overflow ? UInt64.max : ticks.partialValue,
            name: name.isEmpty ? (pid == 0 ? "kernel_task" : "进程 \(pid)") : name, path: path)
    }

    /// 关闭详情时回收进程元数据，不在常驻状态保存完整进程表。
    func reset() { metadata.removeAll() }
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
