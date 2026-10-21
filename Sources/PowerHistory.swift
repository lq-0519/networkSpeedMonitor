import Foundation
import SQLite3
import zlib

/// 电量详情允许选择的固定范围；不读取历史偏好，应用启动时默认十小时。
enum PowerHistoryRange: Int, CaseIterable {
    /// 查看最近一小时，复用系统历史查询，不改变默认十小时窗口。
    case hour = 1
    /// 默认展示窗口。
    case tenHours = 10
    /// 查看过去一天的电量变化。
    case day = 24
    /// 查看过去一周，包含系统已经归档的电池记录。
    case week = 168

    /// 分段选择器使用的紧凑名称，不包含未要求的十二小时选项。
    var title: String {
        switch self {
        case .hour: return "1 小时"
        case .tenHours: return "10 小时"
        case .day: return "24 小时"
        case .week: return "7 天"
        }
    }

    /// 传给数据库查询和曲线横轴的真实秒数，七天按连续 168 小时计算。
    var seconds: TimeInterval { Double(rawValue) * 3600 }
}

/// 系统 Powerlog 的单条电池记录；时间为 Unix 秒，电量使用系统的 Level 百分比。
struct PowerHistorySample: Codable {
    /// 系统生成这条记录的时间，不使用本应用读取数据库的时间代替。
    let time: TimeInterval
    /// 用户可见的电量百分比，已经排除缺失值、非有限数和超出 0～100 的值。
    let percent: Double
    /// 是否连接外部电源；不把“未充电”误认成“电池供电”。
    let external: Bool
    /// 电池实际充电标志，与外部电源连接状态分别保留。
    let charging: Bool
}

/// 系统记录支持的时间区间；用于休眠阴影，不为缺失记录伪造采样点。
struct PowerHistoryInterval: Codable {
    /// 区间开始的 Unix 时间。
    let start: TimeInterval
    /// 区间结束的 Unix 时间，必须晚于开始。
    let end: TimeInterval
}

/// 根据可比较的系统历史推算的摘要，接电时的电量变化不会累计为电池耗电。
struct PowerHistorySummary {
    /// 可比较区间中由电池供电的秒数，包含有系统休眠记录支持的睡眠时间。
    let batterySeconds: TimeInterval
    /// 电池供电期间下降的百分点之和；充电回升及接电区间均不抵扣或加入。
    let decline: Double
}

/// 一次按需读取的所选范围快照，仅驻留内存，不创建本应用的历史数据库。
struct PowerHistorySnapshot: Codable {
    /// 所选范围的固定左边界，缺少数据时也不缩短横轴。
    let start: TimeInterval
    /// 查询时刻对应的横轴右边界，不把数据库最近更新时间当成“现在”。
    let end: TimeInterval
    /// 已按时间排序并去重的记录；可含左边界前半小时内的一个或多个基线。
    let samples: [PowerHistorySample]
    /// 已裁剪到展示窗口及左侧基线范围，并合并重叠的系统休眠区间。
    let sleeps: [PowerHistoryInterval]
    /// 无休眠证据时最多连接半小时内的相邻记录，避免跨越长时间数据缺口。
    static let maximumGap: TimeInterval = 30 * 60

    /// 过滤异常系统数据、固定展示窗口并合并重叠休眠事件，避免重复累计暗唤醒区间。
    static func make(start: TimeInterval, end: TimeInterval, samples: [PowerHistorySample],
                     sleeps: [PowerHistoryInterval]) -> PowerHistorySnapshot {
        var unique: [TimeInterval: PowerHistorySample] = [:]
        for sample in samples where sample.time.isFinite && sample.percent.isFinite
            && sample.time >= start - maximumGap && sample.time <= end && (0...100).contains(sample.percent) {
            unique[sample.time] = sample
        }
        let clipped = sleeps.compactMap { interval -> PowerHistoryInterval? in
            guard interval.start.isFinite, interval.end.isFinite else { return nil }
            let lower = max(start - maximumGap, interval.start), upper = min(end, interval.end)
            return upper > lower ? PowerHistoryInterval(start: lower, end: upper) : nil
        }.sorted { $0.start < $1.start }
        var merged: [PowerHistoryInterval] = []
        for interval in clipped {
            if let last = merged.last, interval.start <= last.end {
                merged[merged.count - 1] = PowerHistoryInterval(start: last.start, end: max(last.end, interval.end))
            } else { merged.append(interval) }
        }
        return PowerHistorySnapshot(start: start, end: end,
            samples: unique.values.sorted { $0.time < $1.time }, sleeps: merged)
    }

    /// 允许连接短采样间隔；长间隔必须由休眠记录覆盖且前后供电状态相同，不能猜测缺口。
    func connects(_ before: PowerHistorySample, _ after: PowerHistorySample) -> Bool {
        let duration = after.time - before.time
        guard duration > 0 else { return false }
        if duration <= Self.maximumGap { return true }
        guard before.external == after.external else { return false }
        let sleeping = sleeps.reduce(0.0) { total, interval in
            total + max(0, min(after.time, interval.end) - max(before.time, interval.start))
        }
        return sleeping >= duration - 5 * 60
    }

    /// 只在两个真实记录之间累计；不外推最后一条记录至现在，窗口边缘按区间比例裁剪。
    var summary: PowerHistorySummary? {
        var seconds = 0.0, decline = 0.0, comparable = false
        for (before, after) in zip(samples, samples.dropFirst()) where connects(before, after) {
            let duration = min(end, after.time) - max(start, before.time)
            guard duration > 0 else { continue }
            comparable = true
            if !before.external { seconds += duration }
            if !before.external && !after.external {
                decline += max(0, before.percent - after.percent) * duration / (after.time - before.time)
            }
        }
        return comparable ? PowerHistorySummary(batterySeconds: seconds, decline: decline) : nil
    }
}

/// 读取失败使用用户能理解的错误，不能将权限、表结构变化或超时伪装成空历史。
private enum PowerHistoryReadError: LocalizedError {
    /// 系统没有数据库，或者当前用户不能以只读方式打开。
    case unavailable
    /// 系统内部表结构变化或查询失败，需要兼容新版系统。
    case query
    /// 数据库繁忙或查询预算耗尽，本次停止读取，等待之后按需重试。
    case busy

    /// 面板只展示简短错误，完整的数据库路径或 SQL 不进入产品界面。
    var errorDescription: String? {
        switch self {
        case .unavailable: return "暂时无法读取系统电量历史"
        case .query: return "当前系统的电量历史格式暂不支持"
        case .busy: return "系统电量历史繁忙，请稍后重试"
        }
    }
}

/// 对系统数据库或归档内存映像的短时只读连接，不创建历史文件或执行系统私有 RPC。
private final class PowerHistoryDatabase {
    /// READONLY 打开的 SQLite 连接，只在历史读取队列内使用。
    private let handle: OpaquePointer
    /// 每次打开最多允许约一秒查询工作，防止异常系统表长时间占用 CPU。
    private let deadline = ProcessInfo.processInfo.systemUptime + 1

    /// 打开已有系统文件并限制锁等待；未找到数据库时不允许 SQLite 自动创建空文件。
    init(path: String) throws {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard result == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw PowerHistoryReadError.unavailable
        }
        handle = database
        configureReadLimits()
    }

    /// 逐块把系统 gzip 归档解压到 SQLite 管理的内存，最多 64 MiB，关闭连接即释放。
    /// SQLite 官方反序列化接口要求内存映像使用 rollback 头；只改内存副本的 18/19 字节。
    init(archive: URL) throws {
        let file = try FileHandle(forReadingFrom: archive)
        defer { try? file.close() }
        let length = try file.seekToEnd()
        guard length >= 4 else { throw PowerHistoryReadError.query }
        try file.seek(toOffset: length - 4)
        guard let footer = try file.read(upToCount: 4), footer.count == 4 else { throw PowerHistoryReadError.query }
        let size = footer.enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
        guard size >= 100, size <= 64 * 1024 * 1024,
              let memory = sqlite3_malloc64(UInt64(size + 32)) else { throw PowerHistoryReadError.query }
        var transferred = false
        defer { if !transferred { sqlite3_free(memory) } }
        guard let gzip = gzopen(archive.path, "rb") else { throw PowerHistoryReadError.unavailable }
        defer { gzclose(gzip) }
        let expires = ProcessInfo.processInfo.systemUptime + 1
        var offset = 0
        while offset < size {
            guard ProcessInfo.processInfo.systemUptime < expires else { throw PowerHistoryReadError.busy }
            let count = gzread(gzip, memory.advanced(by: offset), UInt32(min(65536, size - offset)))
            guard count > 0 else { throw PowerHistoryReadError.query }
            offset += Int(count)
        }
        var extra: UInt8 = 0
        guard gzread(gzip, &extra, 1) == 0 else { throw PowerHistoryReadError.query }
        let bytes = memory.assumingMemoryBound(to: UInt8.self)
        guard memcmp(bytes, "SQLite format 3\0", 16) == 0 else { throw PowerHistoryReadError.query }
        bytes[18] = 1; bytes[19] = 1
        memset(memory.advanced(by: size), 0, 32)
        var database: OpaquePointer?
        guard sqlite3_open_v2(":memory:", &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            throw PowerHistoryReadError.unavailable
        }
        // FREEONCLOSE 在失败时也接管并释放内存，不能再由上面的 defer 重复释放。
        transferred = true
        let result = sqlite3_deserialize(database, "main", bytes, Int64(size), Int64(size + 32),
            UInt32(SQLITE_DESERIALIZE_READONLY | SQLITE_DESERIALIZE_FREEONCLOSE))
        guard result == SQLITE_OK else { sqlite3_close(database); throw PowerHistoryReadError.query }
        handle = database
        configureReadLimits()
    }

    /// 活动库和内存归档共用短时锁等待、进度预算及只读查询行为。
    private func configureReadLimits() {
        sqlite3_busy_timeout(handle, 200)
        sqlite3_exec(handle, "PRAGMA query_only=ON", nil, nil, nil)
        sqlite3_progress_handler(handle, 2000, { context in
            guard let context else { return 1 }
            let owner = Unmanaged<PowerHistoryDatabase>.fromOpaque(context).takeUnretainedValue()
            return ProcessInfo.processInfo.systemUptime >= owner.deadline ? 1 : 0
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    /// 参数绑定查询的数值列；NULL 保留为 nil，数量上限由调用方的固定 SQL 限制。
    func rows(_ sql: String, from start: TimeInterval, to end: TimeInterval) throws -> [[Double?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw PowerHistoryReadError.query
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_double(statement, 1, start) == SQLITE_OK,
              sqlite3_bind_double(statement, 2, end) == SQLITE_OK else { throw PowerHistoryReadError.query }
        var result: [[Double?]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else {
                throw status == SQLITE_BUSY || status == SQLITE_LOCKED || status == SQLITE_INTERRUPT
                    ? PowerHistoryReadError.busy : PowerHistoryReadError.query
            }
            result.append((0..<sqlite3_column_count(statement)).map { index in
                let kind = sqlite3_column_type(statement, index)
                return kind == SQLITE_INTEGER || kind == SQLITE_FLOAT ? sqlite3_column_double(statement, index) : nil
            })
        }
    }

    /// 先移除回调再关闭连接，SQLite 不会保留指向已经释放对象的上下文。
    deinit {
        sqlite3_progress_handler(handle, 0, nil, nil)
        sqlite3_close(handle)
    }
}

/// 直接读取 macOS 已维护的电池历史，只在二级详情需要刷新时调用。
enum PowerHistoryReader {
    /// 系统 Powerlog 当前数据库；不读取用户应用活动、网络端点或其他无关系统表。
    static let databasePath = "/var/db/powerlog/Library/BatteryLife/CurrentPowerlog.PLSQL"

    /// 查询所选范围及左侧半小时基线；活动库覆盖不足时按需读取系统 gzip 归档。
    static func read(range: PowerHistoryRange = .tenHours, now: Date = Date(),
                     path: String = databasePath) throws -> PowerHistorySnapshot {
        let end = now.timeIntervalSince1970, start = end - range.seconds
        let database = try PowerHistoryDatabase(path: path)
        let current = try read(database: database, start: start, end: end)
        var samples: [PowerHistorySample] = [], sleeps: [PowerHistoryInterval] = []
        if (current.samples.first?.time ?? end) > start {
            let directory = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("Archives")
            let budget = ProcessInfo.processInfo.systemUptime + 3
            for archive in archiveURLs(in: directory, since: start, until: current.samples.first?.time ?? end) {
                guard ProcessInfo.processInfo.systemUptime < budget else { break }
                // 某份系统归档已清理、损坏或无法读取时保留真实缺口，不阻断其他可用记录。
                if let archived = try? read(database: PowerHistoryDatabase(archive: archive), start: start, end: end) {
                    samples += archived.samples; sleeps += archived.sleeps
                }
            }
        }
        // 活动库放在最后，相同时间戳以最新系统记录为准；归档连接已逐个释放。
        samples += current.samples; sleeps += current.sleeps
        return .make(start: start, end: end, samples: samples, sleeps: sleeps)
    }

    /// 仅选择系统命名的相关日期归档，最多八份以覆盖七天窗口及左侧基线，拒绝子目录和链接。
    private static func archiveURLs(in directory: URL, since start: TimeInterval, until end: TimeInterval) -> [URL] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? []
        return Array(urls.filter { url in
            let name = url.lastPathComponent
            guard name.hasPrefix("powerlog_"), name.hasSuffix(".PLSQL.gz"), name.count >= 27,
                  let date = formatter.date(from: String(name.dropFirst(9).prefix(10))),
                  date.timeIntervalSince1970 >= start - 86400, date.timeIntervalSince1970 <= end,
                  let attributes = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  attributes.isRegularFile == true, attributes.isSymbolicLink != true else { return false }
            return true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }.suffix(8))
    }

    /// 单个系统库读取相同字段，活动库和归档共享过滤规则；条数限制覆盖七天分钟级记录。
    private static func read(database: PowerHistoryDatabase, start: TimeInterval,
                             end: TimeInterval) throws -> PowerHistorySnapshot {
        let rows = try database.rows("""
            SELECT timestamp, Level, ExternalConnected, IsCharging
            FROM PLBatteryAgent_EventBackward_Battery
            WHERE timestamp >= ? AND timestamp <= ? ORDER BY timestamp DESC, ID DESC LIMIT 24000
            """, from: start - PowerHistorySnapshot.maximumGap, to: end)
        let samples = rows.reversed().compactMap { row -> PowerHistorySample? in
            guard let time = row[0], let percent = row[1], let external = row[2], let charging = row[3],
                  (external == 0 || external == 1), (charging == 0 || charging == 1) else { return nil }
            return PowerHistorySample(time: time, percent: percent, external: external == 1, charging: charging == 1)
        }
        // 休眠表属于可选增强：缺失时仍可展示电量，长缺口保持断开，不据此猜测休眠。
        let sleepRows = (try? database.rows("""
            SELECT timestamp, KernelSleepDate, Event FROM PLSleepWakeAgent_EventForward_PowerState
            WHERE timestamp >= ? AND timestamp <= ? AND (KernelSleepDate > 0 OR Event = 0)
            ORDER BY timestamp DESC, ID DESC LIMIT 12000
            """, from: start - PowerHistorySnapshot.maximumGap, to: end)) ?? []
        return .make(start: start, end: end, samples: samples, sleeps: sleepIntervals(from: sleepRows))
    }

    /// KernelSleepDate 是进入休眠时刻，所在行可能紧随休眠写入，不能把该行时间当成唤醒。
    /// 本机已与 pmset 对齐确认 Event=0 为唤醒记录；用其与前一次休眠配对，没有配对则不猜测。
    static func sleepIntervals(from rows: [[Double?]]) -> [PowerHistoryInterval] {
        let wakes = rows.compactMap { row -> TimeInterval? in
            guard row.count == 3, row[2] == 0, let time = row[0], time.isFinite else { return nil }
            return time
        }.sorted()
        return rows.compactMap { row -> PowerHistoryInterval? in
            guard row.count == 3, let start = row[1], start.isFinite, start > 0 else { return nil }
            var lower = 0, upper = wakes.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if wakes[middle] <= start { lower = middle + 1 } else { upper = middle }
            }
            guard lower < wakes.count else { return nil }
            return PowerHistoryInterval(start: start, end: wakes[lower])
        }
    }
}

/// 历史详情的按需模型；关闭时不保留计时器，不与实时电源的 1 / 2 / 5 秒采样绑定。
final class PowerHistoryMonitor {
    /// 主线程通知，仅让历史详情更新图形和两个摘要值。
    var onUpdate: (() -> Void)?
    /// 有界的内存快照，短时间重新悬浮时复用；不写入磁盘。
    private(set) var snapshot: PowerHistorySnapshot?
    /// 空历史和读取错误分别表达，避免将错误显示成零耗电。
    private(set) var error: String?
    /// 当前是否正在读取，用于抑制重复请求。
    private(set) var loading = false
    /// 当前选择，重新打开一级弹窗时恢复默认十小时，不新增持久化设置。
    private(set) var range: PowerHistoryRange = .tenHours
    /// 四种范围各保留一份短时内存缓存，切换时不会混用范围或反复解压相同归档。
    private var cache: [PowerHistoryRange: (snapshot: PowerHistorySnapshot, loadedAt: TimeInterval)] = [:]
    /// 只有电源二级详情可见时为 true，一级概览打开不会触发历史读取。
    private var visible = false
    /// 详情关闭或重新打开时更新世代，拒绝旧查询的迟到回调。
    private var epoch = UUID()
    /// 成功查询的单调时刻，用于三分钟内的悬浮缓存复用。
    private var loadedAt: TimeInterval?
    /// SQLite 读取在低优先级串行队列执行，不阻塞 UI 或实时电源采样。
    private let queue = DispatchQueue(label: "com.local.NetworkSpeedMonitor.power-history", qos: .utility)
    /// 仅在二级详情持续打开时存在的三分钟刷新器，关闭即取消。
    private var timer: DispatchSourceTimer?
    /// 关闭详情时取消尚未开始的读取，快速划过多个概览块不会堆积数据库请求。
    private var request: DispatchWorkItem?

    /// 切换范围时失效旧请求，立即清除旧曲线；只有匹配当前范围和世代的结果可以发布。
    func setRange(_ value: PowerHistoryRange) {
        guard range != value else { return }
        range = value; epoch = UUID(); loading = false; error = nil
        request?.cancel(); request = nil
        snapshot = cache[value]?.snapshot; loadedAt = cache[value]?.loadedAt
        if visible { refreshIfNeeded() }
        else { onUpdate?() }
    }

    /// 打开时按缓存年龄决定是否查询；关闭时取消刷新并使在途结果失效。
    func setVisible(_ value: Bool) {
        guard visible != value else { return }
        visible = value; epoch = UUID(); loading = false
        timer?.cancel(); timer = nil
        request?.cancel(); request = nil
        guard value else { return }
        refreshIfNeeded()
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + .seconds(180), repeating: .seconds(180), leeway: .seconds(10))
        source.setEventHandler { [weak self] in self?.refreshIfNeeded(force: true) }
        timer = source; source.resume()
    }

    /// 只读取系统现有记录；没有两秒轮询、后台采集或持久化历史，失败后下次打开可重试。
    private func refreshIfNeeded(force: Bool = false) {
        guard visible, !loading else { return }
        let age = loadedAt.map { ProcessInfo.processInfo.systemUptime - $0 }
        if !force, error == nil, let age, age >= 0, age < 180 { onUpdate?(); return }
        loading = true; error = nil
        let current = epoch, selectedRange = range
        onUpdate?()
        let work = DispatchWorkItem { [weak self] in
            let result = Result { try PowerHistoryReader.read(range: selectedRange) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.visible, self.epoch == current, self.range == selectedRange else { return }
                self.loading = false; self.request = nil
                switch result {
                case .success(let value):
                    let loaded = ProcessInfo.processInfo.systemUptime
                    self.snapshot = value; self.loadedAt = loaded
                    self.cache[selectedRange] = (value, loaded)
                case .failure(let failure):
                    self.snapshot = nil; self.loadedAt = nil; self.error = failure.localizedDescription
                }
                self.onUpdate?()
            }
        }
        request = work; queue.async(execute: work)
    }

    /// 控制器释放时取消最后一个低频刷新器，不留下独立后台工作。
    deinit { timer?.cancel(); request?.cancel() }
}
