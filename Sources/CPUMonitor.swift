import AppKit

/// 聚合后的软件整机 CPU 占比，子进程详情在同一个采样窗口内计算。
struct CPUApplicationUsage {
    /// 已确认的 App 路径或独立系统进程身份。
    let key: String
    /// 用户可读的软件或系统进程名称。
    let name: String
    /// 图标对应的外层 App 路径，系统进程可为空。
    let bundlePath: String?
    /// 软件的全部可归属进程占整机 CPU 的比例。
    var percent: Double
    /// 聚合所包含的全部进程数，不能用截取后的明细数量代替。
    var processCount: Int
    /// 当前软件占用最高的最多十个进程，供详情展开使用。
    var processes: [CPUProcessUsage]
}

/// 低频原生 CPU 采样；整机趋势、实时排行与可选磁盘历史共用一次计时唤醒和进程请求。
final class CPUMonitor {
    /// 每次配置同时记录 UI 是否消费快照和是否写入历史；只有已安装管理员服务才启用历史采集。
    private struct ProcessRequest {
        /// 当前配置的世代，用于拒绝旧定时事件和已入队的 UI 回调。
        let epoch: UUID
        /// 使用经过签名和权限校验的管理员连接；普通权限只供原有实时排行回退。
        let helper: Bool
        /// 弹窗可见时才进行 CPU 排序及主线程发布。
        let visible: Bool
        /// 启用后同一快照也用于磁盘写入累计。
        let recordsDiskWrites: Bool
    }

    /// 主线程数据变化通知，驱动菜单栏及当前可见面板。
    var onUpdate: (() -> Void)?
    /// 仅真实整机计数采样触发，设置、排行和界面刷新不会重复写入历史。
    var onSystemSample: ((CPUSystemUsage?, Date, TimeInterval, Int) -> Void)?
    /// 统一周期或睡眠状态变化时重建整机历史分段与磁盘计数基线。
    var onSystemReset: ((Bool) -> Void)?
    /// 同一详情快照同时交给内存和磁盘模型；nil 配合状态区分保留过期结果与关闭时清空。
    var onProcessSnapshot: ((CPUProcessSnapshot?, ProcessCollectionStatus) -> Void)?
    /// 最近一轮有效整机占用，nil 表示正在建立基线或已暂停。
    private(set) var usage: CPUSystemUsage?
    /// 按完整软件占用排序的有界快照，界面根据独立 Top 偏好截取。
    private(set) var applications: [CPUApplicationUsage] = []
    /// 本轮成功读取的进程数，用于展示实际覆盖情况。
    private(set) var readableProcesses = 0
    /// 管理员权限是否已在最新实际采样中验证。
    private(set) var privileged = false
    /// 不可读取的进程数量，不能被界面当成零占用。
    private(set) var deniedProcesses = 0
    /// 详情状态说明，包含首次基线及授权失败信息。
    private(set) var rankingStatus = "正在采样…"
    /// 最近一次采集状态；暂时超时与实际权限、版本校验失败分别展示。
    private(set) var collectionStatus: ProcessCollectionStatus = .sampling
    /// 最近排行是否因延迟或恢复基线而过期；整机 CPU 摘要仍独立更新。
    private(set) var isRankingStale = false
    /// 仅在排行内容或状态变化时递增，整机数字刷新不触发表格重建。
    private(set) var rankingRevision = 0
    /// 最近成功快照的单调时刻，用于诊断当前排行的数据年龄。
    private(set) var rankingSampleTime: TimeInterval?
    /// 最近成功请求从发送到解码完成的总等待时长，包含服务启动及传输。
    private(set) var rankingRequestDuration: TimeInterval?
    /// 服务实际枚举进程的耗时；旧服务未提供该字段时保持 nil。
    private(set) var rankingCollectionDuration: TimeInterval?
    /// 整机 CPU 与进程排行使用全应用统一间隔，不再单独读取旧 CPU 偏好。
    var interval: Int { SamplingPreferences.interval }
    /// 低成本整机统计独立运行，不被普通权限进程枚举或应用归类阻塞。
    private let systemQueue = DispatchQueue(label: "com.local.NetworkSpeedMonitor.cpu.system", qos: .utility)
    /// 低优先级串行处理进程快照；后台记录不经过主线程。
    private let rankingQueue = DispatchQueue(label: "com.local.NetworkSpeedMonitor.cpu.ranking", qos: .utility)
    /// 整机和详情共用一个带容差的定时器，避免重复唤醒。
    private var timer: DispatchSourceTimer?
    /// 仅由 systemQueue 访问，按已有 1、2、5 秒周期计步，隐藏时约每十秒才投递一个采样任务。
    private var processSchedule: (epoch: UUID, stride: Int, remaining: Int)?
    /// 后台写入记录复用整机定时器，全局周期的三档均可整除这一间隔。
    private static let backgroundDiskInterval = 10
    /// 四个整机状态计数器。
    private let systemReader = CPUSystemReader()
    /// 未授权时仍可显示当前用户的进程，并明确标注覆盖不足。
    private let localReader = CPUProcessReader()
    /// 软件占用差分计算器，关闭详情时释放基线。
    private let accumulator = CPUUsageAccumulator()
    /// 经过双向签名验证的按需管理员连接。
    private let client = CPUPrivilegedClient()
    /// 应用归属缓存仅由 rankingQueue 使用，首次读取 App 元数据也不会阻塞界面。
    private let resolver = ApplicationResolver()
    /// 仅 GUI 注入持久化历史；现有有限时长的诊断入口照常只读。
    private let history: TrendHistoryStore?
    /// 独立保存写入计数基线，使前后台切换及实时排行基线重置时保持连续。
    private let diskWriter = DiskWriteAccumulator()
    /// 主线程上的用户选择，关掉弹窗后仍可按需记录。
    private var diskHistoryEnabled: Bool
    /// 主线程上的面板可见状态。
    private var visible = false
    /// 主线程上的系统暂停状态。
    private var suspended = false
    /// 系统计时器世代，用于拒绝重启前尚未交付的 UI 更新。
    private var systemEpoch = UUID()
    /// 详情世代，关闭面板时立即失效。
    private var rankingEpoch = UUID()
    /// 采样队列中的当前请求配置，nil 表示不采集任何进程。
    private var rankingRequest: ProcessRequest?
    /// 单个请求及延迟提示、最终超时任务；等待期间不重复发送进程枚举请求。
    private var pending: (id: UUID, delayed: DispatchWorkItem?, timeout: DispatchWorkItem)?
    /// 当前连接是否已经成功返回快照；新建或失效连接使用更长的启动等待期限。
    private var helperReady = false
    /// 本轮详情连续失败次数，决定有限的重连退避；成功采样后清零。
    private var retryFailures = 0
    /// 下次允许重连的单调时刻，现有整机采样定时器负责到期后发起请求。
    private var retryNotBefore: TimeInterval = 0

    /// 主程序提供可选历史库，诊断实例维持现有按需采集行为。
    init(history: TrendHistoryStore? = nil) {
        self.history = history
        diskHistoryEnabled = history != nil && DiskWriteHistoryPreferences.isEnabled
    }

    /// 显式诊断参数才输出生命周期，不在常驻运行时写入每帧日志。
    private func trace(_ message: String) {
        if CommandLine.arguments.contains("--cpu-trace") { fputs("CPU \(ProcessInfo.processInfo.systemUptime) \(message)\n", stderr) }
    }

    /// 应用启动或刷新间隔变化时重建整机采样，并同步详情状态。
    func restart() {
        usage = nil
        let epoch = UUID(); systemEpoch = epoch
        let paused = suspended, seconds = interval
        onSystemReset?(paused)
        systemQueue.async { [self] in
            timer?.cancel(); timer = nil; systemReader.reset()
            guard !paused else { return }
            _ = systemReader.sample()
            let source = DispatchSource.makeTimerSource(queue: systemQueue)
            source.schedule(deadline: .now() + .seconds(seconds), repeating: .seconds(seconds), leeway: .milliseconds(150))
            source.setEventHandler { [weak self] in
                guard let self else { return }
                let value = self.systemReader.sample()
                let sampledAt = Date(), uptime = ProcessInfo.processInfo.systemUptime
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.systemEpoch == epoch else { return }
                    self.onSystemSample?(value, sampledAt, uptime, seconds)
                    self.usage = value; self.onUpdate?()
                }
                self.scheduleProcessSample()
            }
            timer = source; source.resume()
        }
        configureRanking()
        onUpdate?()
    }

    /// 展开立即建立实时基线；收起时按历史记录设置降频或关闭连接。
    func setRankingVisible(_ value: Bool) {
        guard visible != value else { return }
        visible = value; configureRanking()
    }

    /// 设置变更通过同一采样配置生效，关闭记录时即丢弃历史差分基线。
    func setDiskHistoryEnabled(_ value: Bool) {
        guard history != nil, diskHistoryEnabled != value else { return }
        diskHistoryEnabled = value; configureRanking()
    }

    /// 复用全应用的锁屏/睡眠状态，暂停期间不保留活动采样任务。
    func setSuspended(_ value: Bool) {
        guard suspended != value else { return }
        suspended = value; restart()
    }

    /// 授权安装成功后刷新连接和差分基线，防止混合普通权限与管理员结果。
    func authorizationChanged() { configureRanking(resetConnection: true) }

    /// 根据主线程界面状态生成一份不可变采集配置，过期回调无法污染新面板。
    private func configureRanking(resetConnection: Bool = false) {
        let epoch = UUID(); rankingEpoch = epoch
        let enabled = visible && !suspended
        let wantsHistory = diskHistoryEnabled && !suspended
        let helper = (enabled || wantsHistory) && CPUPrivilege.isInstalled
        let recordsDiskWrites = wantsHistory && helper
        let request = enabled || recordsDiskWrites
            ? ProcessRequest(epoch: epoch, helper: helper, visible: enabled, recordsDiskWrites: recordsDiskWrites)
            : nil
        trace("configure visible=\(visible) suspended=\(suspended) helper=\(helper) epoch=\(epoch)")
        applications = []; readableProcesses = 0; deniedProcesses = 0; privileged = false
        rankingSampleTime = nil; rankingRequestDuration = nil; rankingCollectionDuration = nil
        collectionStatus = enabled ? .sampling : .paused
        rankingStatus = collectionStatus.message; isRankingStale = false
        rankingRevision += 1
        onProcessSnapshot?(nil, collectionStatus)
        let stride = enabled ? 1 : Self.backgroundDiskInterval / interval
        systemQueue.async { [self] in
            processSchedule = request.map { ($0.epoch, stride, stride) }
        }
        rankingQueue.async { [self] in
            let old = rankingRequest
            let restarts = resetConnection || request == nil || old?.helper != request?.helper
            if restarts {
                closeProcessSource(); localReader.reset(); resolver.clear()
            }
            accumulator.reset()
            if restarts || !recordsDiskWrites || old?.recordsDiskWrites != true {
                diskWriter.reset()
            }
            rankingRequest = request
            if enabled || (recordsDiskWrites && (restarts || old?.recordsDiskWrites != true)) {
                sampleRanking()
            }
        }
        onUpdate?()
    }

    /// 在整机计时队列先限频；休眠后重新配置步数，未启用记录时不向采样队列投递空任务。
    private func scheduleProcessSample() {
        guard var schedule = processSchedule else { return }
        schedule.remaining -= 1
        if schedule.remaining == 0 {
            schedule.remaining = schedule.stride
            let epoch = schedule.epoch
            rankingQueue.async { [weak self] in
                guard let self, self.rankingRequest?.epoch == epoch else { return }
                self.sampleRanking()
            }
        }
        processSchedule = schedule
    }

    /// 仅由采样队列调用；实时排行和后台记录共用一个在途请求、连接与退避策略。
    private func sampleRanking() {
        guard let request = rankingRequest, pending == nil,
              ProcessInfo.processInfo.systemUptime >= retryNotBefore else { return }
        if !request.helper { receive(localReader.snapshot(), request: request); return }
        let id = UUID(), began = ProcessInfo.processInfo.systemUptime
        let delayed = request.visible ? DispatchWorkItem { [weak self] in
            guard let self, self.pending?.id == id else { return }
            self.publishProcessStatus(.retrying("采集延迟，正在等待服务响应。"))
        } : nil
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.pending?.id == id else { return }
            self.pending?.delayed?.cancel(); self.pending = nil
            self.scheduleRetry(.retrying("采集超时，正在自动重试。"))
        }
        pending = (id, delayed, timeout)
        if let delayed { rankingQueue.asyncAfter(deadline: .now() + CPURequestTiming.delayedAfter, execute: delayed) }
        rankingQueue.asyncAfter(deadline: .now() + (helperReady ? CPURequestTiming.sampleTimeout : CPURequestTiming.startupTimeout),
                         execute: timeout)
        client.read { [weak self] result in
            guard let self else { return }
            let duration = ProcessInfo.processInfo.systemUptime - began
            self.rankingQueue.async { [weak self] in
                guard let self, self.pending?.id == id, let current = self.rankingRequest else { return }
                self.pending?.delayed?.cancel(); self.pending?.timeout.cancel(); self.pending = nil
                switch result {
                case .success(let snapshot):
                    self.helperReady = true; self.retryFailures = 0; self.retryNotBefore = 0
                    self.receive(snapshot, request: current, requestDuration: duration)
                case .failure(let error):
                    if let validation = error as? CPUServiceValidationError {
                        self.publishProcessStatus(validation.status)
                        self.stopProcessSampling(epoch: current.epoch)
                    } else {
                        self.scheduleRetry(.retrying("采集暂不可用，正在自动重试。"))
                    }
                }
            }
        }
    }

    /// 暂时故障断开并退避；写入历史将这段保留为缺口，实时排行沿用原有过期状态。
    private func scheduleRetry(_ status: ProcessCollectionStatus) {
        client.close(); helperReady = false
        diskWriter.reset()
        retryFailures = min(4, retryFailures + 1)
        retryNotBefore = ProcessInfo.processInfo.systemUptime + CPURequestTiming.retryDelay(after: retryFailures)
        publishProcessStatus(status)
    }

    /// 连接不用时取消在途任务，退出或重新授权后从干净连接与退避状态开始。
    private func closeProcessSource() {
        pending?.delayed?.cancel(); pending?.timeout.cancel(); pending = nil
        client.close(); helperReady = false; retryFailures = 0; retryNotBefore = 0
    }

    /// 确定不兼容时停止此世代的轮询，直到重新打开面板、改变设置或更新授权。
    private func stopProcessSampling(epoch: UUID) {
        closeProcessSource(); accumulator.reset(); diskWriter.reset(); resolver.clear()
        rankingRequest = nil
        systemQueue.async { [weak self] in
            guard let self, self.processSchedule?.epoch == epoch else { return }
            self.processSchedule = nil
        }
    }

    /// 隐藏时仅处理磁盘字节，不做实时 CPU 计算、排序、主线程通知和其他资源刷新。
    private func receive(_ snapshot: CPUProcessSnapshot, request: ProcessRequest, requestDuration: TimeInterval? = nil) {
        if request.recordsDiskWrites, let history {
            if snapshot.diskProcesses == nil && !request.visible {
                stopProcessSampling(epoch: request.epoch)
                return
            }
            if let sample = diskWriter.consume(snapshot, resolver: resolver) {
                history.appendDiskWrites(start: sample.start, end: sample.end, totals: sample.totals)
            }
        }
        guard request.visible else { return }
        let epoch = request.epoch
        let values = accumulator.consume(snapshot)
        let groups = values.map { groupedApplications($0) }
        trace("receive time=\(snapshot.uptime) request=\(requestDuration ?? -1) collection=\(snapshot.collectionDuration ?? -1) cores=\(snapshot.cores) usages=\(values?.count ?? -1) epoch=\(epoch)")
        DispatchQueue.main.async { [weak self] in
            guard let self, self.rankingEpoch == epoch else { return }
            self.privileged = snapshot.privileged
            self.rankingSampleTime = snapshot.uptime
            self.rankingRequestDuration = requestDuration
            self.rankingCollectionDuration = snapshot.collectionDuration
            self.readableProcesses = snapshot.processes.count; self.deniedProcesses = snapshot.denied
            self.collectionStatus = .live
            self.onProcessSnapshot?(snapshot, .live)
            guard let values, let groups else {
                self.isRankingStale = !self.applications.isEmpty
                self.rankingStatus = self.isRankingStale ? "最近结果已过期，正在重新采样。" : "正在采样…"
                self.rankingRevision += 1
                self.onUpdate?()
                return
            }
            self.applications = groups
            self.isRankingStale = false
            self.rankingStatus = values.isEmpty ? "当前没有可比较的进程样本" : "实时"
            self.trace("publish groups=\(self.applications.count) epoch=\(epoch)")
            self.rankingRevision += 1
            self.onUpdate?()
        }
    }

    /// 完整汇总后再截取五十个应用和每项十个子进程，保持原有排行口径及设置即时切换能力。
    private func groupedApplications(_ values: [CPUProcessUsage]) -> [CPUApplicationUsage] {
        var grouped: [String: CPUApplicationUsage] = [:]
        for value in values {
            let process = value.process
            let app = resolver.resolve(path: process.path, pid: process.pid, fallback: process.name)
            var item = grouped[app.key] ?? CPUApplicationUsage(key: app.key, name: app.name,
                bundlePath: app.bundle, percent: 0, processCount: 0, processes: [])
            item.percent += value.percent; item.processCount += 1
            item.processes.append(value); grouped[app.key] = item
        }
        let top = grouped.values.sorted {
            $0.percent == $1.percent ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.percent > $1.percent
        }.prefix(RankingPreferences.maximumCount)
        return top.map { item in
            var result = item
            result.processes = Array(item.processes.sorted {
                $0.percent == $1.percent ? $0.process.pid < $1.process.pid : $0.percent > $1.percent
            }.prefix(10))
            return result
        }
    }

    /// 仅在实时详情可见时发布故障状态；同一请求跨前后台时取当前世代。
    private func publishProcessStatus(_ status: ProcessCollectionStatus) {
        guard let request = rankingRequest, request.visible else { return }
        let epoch = request.epoch
        DispatchQueue.main.async { [weak self] in
            guard let self, self.rankingEpoch == epoch else { return }
            self.collectionStatus = status
            if status.preservesResult {
                self.isRankingStale = !self.applications.isEmpty
            } else {
                self.applications = []; self.privileged = false; self.isRankingStale = false
                self.readableProcesses = 0; self.deniedProcesses = 0
            }
            self.rankingStatus = self.isRankingStale ? "最近结果已过期。\(status.message)" : status.message
            self.rankingRevision += 1
            self.onProcessSnapshot?(nil, status)
            self.onUpdate?()
        }
    }

    /// 退出时同步释放计时器与 XPC 连接，后台服务随后按空闲期限结束。
    func shutdown() {
        systemEpoch = UUID(); rankingEpoch = UUID()
        systemQueue.sync { timer?.cancel(); timer = nil; processSchedule = nil }
        rankingQueue.sync {
            rankingRequest = nil
            closeProcessSource(); localReader.reset(); accumulator.reset(); diskWriter.reset(); resolver.clear()
        }
    }
}
