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

/// 低频原生 CPU 采样；全机统计常驻，完整进程列表只在 CPU 面板可见时请求。
final class CPUMonitor {
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
    /// 整机 CPU 与进程排行使用全应用统一间隔，不再单独读取旧 CPU 偏好。
    var interval: Int { SamplingPreferences.interval }
    /// 所有底层计数器、连接、计时器与差分状态仅由此串行队列读写。
    private let queue = DispatchQueue(label: "com.local.NetworkSpeedMonitor.cpu", qos: .utility)
    /// 整机和详情共用一个带容差的定时器，避免重复唤醒。
    private var timer: DispatchSourceTimer?
    /// 四个整机状态计数器。
    private let systemReader = CPUSystemReader()
    /// 未授权时仍可显示当前用户的进程，并明确标注覆盖不足。
    private let localReader = CPUProcessReader()
    /// 软件占用差分计算器，关闭详情时释放基线。
    private let accumulator = CPUUsageAccumulator()
    /// 经过双向签名验证的按需管理员连接。
    private let client = CPUPrivilegedClient()
    /// 应用归属缓存仅在主线程上使用。
    private let resolver = ApplicationResolver()
    /// 主线程上的面板可见状态。
    private var visible = false
    /// 主线程上的系统暂停状态。
    private var suspended = false
    /// 系统计时器世代，用于拒绝重启前尚未交付的 UI 更新。
    private var systemEpoch = UUID()
    /// 详情世代，关闭面板时立即失效。
    private var rankingEpoch = UUID()
    /// 队列中的详情配置，nil 表示不采集任何进程。
    private var rankingRequest: (epoch: UUID, helper: Bool)?
    /// 单个请求及延迟提示、最终超时任务；等待期间不重复发送进程枚举请求。
    private var pending: (id: UUID, delayed: DispatchWorkItem, timeout: DispatchWorkItem)?
    /// 当前连接是否已经成功返回快照；新建或失效连接使用更长的启动等待期限。
    private var helperReady = false
    /// 本轮详情连续失败次数，决定有限的重连退避；成功采样后清零。
    private var retryFailures = 0
    /// 下次允许重连的单调时刻，现有整机采样定时器负责到期后发起请求。
    private var retryNotBefore: TimeInterval = 0

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
        queue.async { [self] in
            timer?.cancel(); timer = nil; systemReader.reset()
            guard !paused else { return }
            _ = systemReader.sample()
            let source = DispatchSource.makeTimerSource(queue: queue)
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
                self.sampleRanking()
            }
            timer = source; source.resume()
        }
        configureRanking()
        onUpdate?()
    }

    /// 展开立即记录一次进程基线；收起取消请求、释放缓存及管理员连接。
    func setRankingVisible(_ value: Bool) {
        guard visible != value else { return }
        visible = value; configureRanking()
    }

    /// 复用全应用的锁屏/睡眠状态，暂停期间不保留活动采样任务。
    func setSuspended(_ value: Bool) {
        guard suspended != value else { return }
        suspended = value; restart()
    }

    /// 授权安装成功后刷新连接和差分基线，防止混合普通权限与管理员结果。
    func authorizationChanged() { configureRanking() }

    /// 根据主线程界面状态生成一份不可变采集配置，过期回调无法污染新面板。
    private func configureRanking() {
        let epoch = UUID(); rankingEpoch = epoch
        let enabled = visible && !suspended, helper = CPUPrivilege.isInstalled
        trace("configure visible=\(visible) suspended=\(suspended) helper=\(helper) epoch=\(epoch)")
        applications = []; readableProcesses = 0; deniedProcesses = 0; privileged = false
        collectionStatus = enabled ? .sampling : .paused
        rankingStatus = collectionStatus.message; isRankingStale = false
        rankingRevision += 1
        onProcessSnapshot?(nil, collectionStatus)
        resolver.clear()
        queue.async { [self] in
            pending?.delayed.cancel(); pending?.timeout.cancel(); pending = nil
            client.close(); accumulator.reset(); localReader.reset()
            helperReady = false; retryFailures = 0; retryNotBefore = 0
            rankingRequest = enabled ? (epoch, helper) : nil
            if enabled { sampleRanking() }
        }
        onUpdate?()
    }

    /// 仅由采样队列调用；详情隐藏时快速返回，不枚举进程或唤醒管理员服务。
    private func sampleRanking() {
        guard let request = rankingRequest, pending == nil,
              ProcessInfo.processInfo.systemUptime >= retryNotBefore else { return }
        if !request.helper { receive(localReader.snapshot(), epoch: request.epoch); return }
        let id = UUID()
        let delayed = DispatchWorkItem { [weak self] in
            guard let self, self.pending?.id == id else { return }
            self.publishStatus(.retrying("采集延迟，正在等待服务响应。"), epoch: request.epoch)
        }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.pending?.id == id else { return }
            self.pending?.delayed.cancel(); self.pending = nil
            self.scheduleRetry(.retrying("采集超时，正在自动重试。"), epoch: request.epoch)
        }
        pending = (id, delayed, timeout)
        queue.asyncAfter(deadline: .now() + CPURequestTiming.delayedAfter, execute: delayed)
        queue.asyncAfter(deadline: .now() + (helperReady ? CPURequestTiming.sampleTimeout : CPURequestTiming.startupTimeout),
                         execute: timeout)
        client.read { [weak self] result in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self, self.pending?.id == id, self.rankingRequest?.epoch == request.epoch else { return }
                self.pending?.delayed.cancel(); self.pending?.timeout.cancel(); self.pending = nil
                switch result {
                case .success(let snapshot):
                    self.helperReady = true; self.retryFailures = 0; self.retryNotBefore = 0
                    self.receive(snapshot, epoch: request.epoch)
                case .failure(let error):
                    if let validation = error as? CPUServiceValidationError {
                        self.client.close(); self.helperReady = false; self.accumulator.reset()
                        self.rankingRequest = nil
                        self.publishStatus(validation.status, epoch: request.epoch)
                    } else {
                        self.scheduleRetry(.retrying("采集暂不可用，正在自动重试。"),
                                           epoch: request.epoch)
                    }
                }
            }
        }
    }

    /// 暂时故障断开失效连接并退避；保留差分基线，三十秒内恢复可直接计算，长缺口由差分器重建。
    private func scheduleRetry(_ status: ProcessCollectionStatus, epoch: UUID) {
        client.close(); helperReady = false
        retryFailures = min(4, retryFailures + 1)
        retryNotBefore = ProcessInfo.processInfo.systemUptime + CPURequestTiming.retryDelay(after: retryFailures)
        publishStatus(status, epoch: epoch)
    }

    /// 从累计快照计算占用，主线程只执行应用归类和可见 UI 更新。
    private func receive(_ snapshot: CPUProcessSnapshot, epoch: UUID) {
        let values = accumulator.consume(snapshot)
        trace("receive time=\(snapshot.uptime) cores=\(snapshot.cores) usages=\(values?.count ?? -1) epoch=\(epoch)")
        DispatchQueue.main.async { [weak self] in
            guard let self, self.rankingEpoch == epoch else { return }
            self.privileged = snapshot.privileged
            self.readableProcesses = snapshot.processes.count; self.deniedProcesses = snapshot.denied
            self.collectionStatus = .live
            self.onProcessSnapshot?(snapshot, .live)
            guard let values else {
                self.isRankingStale = !self.applications.isEmpty
                self.rankingStatus = self.isRankingStale ? "最近结果已过期，正在重新采样。" : "正在采样…"
                self.rankingRevision += 1
                self.onUpdate?()
                return
            }
            var grouped: [String: CPUApplicationUsage] = [:]
            for value in values {
                let process = value.process
                let app = self.resolver.resolve(path: process.path, pid: process.pid, fallback: process.name)
                var item = grouped[app.key] ?? CPUApplicationUsage(key: app.key, name: app.name,
                    bundlePath: app.bundle, percent: 0, processCount: 0, processes: [])
                item.percent += value.percent; item.processCount += 1
                item.processes.append(value); grouped[app.key] = item
            }
            // 先汇总完整占用，再保留最多五十个应用供设置即时切换；子进程明细仍有界为十项。
            let top = grouped.values.sorted {
                $0.percent == $1.percent ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.percent > $1.percent
            }.prefix(RankingPreferences.maximumCount)
            self.applications = top.map { item in
                var result = item
                result.processes = Array(item.processes.sorted {
                    $0.percent == $1.percent ? $0.process.pid < $1.process.pid : $0.percent > $1.percent
                }.prefix(10))
                return result
            }
            self.isRankingStale = false
            self.rankingStatus = values.isEmpty ? "当前没有可比较的进程样本" : "实时"
            self.trace("publish groups=\(self.applications.count) epoch=\(epoch)")
            self.rankingRevision += 1
            self.onUpdate?()
        }
    }

    /// 延迟时保留最近结果并明确标记过期；确定的权限或兼容性失败才清空不可用排行。
    private func publishStatus(_ status: ProcessCollectionStatus, epoch: UUID) {
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
        queue.sync {
            timer?.cancel(); timer = nil; rankingRequest = nil
            pending?.delayed.cancel(); pending?.timeout.cancel(); pending = nil
            client.close(); localReader.reset(); accumulator.reset()
        }
    }
}
