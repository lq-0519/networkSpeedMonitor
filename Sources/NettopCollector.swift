import Foundation
import OSLog

/// 在独立串行队列中维护一个只读 nettop 子进程，保持 stdin 打开以避免本机 EOF 空转问题。
final class NettopCollector {
    /// 普通根路由保持原生低耗路径；AWDL 使用系统权限采集，完整应用明细仅在弹窗可见时启动。
    enum Mode {
        /// 普通物理接口的根路由增量，协议不兼容时使用系统连接明细。
        case routes
        /// 系统 nettop 按 AWDL 类型筛选的直连明细，覆盖用户态 QUIC。
        case direct
        /// 弹窗中所有对外连接的应用排行。
        case applications
    }
    /// 完整增量帧通过主队列交给界面模型。
    var onFrame: ((TrafficFrame) -> Void)?
    /// 仅报告状态变化和失败，不记录每秒的流量、连接地址或内容。
    var onStatus: ((String?) -> Void)?
    /// 子进程和解析状态只由该队列访问，避免并发重启与过期输出污染新采样。
    private let queue = DispatchQueue(label: "com.local.NetworkSpeedMonitor.collector", qos: .utility)
    /// 当前持有的子进程。
    private var process: Process?
    /// 保持写端打开，不写数据；关闭 stdin 会导致当前系统 nettop 高 CPU 空转。
    private var inputPipe: Pipe?
    /// 持有 stdout，关闭采集时主动解除读取回调。
    private var outputPipe: Pipe?
    /// 当前 CSV 解析器，每次启动都重新建立首帧基线。
    private var parser = TrafficParser()
    /// 在最后一个输出块之后提交帧，不额外创建周期轮询定时器。
    private var flush: DispatchWorkItem?
    /// 无数据超时检测，每个有效输出块会取消并重设。
    private var watchdog: DispatchWorkItem?
    /// 异常退出后的有界退避重启任务。
    private var retry: DispatchWorkItem?
    /// 请求的采集参数；nil 表示用户已停止该采集器。
    private var request: (mode: Mode, interval: Int)?
    /// 每次停止或重启递增，用于丢弃旧进程的异步回调。
    private var generation = 0
    /// 主线程上的回调准入标识；停止立即失效，避免队列中旧帧覆盖新设置后的占位状态。
    private var allowedDelivery = UUID()
    /// 串行采集队列持有的标识副本，跨队列只传值，不共享读写。
    private var currentDelivery = UUID()
    /// 连续故障次数，用于指数退避，避免后台反复创建进程。
    private var failures = 0
    /// 状态日志使用统一日志系统，并且不输出网络端点。
    private let logger = Logger(subsystem: "com.local.NetworkSpeedMonitor", category: "collector")

    /// 启动采集；不同刷新间隔通过完整重启重置累计首帧，防止出现启动瞬时峰值。
    func start(mode: Mode, interval: Int) {
        let delivery = UUID()
        allowedDelivery = delivery
        queue.async { [weak self] in
            guard let self else { return }
            self.stopLocked()
            self.currentDelivery = delivery
            self.request = (mode, max(1, min(5, interval)))
            self.failures = 0
            self.launchLocked()
        }
    }

    /// 停止子进程并释放管道；主线程不等待进程退出。
    func stop() {
        allowedDelivery = UUID()
        queue.async { [weak self] in self?.request = nil; self?.stopLocked() }
    }

    /// 应用退出时同步收回管道和子进程，避免菜单栏退出后留下孤立的采集任务。
    func shutdown() {
        allowedDelivery = UUID()
        queue.sync { request = nil; stopLocked() }
    }

    /// 只在串行队列调用，创建进程与异步管道读取，不经过 shell。
    private func launchLocked() {
        guard let request else { return }
        generation += 1
        let token = generation
        parser = TrafficParser()
        let child = Process(), input = Pipe(), output = Pipe()
        // 极小的原生守护包装器只管理进程生命周期。即使主程序被强制退出，也会收回 nettop。
        child.executableURL = Bundle.main.url(forAuxiliaryExecutable: "NetworkSampler")
        let mode: String
        switch request.mode {
        case .routes: mode = "routes"
        case .direct: mode = "direct"
        case .applications: mode = "applications"
        }
        child.arguments = [mode, String(request.interval)]
        child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "LANG": "C"]
        child.standardInput = input
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        inputPipe = input; outputPipe = output; process = child
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.queue.async { [weak self] in
                guard let self, self.generation == token, self.request != nil else { return }
                self.received(data, token: token)
            }
        }
        child.terminationHandler = { [weak self] task in
            self?.queue.async { [weak self] in
                guard let self, self.generation == token, self.request != nil else { return }
                self.failed("采集进程已退出（\(task.terminationStatus)），正在重试")
            }
        }
        do {
            try child.run()
            report("正在采样…")
            armWatchdog(token: token)
        } catch { failed("无法启动网络统计，正在重试") }
    }

    /// 消费一个输出块，延迟 80ms 等待该帧剩余块到达；采样时间仍取帧头时间。
    private func received(_ data: Data, token: Int) {
        for frame in parser.consume(data, at: ProcessInfo.processInfo.systemUptime) { publish(frame) }
        flush?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            if let frame = self.parser.finish() { self.publish(frame) }
        }
        flush = work
        queue.asyncAfter(deadline: .now() + .milliseconds(80), execute: work)
        armWatchdog(token: token)
    }

    /// 帧回调在主队列执行，成功后清除故障退避状态。
    private func publish(_ frame: TrafficFrame) {
        failures = 0
        let delivery = currentDelivery
        DispatchQueue.main.async { [weak self] in
            guard let self, self.allowedDelivery == delivery else { return }
            self.onFrame?(frame)
        }
    }

    /// 避免采集器活着但无输出时永远展示过期速度；超时后恢复采样基线。
    private func armWatchdog(token: Int) {
        watchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.failed("网络统计暂时无响应，正在重试")
        }
        watchdog = work
        queue.asyncAfter(deadline: .now() + Double(max(10, (request?.interval ?? 2) * 4)), execute: work)
    }

    /// 失败时停止旧进程，最多每 30 秒重试一次；错误不会显示成 0 B/s。
    private func failed(_ message: String) {
        stopLocked()
        failures += 1
        logger.error("\(message, privacy: .public)")
        report(message)
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token, self.request != nil else { return }
            self.launchLocked()
        }
        retry = work
        queue.asyncAfter(deadline: .now() + min(30, pow(2, Double(min(failures, 5)))), execute: work)
    }

    /// 更新采集状态，保持对 AppKit 的访问全部位于主线程。
    private func report(_ message: String?) {
        let delivery = currentDelivery
        DispatchQueue.main.async { [weak self] in
            guard let self, self.allowedDelivery == delivery else { return }
            self.onStatus?(message)
        }
    }

    /// 同步取消旧回调，并以 SIGTERM 结束本程序创建的子进程，不影响任何其他 nettop。
    private func stopLocked() {
        generation += 1
        flush?.cancel(); watchdog?.cancel(); retry?.cancel()
        flush = nil; watchdog = nil; retry = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        if let child = process, child.isRunning {
            child.terminate()
            // 包装器在 0.5 秒内结束它持有的 nettop，再退出；等待避免更新时遗留采集进程。
            child.waitUntilExit()
        }
        try? outputPipe?.fileHandleForReading.close()
        try? inputPipe?.fileHandleForWriting.close()
        try? inputPipe?.fileHandleForReading.close()
        process = nil; outputPipe = nil; inputPipe = nil
    }
}
