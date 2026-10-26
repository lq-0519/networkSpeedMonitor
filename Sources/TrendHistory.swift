import Foundation
import SQLite3

/// 所有自行采集的资源曲线共用的四个时间窗口；不改变底层采样频率，首次展示默认十分钟。
enum TrendRange: Int, CaseIterable {
    /// 保留最近一分钟的真实采样细节。
    case minute = 60
    /// 查看短时负载和传输变化。
    case tenMinutes = 600
    /// 查看过去一小时。
    case hour = 3600
    /// 查看本应用保留的最近二十四小时。
    case day = 86400

    /// 所有自行采集的资源趋势首次展示及关闭一级弹窗后统一使用十分钟。
    /// 控制器和图表共用此默认值，分段按钮按实际范围定位，不依赖选项排列顺序。
    static let defaultRange: TrendRange = .tenMinutes

    /// 原生分段控件中的固定名称。
    var title: String {
        switch self {
        case .minute: return "1分钟"
        case .tenMinutes: return "10分钟"
        case .hour: return "1小时"
        case .day: return "24小时"
        }
    }
}

/// 历史库的稳定列编号；只保存整机标量，不保存进程、应用或网络连接明细。
enum TrendMetric: Int, CaseIterable {
    /// 整机 CPU 非空闲时间百分比。
    case cpu
    /// 按现有 Mach VM 口径计算的已用内存字节。
    case memory
    /// 与菜单栏口径相同的下载、上传字节每秒。
    case download, upload
    /// 实际输入、系统负载及带正负方向的电池净功率，单位为瓦。
    case inputPower, systemPower, batteryPower
    /// 系统盘已用字节及底层物理设备读取、写入字节每秒。
    case diskUsed, diskRead, diskWrite
    /// 按 SMC 稳定编号保存的十个风扇转速列，单位为 RPM。
    case fan0, fan1, fan2, fan3, fan4, fan5, fan6, fan7, fan8, fan9

    /// 固定列名只由枚举生成，外部字符串不能进入 SQL 标识符。
    var column: String { "v\(rawValue)" }
    /// 位图区分本轮未采集与已采集但无效的 NULL，后者必须使曲线断开。
    var mask: Int64 { Int64(1) << rawValue }

    /// 已用容量与风扇转速按可见窗口的真实极值确定纵轴，因此查询及实时缓存保留完整标量。
    /// 绘图仍可压缩；旧极值滑出窗口后，未被压缩丢弃的其余样本可准确给出新的上下限。
    var usesWindowBounds: Bool { self == .diskUsed || rawValue >= Self.fan0.rawValue }

    /// 将合法 SMC 编号映射到固定列，不为异常数量创建无限列或缓存。
    static func fan(_ index: Int) -> TrendMetric? {
        guard (0..<10).contains(index) else { return nil }
        return TrendMetric(rawValue: TrendMetric.fan0.rawValue + index)
    }
}

/// 本轮实际读取的一个标量；nil 是明确的采集失败，不能转换为零。
struct TrendValue {
    /// 标量对应的稳定资源列。
    let metric: TrendMetric
    /// 有效的原始数值；不使用显示时已四舍五入的文本。
    let value: Double?
    /// 功率由收支或电流推算时保留估算标志。
    var estimated: Bool = false
}

/// 一次真实采集批次；不同来源各自保留实际时间，不拼接成假同步快照。
struct TrendSample {
    /// 数据库与未落盘缓冲共享的唯一递增标识，用于无缝合并和去重。
    let id: Int64
    /// 实际读取时刻的 Unix 秒，供查询和横轴使用。
    let time: TimeInterval
    /// 启停、计数器重置或来源变化后使用新分段，禁止跨分段连线。
    let segment: String
    /// 本次来源预期的读取间隔，用于识别长缺口。
    let spacing: TimeInterval
    /// 本轮确实读取的整机标量，不包含其他来源的旧值。
    let values: [TrendValue]
}

/// 绘图使用的单指标真实样本，保留极值和断线所需信息。
struct TrendPoint {
    /// 原始采样批次标识，压缩时用于去重。
    let id: Int64
    /// 原始采样时间，不插值创造历史记录。
    let time: TimeInterval
    /// 无效读数形成断点。
    let value: Double?
    /// 同一曲线的采集分段身份。
    let segment: String
    /// 超过该预期周期的三倍则不连接。
    let spacing: TimeInterval
    /// 悬停读数是否需要近似符号。
    let estimated: Bool
    /// 原始相邻样本之间存在长缺口；压缩后仍保留，不能按压缩点间距重新猜测缺口。
    var breakBefore: Bool = false
}

/// 一次合并数据库与尚未提交缓冲的历史读取结果。
struct TrendSnapshot {
    /// 每条曲线已按真实时间排序并压缩到显示量级。
    let series: [TrendMetric: [TrendPoint]]
    /// 读取包含的最后一个样本标识，迟到的实时通知可据此去重。
    let watermark: Int64
    /// 数据库不可读时仍返回内存曲线，并解释较早历史缺失。
    let error: String?
}

/// 按稳定时间桶保留首点、末点和真实最小最大值；增量压缩不会抹掉已保留的尖峰。
enum TrendDownsampler {
    /// 每条曲线通常最多约六百四十个点；断点和分段边界额外保留，禁止跨缺口合并。
    static func reduce(_ points: [TrendPoint], since start: TimeInterval, range: TrendRange) -> [TrendPoint] {
        let width = max(1, Double(range.rawValue) / 160)
        var result: [TrendPoint] = []
        var first: TrendPoint?, last: TrendPoint?, minimum: TrendPoint?, maximum: TrendPoint?
        var bucket: Int64?
        // 每桶只保留四个真实点，重复压缩仍保持真实最小值、最大值及其时间。
        func finish() {
            let optionalPoints: [TrendPoint?] = [first, minimum, maximum, last]
            var candidates: [TrendPoint] = optionalPoints.compactMap { $0 }
            candidates.sort { left, right in
                if left.time == right.time { return left.id < right.id }
                return left.time < right.time
            }
            var previous: Int64?
            for point in candidates where point.id != previous { result.append(point); previous = point.id }
            first = nil; last = nil; minimum = nil; maximum = nil
        }
        for point in points where point.time >= start {
            let nextBucket = Int64(floor(point.time / width))
            if bucket != nextBucket || point.breakBefore || last.map({ $0.segment != point.segment }) == true {
                finish()
            }
            bucket = nextBucket
            guard let value = point.value else {
                finish()
                if result.last?.value != nil || result.last.map({ Int64(floor($0.time / width)) != nextBucket }) != false {
                    result.append(point)
                }
                continue
            }
            if first == nil { first = point; minimum = point; maximum = point }
            if value < (minimum?.value ?? value) { minimum = point }
            if value > (maximum?.value ?? value) { maximum = point }
            last = point
        }
        finish()
        return result
    }
}

/// 本地二十四小时标量历史；单一串行队列拥有连接、缓冲和事务，读取不会遇到提交中的空档。
final class TrendHistoryStore {
    /// 主线程上的有效采样通知，仅当前可见趋势页订阅绘图。
    var onAppend: ((TrendSample) -> Void)?
    /// 所有 SQLite 操作和 pending 状态都限定在此低优先级队列。
    private let queue = DispatchQueue(label: "com.local.NetworkSpeedMonitor.trend-history", qos: .utility)
    /// 写连接不与系统 Powerlog 共用，失败也不影响实时菜单栏采集。
    private var database: OpaquePointer?
    /// 成功 COMMIT 前始终保留原样本；写入失败不会提前清空。
    private var pending: [TrendSample] = []
    /// 从库中最大标识继续递增；同一进程内不会因重试产生重复标识。
    private var nextID: Int64 = 0
    /// 连接初始化是否已经成功，以区分首次读取与失败重试。
    private var initialized = false
    /// 打开失败后的下一次允许时间，避免每秒反复触碰不可写目录。
    private var retryAfter: TimeInterval = 0
    /// 每分钟一次批量事务，暂停时取消，不新增高频写盘任务。
    private var timer: DispatchSourceTimer?
    /// 最近成功清理的单调时刻，系统校时不改变每小时清理节奏。
    private var lastCleanup: TimeInterval = 0
    /// 最近批量写入失败时向可见页面说明持久化受限，内存中的实时曲线仍继续工作。
    private var writeFailed = false
    /// 只有当前可见趋势需要的列才投递主线程通知，隐藏时不为历史存储额外唤醒 UI。
    private var observedMask: Int64 = 0
    /// 数据库失败时的有界缓冲上限，不让常驻内存无限增长。
    private static let maximumPending = 8192
    /// 所有查询严格裁剪二十四小时，物理删除可比查询边界晚至下一次低频清理。
    private static let retention: TimeInterval = 86400

    /// 启动异步打开和分钟写入；不在主线程创建目录、查询或提交事务。
    init() {
        queue.async { [self] in
            _ = openDatabase()
            configureTimer(enabled: true)
        }
    }

    /// 接收真实采样结果，在队列内分配标识并通知 UI；不为每个样本执行 SQL。
    func append(time: Date, segment: String, spacing: TimeInterval, values: [TrendValue]) {
        guard !values.isEmpty else { return }
        queue.async { [self] in
            nextID += 1
            let safe = values.map { TrendValue(metric: $0.metric, value: $0.value.flatMap { $0.isFinite ? $0 : nil }, estimated: $0.estimated) }
            let sample = TrendSample(id: nextID, time: time.timeIntervalSince1970,
                                     segment: segment, spacing: max(1, spacing), values: safe)
            pending.append(sample)
            if pending.count > Self.maximumPending { pending.removeFirst(pending.count - Self.maximumPending) }
            if sample.values.contains(where: { $0.metric.mask & observedMask != 0 }) {
                DispatchQueue.main.async { [weak self] in self?.onAppend?(sample) }
            }
        }
    }

    /// 二级页面切换时在同一串行队列更新订阅；关闭页面后不再投递其曲线样本。
    func observe(metrics: [TrendMetric]) {
        let mask = metrics.reduce(Int64(0)) { $0 | $1.mask }
        queue.async { [self] in observedMask = mask }
    }

    /// 仅在打开弹窗、正常退出或系统暂停时额外请求提交；UI 不等待落库即可显示内存数据。
    func flush() { queue.async { [self] in commit() } }

    /// 暂停前提交缓冲并取消分钟定时器；恢复后重新计时，不为锁屏或睡眠唤醒机器。
    func setSuspended(_ suspended: Bool) {
        queue.async { [self] in
            if suspended { commit() }
            configureTimer(enabled: !suspended)
        }
    }

    /// 在同一串行队列中读取库和待写样本，按标识去重；完成后由 UI 世代拒绝过期查询。
    func load(metrics: [TrendMetric], range: TrendRange, completion: @escaping (TrendSnapshot) -> Void) {
        queue.async { [self] in
            let end = Date().timeIntervalSince1970, start = end - Double(range.rawValue)
            var series: [TrendMetric: [TrendPoint]] = [:]
            var seen = Set<Int64>()
            var error: String? = writeFailed ? "近期趋势暂时无法保存，退出后可能丢失" : nil
            if openDatabase(), let database {
                let columns = metrics.map(\.column).joined(separator: ",")
                let mask = metrics.reduce(Int64(0)) { $0 | $1.mask }
                let sql = "SELECT id,time,segment,spacing,estimated,mask,\(columns) FROM samples WHERE time>=? AND time<=? AND (mask & ?) != 0 ORDER BY time,id"
                var statement: OpaquePointer?
                if sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement {
                    defer { sqlite3_finalize(statement) }
                    sqlite3_bind_double(statement, 1, start); sqlite3_bind_double(statement, 2, end)
                    sqlite3_bind_int64(statement, 3, mask)
                    var status = sqlite3_step(statement)
                    while status == SQLITE_ROW {
                        let id = sqlite3_column_int64(statement, 0), time = sqlite3_column_double(statement, 1)
                        let segment = String(cString: sqlite3_column_text(statement, 2))
                        let spacing = sqlite3_column_double(statement, 3), estimated = sqlite3_column_int64(statement, 4)
                        let sampled = sqlite3_column_int64(statement, 5)
                        seen.insert(id)
                        for (index, metric) in metrics.enumerated() where sampled & metric.mask != 0 {
                            let value = sqlite3_column_type(statement, Int32(index + 6)) == SQLITE_NULL
                                ? nil : sqlite3_column_double(statement, Int32(index + 6))
                            series[metric, default: []].append(TrendPoint(id: id, time: time, value: value,
                                segment: segment, spacing: spacing, estimated: estimated & metric.mask != 0))
                        }
                        status = sqlite3_step(statement)
                    }
                    if status != SQLITE_DONE { error = "暂时无法读取较早的趋势记录" }
                } else { error = "暂时无法读取较早的趋势记录" }
            } else { error = "暂时无法保存或读取较早的趋势记录" }
            for sample in pending where sample.time >= start && sample.time <= end && !seen.contains(sample.id) {
                for value in sample.values where metrics.contains(value.metric) {
                    series[value.metric, default: []].append(TrendPoint(id: sample.id, time: sample.time,
                        value: value.value, segment: sample.segment, spacing: sample.spacing, estimated: value.estimated))
                }
            }
            for metric in metrics {
                var sorted = (series[metric] ?? []).sorted { $0.time == $1.time ? $0.id < $1.id : $0.time < $1.time }
                for index in sorted.indices.dropFirst() {
                    let previous = sorted[index - 1]
                    sorted[index].breakBefore = sorted[index].time - previous.time > max(3, previous.spacing * 3)
                }
                series[metric] = metric.usesWindowBounds || sorted.count <= 800
                    ? sorted : TrendDownsampler.reduce(sorted, since: start, range: range)
            }
            let snapshot = TrendSnapshot(series: series, watermark: nextID, error: error)
            DispatchQueue.main.async { completion(snapshot) }
        }
    }

    /// 正常退出时等待最后一个批次提交并关闭连接，不遗留独立采集进程。
    func shutdown() {
        queue.sync {
            timer?.cancel(); timer = nil
            commit()
            if let database { sqlite3_close(database) }
            database = nil
        }
    }

    /// 分钟定时器容许五秒合并延迟；所有写入仍只发生在串行队列。
    private func configureTimer(enabled: Bool) {
        timer?.cancel(); timer = nil
        guard enabled else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + .seconds(60), repeating: .seconds(60), leeway: .seconds(5))
        source.setEventHandler { [weak self] in self?.commit() }
        timer = source; source.resume()
    }

    /// 创建本应用数据目录和固定标量表；WAL 有界检查点避免长期打开后日志无限增长。
    private func openDatabase() -> Bool {
        if database != nil { return true }
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= retryAfter else { return false }
        retryAfter = now + 60
        var opened: OpaquePointer?
        do {
            let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true)
            let directory = base.appendingPathComponent("NetworkSpeedMonitor", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let path = directory.appendingPathComponent("History.sqlite").path
            guard sqlite3_open_v2(path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
                  let opened else { throw CocoaError(.fileWriteUnknown) }
            sqlite3_busy_timeout(opened, 150)
            let columns = TrendMetric.allCases.map { "\($0.column) REAL" }.joined(separator: ",")
            let schema = "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA wal_autocheckpoint=256; CREATE TABLE IF NOT EXISTS samples(id INTEGER PRIMARY KEY,time REAL NOT NULL,segment TEXT NOT NULL,spacing REAL NOT NULL,mask INTEGER NOT NULL,estimated INTEGER NOT NULL,\(columns)); CREATE INDEX IF NOT EXISTS samples_time ON samples(time);"
            guard sqlite3_exec(opened, schema, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
            if !initialized {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(opened, "SELECT COALESCE(MAX(id),0) FROM samples", -1, &statement, nil) == SQLITE_OK,
                      let statement else { throw CocoaError(.fileReadUnknown) }
                defer { sqlite3_finalize(statement) }
                guard sqlite3_step(statement) == SQLITE_ROW else { throw CocoaError(.fileReadUnknown) }
                let oldMaximum = sqlite3_column_int64(statement, 0)
                // 首次打开失败后可能已有内存样本，统一平移标识以避免覆盖上次运行的数据。
                if oldMaximum > 0 {
                    pending = pending.map { TrendSample(id: $0.id + oldMaximum, time: $0.time,
                        segment: $0.segment, spacing: $0.spacing, values: $0.values) }
                    nextID += oldMaximum
                }
                initialized = true
            }
            database = opened
            cleanup(now: Date().timeIntervalSince1970)
            return true
        } catch {
            if let opened { sqlite3_close(opened) }
            return false
        }
    }

    /// 一个事务提交整个缓冲；任何插入或提交失败都回滚并保留待写记录。
    private func commit() {
        guard openDatabase(), let database else { writeFailed = true; return }
        let now = Date().timeIntervalSince1970
        pending.removeAll { $0.time < now - Self.retention }
        if !pending.isEmpty {
            let columns = TrendMetric.allCases.map(\.column)
            let placeholders = Array(repeating: "?", count: 6 + columns.count).joined(separator: ",")
            let sql = "INSERT OR IGNORE INTO samples(id,time,segment,spacing,mask,estimated,\(columns.joined(separator: ","))) VALUES(\(placeholders))"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { writeFailed = true; return }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { writeFailed = true; return }
            var succeeded = true
            for sample in pending {
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                sqlite3_bind_int64(statement, 1, sample.id); sqlite3_bind_double(statement, 2, sample.time)
                _ = sample.segment.withCString { sqlite3_bind_text(statement, 3, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
                sqlite3_bind_double(statement, 4, sample.spacing)
                sqlite3_bind_int64(statement, 5, sample.values.reduce(0) { $0 | $1.metric.mask })
                sqlite3_bind_int64(statement, 6, sample.values.filter(\.estimated).reduce(0) { $0 | $1.metric.mask })
                for value in sample.values {
                    if let number = value.value { sqlite3_bind_double(statement, Int32(value.metric.rawValue + 7), number) }
                }
                if sqlite3_step(statement) != SQLITE_DONE { succeeded = false; break }
            }
            if succeeded && sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK {
                pending.removeAll(keepingCapacity: true); writeFailed = false
            } else { sqlite3_exec(database, "ROLLBACK", nil, nil, nil); writeFailed = true }
        }
        cleanup(now: now)
    }

    /// 启动与每小时删除过期行，重用空闲页；不在采样路径执行全库 VACUUM。
    private func cleanup(now: TimeInterval) {
        let uptime = ProcessInfo.processInfo.systemUptime
        guard let database, lastCleanup == 0 || uptime - lastCleanup >= 3600 else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "DELETE FROM samples WHERE time < ?", -1, &statement, nil) == SQLITE_OK,
              let statement else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, now - Self.retention)
        if sqlite3_step(statement) == SQLITE_DONE { lastCleanup = uptime }
    }
}
