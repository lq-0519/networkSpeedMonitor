import Foundation

/// 菜单栏可独立勾选的内容，声明顺序同时确定显示顺序和设置中的控件顺序。
enum MenuBarComponent: String, CaseIterable {
    /// 保留现有的整机 CPU 饼图。
    case cpu
    /// 保留现有的上行、下行两行网速。
    case network
    /// 显示电量百分比及充满时间、续航或系统充电状态。
    case battery

    /// 原生设置控件和辅助功能共用的用户可读名称。
    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .network: return "网络速度"
        case .battery: return "电池"
        }
    }
}

/// 菜单栏显示偏好独立于采样设置；至少保留一项，防止入口因全部隐藏而消失。
enum MenuBarPreferences {
    /// 固定 Bundle ID 下的独立偏好键，不覆盖既有采样间隔或排行设置。
    private static let key = "menuBarComponents"

    /// 首次使用或配置损坏时显示全部三项，使新增电池信息直接可见。
    static var components: Set<MenuBarComponent> {
        validated(UserDefaults.standard.array(forKey: key) as? [String])
    }

    /// 忽略未知配置值；缺失或没有任何有效项时回退到全部内容，读取不改写偏好。
    static func validated(_ values: [String]?) -> Set<MenuBarComponent> {
        let selected = Set((values ?? []).compactMap(MenuBarComponent.init(rawValue:)))
        return selected.isEmpty ? Set(MenuBarComponent.allCases) : selected
    }

    /// 按固定顺序保存用户选择；空集合被拒绝，调用方应恢复最后一个勾选。
    @discardableResult
    static func setComponents(_ selected: Set<MenuBarComponent>) -> Bool {
        guard !selected.isEmpty else { return false }
        UserDefaults.standard.set(MenuBarComponent.allCases.filter(selected.contains).map(\.rawValue), forKey: key)
        return true
    }
}

/// 网络、CPU 与电源共用的采样偏好；沿用原网络配置键，升级时保留用户已有的网络间隔。
enum SamplingPreferences {
    /// 统一间隔以秒为单位，只允许现有 1 / 2 / 5 秒档位；缺失或非法值恢复为默认两秒。
    static var interval: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: "refreshInterval")
            return [1, 2, 5].contains(value) ? value : 2
        }
        set {
            UserDefaults.standard.set([1, 2, 5].contains(newValue) ? newValue : 2, forKey: "refreshInterval")
        }
    }
}

/// 四类应用排行各自保存显示数量；数量只控制展示，不改变采样周期或应用的完整统计总量。
enum RankingPreferences {
    /// 独立配置项的固定键；网络、CPU、内存默认十项，磁盘默认五项。
    enum Section: String, CaseIterable {
        /// 网络应用收发速度排行的独立显示条数。
        case network = "networkTopCount"
        /// CPU 应用完整占用排行的独立显示条数。
        case cpu = "cpuTopCount"
        /// 内存应用 footprint 排行的独立显示条数。
        case memory = "memoryTopCount"
        /// 磁盘应用读写速度排行的独立显示条数。
        case disk = "diskTopCount"

        /// 磁盘默认五项，其余排行默认十项。
        var defaultCount: Int { self == .disk ? 5 : 10 }

        /// 用户可读的设置名称，同时用于辅助功能，避免暴露持久化实现键。
        var title: String {
            switch self {
            case .network: return "网络排行数量"
            case .cpu: return "CPU 排行数量"
            case .memory: return "内存排行数量"
            case .disk: return "磁盘排行数量"
            }
        }
    }

    /// 显示数量上限也约束模型和图标缓存，防止误输入造成大量界面更新。
    static let maximumCount = 50

    /// 缺失或非法的历史设置使用模块默认值，读取不会改写用户偏好。
    static func count(for section: Section) -> Int {
        let value = UserDefaults.standard.integer(forKey: section.rawValue)
        return (1...maximumCount).contains(value) ? value : section.defaultCount
    }

    /// 将输入限制到一至五十并持久化；不重启底层采集或丢弃差分基线。
    static func setCount(_ count: Int, for section: Section) {
        UserDefaults.standard.set(min(maximumCount, max(1, count)), forKey: section.rawValue)
    }
}

/// 一个采样周期内的双向字节量；所有速度都除以实际单调时钟间隔，而不是假定定时器准时。
struct ByteCount: Equatable {
    /// 接收字节，保持 UInt64 避免大流量长时间运行时溢出。
    var received: UInt64 = 0
    /// 发出字节，包含所选统计层记录的协议开销。
    var sent: UInt64 = 0

    /// 汇总同一统计层的数据；调用者负责排除虚拟接口和父子统计的重复项。
    mutating func add(_ other: ByteCount) {
        received = received.addingReportingOverflow(other.received).partialValue
        sent = sent.addingReportingOverflow(other.sent).partialValue
    }
}

/// 一个完整的 nettop CSV 采样帧。首帧为历史累计值，后续帧才是 -d 输出的周期增量。
struct TrafficFrame {
    /// 按路由组或进程标签索引的增量；同一帧中重复行只保留一次。
    let rows: [String: ByteCount]
    /// 两个帧头之间的实际秒数，使用 systemUptime 排除系统时间调整。
    let duration: TimeInterval
    /// 连接明细按真实接口汇总；nil 表示旧格式路由帧。只保留接口名，不保存连接地址。
    var interfaceTotals: [String: ByteCount]? = nil
    /// 同一进程在直连接口的字节量，供应用排行扣除已独立展示的直连流量。
    var directApplications: [String: ByteCount] = [:]
}

/// 接收任意分块的 CSV 流，按重复表头划分帧，并避免把首帧累计流量当作实时速度。
final class TrafficParser {
    /// 尚未收到换行的尾部字节，避免 UTF-8 字符被管道拆分后损坏。
    private var pending = Data()
    /// 当前帧的唯一标签和字节量。
    private var rows: [String: ByteCount] = [:]
    /// 表头定义的输入、输出列位置，支持系统更新后列顺序改变。
    private var columns: (input: Int, output: Int)?
    /// 明细格式中的接口列；没有该列时继续兼容原路由汇总格式。
    private var interfaceColumn: Int?
    /// 当前连接所属进程，只保存系统进程标签，不保留 TCP/UDP 端点。
    private var currentProcess: String?
    /// 当前周期的接口连接总量，不累加进程汇总行，避免父子重复。
    private var interfaceTotals: [String: ByteCount] = [:]
    /// 当前周期已确认属于直连接口的进程流量。
    private var directApplications: [String: ByteCount] = [:]
    /// 当前采样帧头的单调时钟时间。
    private var headerTime: TimeInterval?
    /// 当前帧覆盖的真实时间；第一帧保持 nil。
    private var duration: TimeInterval?
    /// 已发布帧不能因为重复的静默回调而再次发布。
    private var delivered = false

    /// 增量解析管道字节；遇到下一帧头时也会提交上一帧，避免依赖管道读取块的边界。
    func consume(_ data: Data, at now: TimeInterval) -> [TrafficFrame] {
        pending.append(data)
        var completed: [TrafficFrame] = []
        while let end = pending.firstIndex(of: 10) {
            let line = String(decoding: pending[..<end], as: UTF8.self)
                .trimmingCharacters(in: .newlines)
            pending.removeSubrange(...end)
            if line == "#RESET" {
                rows.removeAll(keepingCapacity: true)
                columns = nil; headerTime = nil; duration = nil; delivered = false
                interfaceColumn = nil; currentProcess = nil
                interfaceTotals.removeAll(keepingCapacity: true); directApplications.removeAll(keepingCapacity: true)
                continue
            }
            let fields = Self.csvFields(line)
            if let input = fields.firstIndex(of: "bytes_in"),
               let output = fields.firstIndex(of: "bytes_out") {
                if let frame = finish() { completed.append(frame) }
                duration = headerTime.map { now - $0 }
                headerTime = now
                columns = (input, output)
                interfaceColumn = fields.firstIndex(of: "interface")
                currentProcess = nil
                interfaceTotals.removeAll(keepingCapacity: true); directApplications.removeAll(keepingCapacity: true)
                rows.removeAll(keepingCapacity: true)
                delivered = false
            } else if let columns, !delivered,
                      fields.count > max(columns.input, columns.output),
                      let label = fields.first, !label.isEmpty,
                      let received = UInt64(fields[columns.input]),
                      let sent = UInt64(fields[columns.output]) {
                let bytes = ByteCount(received: received, sent: sent)
                if let index = interfaceColumn, fields.indices.contains(index) {
                    // CSV 连接行没有缩进；按协议前缀识别，不能以空接口把未绑定连接误认成进程。
                    let connection = ["tcp4 ", "tcp6 ", "udp4 ", "udp6 ", "quic ", "quic4 ", "quic6 "].contains { label.hasPrefix($0) }
                    if !connection, fields[index].isEmpty,
                       let dot = label.lastIndex(of: "."), Int32(label[label.index(after: dot)...]) != nil {
                        currentProcess = label; rows[label] = ByteCount()
                    } else if let process = currentProcess {
                        let interface = fields[index]
                        if !interface.isEmpty { interfaceTotals[interface, default: ByteCount()].add(bytes) }
                        // 系统的进程汇总可能夹带回环连接；逐连接合计排除 lo0，避免把本机 IPC 当网络。
                        if interface != "lo0" { rows[process, default: ByteCount()].add(bytes) }
                        if NetworkMonitor.directInterfaceNames.contains(interface) {
                            directApplications[process, default: ByteCount()].add(bytes)
                        }
                    }
                } else { rows[label] = bytes }
            }
        }
        // 有界缓存：损坏输出不能让常驻程序无限增长内存。
        if pending.count > 1_048_576 { pending.removeAll(); columns = nil }
        return completed
    }

    /// 在一帧输出静默后提交；首帧、半行以及无效时间间隔都不会产生虚假速度。
    func finish() -> TrafficFrame? {
        guard !delivered, columns != nil, pending.isEmpty else { return nil }
        delivered = true
        guard let duration, duration >= 0.1, duration <= 30 else { return nil }
        return TrafficFrame(rows: rows, duration: duration,
                            interfaceTotals: interfaceColumn == nil ? nil : interfaceTotals,
                            directApplications: directApplications)
    }

    /// 解析 CSV 的引号及双引号转义，兼容包含空格、逗号的进程显示名称。
    static func csvFields(_ line: String) -> [String] {
        var result: [String] = [], field = "", quoted = false
        var iterator = line.makeIterator()
        var current = iterator.next()
        while let character = current {
            if character == "\"" {
                let next = iterator.next()
                if quoted && next == "\"" { field.append("\""); current = iterator.next(); continue }
                quoted.toggle(); current = next; continue
            }
            if character == "," && !quoted { result.append(field); field = "" }
            else { field.append(character) }
            current = iterator.next()
        }
        result.append(field)
        return result
    }
}

/// 用户选择的排行口径，同时用于持久化与界面分段控件。
enum RankingOrder: Int {
    /// 按收发合计排序。
    case combined = 0
    /// 按下载速度排序。
    case download = 1
    /// 按上传速度排序。
    case upload = 2
}

/// 单个 App 在当前周期内的汇总速度；仅内存保存，不积累使用历史。
struct AppTraffic {
    /// App 路径或无法识别进程的稳定标识。
    let key: String
    /// 展示名称，优先使用应用本地化名称。
    let name: String
    /// 已确认的 App bundle 路径，用于按需读取图标。
    let bundlePath: String?
    /// 最近周期的下载字节/秒。
    var download: Double
    /// 最近周期的上传字节/秒。
    var upload: Double
    /// 合并到该 App 的进程数量。
    var processes: Int

    /// 返回当前排序口径对应的数值。
    func value(for order: RankingOrder) -> Double {
        switch order {
        case .combined: return download + upload
        case .download: return download
        case .upload: return upload
        }
    }
}

/// 网络列表的统一行模型；直连保持独立统计身份，但与软件使用同一速度口径排序。
enum NetworkRankingRow {
    /// 一个普通软件的当前周期汇总，直连字节已由采集模型扣除。
    case application(AppTraffic)
    /// 当前周期的直连收发速度；停顿时仍使用实际零值，不沿用历史峰值。
    case direct(download: Double, upload: Double, idle: Bool)

    /// 普通软件的元数据；直连没有可伪造的 PID、应用路径或进程数量。
    var application: AppTraffic? {
        if case .application(let app) = self { return app }
        return nil
    }

    /// 当前行的下载字节每秒，供排序与单元格展示共用。
    var download: Double {
        switch self {
        case .application(let app): return app.download
        case .direct(let download, _, _): return download
        }
    }

    /// 当前行的上传字节每秒，供排序与单元格展示共用。
    var upload: Double {
        switch self {
        case .application(let app): return app.upload
        case .direct(_, let upload, _): return upload
        }
    }

    /// 仅直连可进入停顿防抖阶段；软件行保留原有的当前周期行为。
    var isIdle: Bool {
        if case .direct(_, _, let idle) = self { return idle }
        return false
    }

    /// 排序和展示采用相同名称，速度相同时按名称及稳定身份减少无意义换位。
    var name: String { application?.name ?? "设备直连" }

    /// 类型前缀避免未知进程名称或标识与直连条目冲突。
    private var key: String { application.map { "app:\($0.key)" } ?? "direct" }

    /// 返回选中的速度口径，直连不再作为特殊尾行排除在排序之外。
    func value(for order: RankingOrder) -> Double {
        switch order {
        case .combined: return download + upload
        case .download: return download
        case .upload: return upload
        }
    }

    /// 对已限量的软件及可选直连行统一降序排列；不改写速度、活动状态或采样基线。
    static func sorted(_ rows: [NetworkRankingRow], by order: RankingOrder) -> [NetworkRankingRow] {
        rows.sorted {
            let left = $0.value(for: order), right = $1.value(for: order)
            if left != right { return left > right }
            let names = $0.name.localizedStandardCompare($1.name)
            return names == .orderedSame ? $0.key < $1.key : names == .orderedAscending
        }
    }
}

/// 设备直连临时条目的显示状态；只随现有网络帧推进，不创建额外计时器。
struct DirectTrafficActivity {
    /// 首个有效非零周期立即显示；没有活动时不预留表格行。
    private(set) var isVisible = false
    /// 短暂零流量时标注停顿，速度仍使用当前零值，不保留旧的非零读数。
    private(set) var isIdle = false
    /// 最后一个非零周期的单调时间；重启、休眠及采集失败后清除。
    private var lastActiveTime: TimeInterval?
    /// 至少容忍八秒的间歇，五秒刷新时容忍三个周期；到期后随下一帧移除，无额外计时器。
    static func idleGracePeriod(for interval: Int) -> TimeInterval { max(8, Double(interval) * 3) }

    /// 接收一个可靠周期的收发速度；任一方向有流量即显示，不用阈值遗漏低速传输。
    /// 不可用、负值或非有限数据立即隐藏，防抖只适用于可读取接口的有效零流量。
    /// interval 使用当前统一刷新设置，使慢刷新时不会因一个空帧就隐藏正在间歇传输的条目。
    mutating func consume(download: Double?, upload: Double?, at now: TimeInterval, interval: Int) {
        guard let download, let upload, download.isFinite, upload.isFinite,
              download >= 0, upload >= 0, now.isFinite else { reset(); return }
        if download > 0 || upload > 0 {
            lastActiveTime = now; isVisible = true; isIdle = false
        } else {
            isVisible = lastActiveTime.map { now >= $0 && now - $0 < Self.idleGracePeriod(for: interval) } ?? false
            isIdle = isVisible
            if !isVisible { lastActiveTime = nil }
        }
    }

    /// 采样基线失效时同步移除临时条目，防止旧活动在新周期或错误状态中继续显示。
    mutating func reset() { isVisible = false; isIdle = false; lastActiveTime = nil }
}

/// 使用十进制 KB/MB 显示字节每秒；格式与菜单栏、弹出面板和排行榜保持一致。
enum SpeedText {
    /// 根据速度量级选择精度，固定上限避免异常输入破坏菜单栏布局。
    static func string(_ bytes: Double) -> String {
        guard bytes.isFinite, bytes >= 0 else { return "—" }
        if bytes < 1_000 { return String(format: "%.0f B/s", bytes) }
        if bytes < 1_000_000 { return String(format: "%.0f KB/s", bytes / 1_000) }
        if bytes < 1_000_000_000 { return String(format: "%.1f MB/s", bytes / 1_000_000) }
        return String(format: "%.1f GB/s", bytes / 1_000_000_000)
    }
}
