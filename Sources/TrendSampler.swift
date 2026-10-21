import Foundation
import IOKit

/// 系统盘底层物理设备的累计计数差分；不枚举进程，不依赖管理员服务或外部命令。
final class DiskSystemReader {
    /// 已确认属于系统盘的块设备驱动，引用在暂停、设备失效和析构时释放。
    private var driver: io_registry_entry_t = 0
    /// 前一个累计字节计数及单调时间，首次读取只建立基线。
    private var previous: (read: UInt64, write: UInt64, uptime: TimeInterval)?
    /// 设备发现失败后低频重试，避免每轮遍历 I/O Registry。
    private var retryAfter: TimeInterval = 0

    /// 释放设备句柄和差分基线；恢复后首帧不能产生跨睡眠吞吐量。
    func reset() {
        if driver != 0 { IOObjectRelease(driver) }
        driver = 0; previous = nil; retryAfter = 0
    }

    /// 读取驱动维护的物理读写累计字节；计数回退、首帧和错误均返回未知而非零。
    func sample(uptime: TimeInterval) -> (read: Double, write: Double)? {
        if driver == 0 {
            guard uptime >= retryAfter else { return nil }
            retryAfter = uptime + 60
            driver = findSystemDriver()
        }
        guard driver != 0,
              let statistics = IORegistryEntryCreateCFProperty(driver, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
              let read = (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value,
              let write = (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value else {
            if driver != 0 { IOObjectRelease(driver); driver = 0 }
            previous = nil
            return nil
        }
        let old = previous; previous = (read, write, uptime)
        guard let old, uptime > old.uptime, uptime - old.uptime <= 30,
              read >= old.read, write >= old.write else { return nil }
        return (Double(read - old.read) / (uptime - old.uptime), Double(write - old.write) / (uptime - old.uptime))
    }

    /// 从根文件系统的 BSD 设备沿服务父链定位唯一物理驱动，避免累加 APFS 容器和多个逻辑卷。
    private func findSystemDriver() -> io_registry_entry_t {
        var filesystem = statfs()
        guard statfs("/", &filesystem) == 0 else { return 0 }
        let device = withUnsafePointer(to: &filesystem.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) { String(cString: $0) }
        }
        let name = URL(fileURLWithPath: device).lastPathComponent
        guard name.hasPrefix("disk"), let matching = IOBSDNameMatching(kIOMainPortDefault, 0, name) else { return 0 }
        var entry = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        for _ in 0..<48 {
            guard entry != 0 else { return 0 }
            if IOObjectConformsTo(entry, "IOBlockStorageDriver") != 0 { return entry }
            var parent: io_registry_entry_t = 0
            let status = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            guard status == KERN_SUCCESS else { return 0 }
            entry = parent
        }
        if entry != 0 { IOObjectRelease(entry) }
        return 0
    }

    /// 兜底释放唯一持有的 IOKit 引用。
    deinit { reset() }
}

/// 复用 CPU 采样唤醒的轻量整机采集器；应用排行始终由既有弹窗生命周期控制。
final class TrendSampler {
    /// 主线程交付整机内存和容量，一级概览与历史共享同一次读取。
    var onSystemUpdate: ((MemorySystemUsage?, DiskCapacity?) -> Void)?
    /// 记录整机标量的共享历史库。
    private let history: TrendHistoryStore
    /// 系统读取和计数器只属于此串行队列，不阻塞菜单栏绘制。
    private let queue = DispatchQueue(label: "com.local.NetworkSpeedMonitor.trend-sampler", qos: .utility)
    /// Mach VM 轻量整机读取器，不包含 PID 枚举。
    private let memory = MemorySystemReader()
    /// 系统盘物理累计字节差分器。
    private let disk = DiskSystemReader()
    /// 同一生命周期内的连续采集分段，重新采样后不跨段连线。
    private var segment = UUID().uuidString
    /// 主线程世代，在暂停后拒绝迟到的概览更新。
    private var epoch = UUID()
    /// 主线程暂停状态，锁屏、息屏、睡眠时不排入新任务。
    private var suspended = false
    /// 主线程仅允许一个在途整机读取，慢设备不会导致采样队列无限积压。
    private var pendingTick: UUID?
    /// 队列内的弹窗状态；可见期间功率、风扇复用既有快速采样。
    private var detailsVisible = false
    /// 最近一次后台功率、风扇读取的单调时刻。
    private var lastPower: TimeInterval = -.infinity
    /// 最近一次容量读取的单调时刻，容量至少相隔十秒。
    private var lastCapacity: TimeInterval = -.infinity
    /// 最近一次容量标量，供一级概览展示；不重复作为新的历史点。
    private var capacity: DiskCapacity?
    /// 最近一轮 CPU 采样时间，用于检测定时器停顿及系统时钟突变。
    private var previousClock: (wall: TimeInterval, uptime: TimeInterval)?

    /// 关联唯一历史库，不创建额外高频计时器。
    init(history: TrendHistoryStore) { self.history = history }

    /// 设置变化或系统暂停时失效旧任务，设备差分与时间轴从新分段开始。
    func reset(suspended value: Bool) {
        suspended = value; epoch = UUID(); pendingTick = nil
        queue.async { [self] in
            segment = UUID().uuidString; disk.reset(); previousClock = nil
            lastPower = -.infinity; lastCapacity = -.infinity; capacity = nil
            history.setSuspended(value)
        }
    }

    /// 一级弹窗打开时关闭后台功率读取；由可见采样回传读数，避免双重采集。
    func setDetailsVisible(_ visible: Bool) {
        queue.async { [self] in detailsVisible = visible; lastPower = -.infinity }
    }

    /// 每个 CPU 真正采样周期只调用一次；读取内存、磁盘吞吐量，并低频读取容量与功率。
    func tick(cpu: CPUSystemUsage?, at time: Date, uptime: TimeInterval, interval: Int) {
        guard !suspended, pendingTick == nil else { return }
        let current = epoch, request = UUID(); pendingTick = request
        queue.async { [self] in
            let wall = time.timeIntervalSince1970
            if let previousClock,
               uptime - previousClock.uptime > max(15, Double(interval) * 3)
                || abs((wall - previousClock.wall) - (uptime - previousClock.uptime)) > 5 {
                segment = UUID().uuidString; disk.reset()
            }
            previousClock = (wall, uptime)
            let usage = memory.sample(), io = disk.sample(uptime: uptime)
            let values = [TrendValue(metric: .cpu, value: cpu?.total),
                          TrendValue(metric: .memory, value: usage.map { Double($0.usedBytes) }),
                          TrendValue(metric: .diskRead, value: io?.read),
                          TrendValue(metric: .diskWrite, value: io?.write)]
            if uptime - lastCapacity >= 10 {
                lastCapacity = uptime; capacity = DiskCapacity.read()
                history.append(time: time, segment: segment, spacing: 10,
                               values: [TrendValue(metric: .diskUsed, value: capacity.map { Double($0.used) })])
            }
            history.append(time: time, segment: segment, spacing: Double(interval), values: values)
            if !detailsVisible, uptime - lastPower >= 5 {
                lastPower = uptime
                let sampledAt = Date()
                recordPower(PowerReader.read(), fans: FanReader.read(), at: sampledAt, spacing: max(5, Double(interval)))
            }
            let currentCapacity = capacity
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.pendingTick == request { self.pendingTick = nil }
                guard self.epoch == current, !self.suspended else { return }
                self.onSystemUpdate?(usage, currentCapacity)
            }
        }
    }

    /// 将可见电源采样的真实结果交给同一记录路径；不再读取一次 IOKit 或 SMC。
    func receivePower(_ snapshot: PowerSnapshot?, fans: FanSnapshot?, at time: Date, interval: Int) {
        guard !suspended else { return }
        queue.async { [self] in recordPower(snapshot, fans: fans, at: time, spacing: Double(interval)) }
    }

    /// 仅保存三项功率和实际风扇转速；无外部电源是确定的零输入，遥测失败仍为未知。
    private func recordPower(_ snapshot: PowerSnapshot?, fans: FanSnapshot?, at time: Date, spacing: TimeInterval) {
        let input = snapshot.map { $0.external ? $0.inputWatts : 0 } ?? nil
        var values = [TrendValue(metric: .inputPower, value: input),
                      TrendValue(metric: .systemPower, value: snapshot?.systemWatts, estimated: snapshot?.estimated ?? false),
                      TrendValue(metric: .batteryPower, value: snapshot?.batteryWatts, estimated: snapshot?.estimated ?? false)]
        if let fans {
            values += fans.fans.compactMap { fan in
                TrendMetric.fan(fan.index).map { TrendValue(metric: $0, value: fan.rpm) }
            }
        } else {
            values += (0..<10).compactMap { index in TrendMetric.fan(index).map { TrendValue(metric: $0, value: nil) } }
        }
        history.append(time: time, segment: segment, spacing: spacing, values: values)
    }

    /// 退出时等待已排入的轻量采样结束并释放设备，再由历史库提交最终批次。
    func shutdown() {
        suspended = true; epoch = UUID()
        queue.sync { disk.reset() }
    }
}
