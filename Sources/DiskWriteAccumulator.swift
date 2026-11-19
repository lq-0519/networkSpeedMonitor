import Foundation

/// 保留管理员快照的整数写入计数，按 App 汇总有效窗口；由单一进程采样队列访问。
final class DiskWriteAccumulator {
    /// 最近一次成功采样的两种时间和进程计数；仅保留相邻一轮以限制后台内存。
    private var previous: (uptime: TimeInterval, time: TimeInterval, counters: [Int32: DiskProcessCounter])?

    /// 暂停、权限变化或采样故障时丢弃基线，恢复后不会把缺口算成零写入。
    func reset() { previous = nil }

    /// 快照时间以采集完成的单调时刻为准，再映射到界面使用的时间轴；空排行仍可报告有效采集区间。
    func consume(_ snapshot: CPUProcessSnapshot, resolver: ApplicationResolver,
                 time: Date = Date(), receivedUptime: TimeInterval = ProcessInfo.processInfo.systemUptime)
        -> (start: TimeInterval, end: TimeInterval, totals: [DiskWriteTotal])? {
        guard snapshot.privileged, let processes = snapshot.diskProcesses, !processes.isEmpty,
              snapshot.uptime.isFinite, snapshot.uptime <= receivedUptime else { reset(); return nil }
        // 同一份缓存快照可以服务多个请求；忽略重复时刻，保留首次收到时建立的基线。
        guard snapshot.uptime != previous?.uptime else { return nil }
        let end = time.timeIntervalSince1970 - (receivedUptime - snapshot.uptime)
        let baseline = previous.flatMap { old in
            let duration = snapshot.uptime - old.uptime
            return duration > 0 && duration <= 30 && end > old.time && abs((end - old.time) - duration) <= 2
                ? old : nil
        }

        var counters = [Int32: DiskProcessCounter](minimumCapacity: processes.count)
        var totals: [String: DiskWriteTotal] = [:]
        for process in processes {
            counters[process.pid] = process
            // 启动时间和路径需要相符；进程换成另一个程序或计数回退时，从本轮重新建立基线。
            guard let old = baseline?.counters[process.pid], old.started == process.started,
                  old.path == process.path, process.writtenBytes > old.writtenBytes else { continue }
            let app = resolver.resolve(path: process.path, pid: process.pid, fallback: process.name)
            let key = process.path.isEmpty ? "process:\(process.identity)" : app.key
            let delta = process.writtenBytes - old.writtenBytes
            let sum = (totals[key]?.bytes ?? 0).addingReportingOverflow(delta)
            totals[key] = DiskWriteTotal(key: key, name: app.name, bundlePath: app.bundle,
                                        bytes: sum.overflow ? UInt64.max : sum.partialValue)
        }
        previous = (snapshot.uptime, end, counters)
        return baseline.map { ($0.time, end, Array(totals.values)) }
    }
}
