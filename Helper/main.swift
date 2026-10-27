import Foundation
import Darwin

/// 按需启动的只读服务；没有界面、网络、文件写入或执行任意命令的接口。
final class CPUHelper: NSObject, NSXPCListenerDelegate, CPUServiceProtocol {
    /// 低优先级串行采集，优先减少查询成本，不持续与前台任务争夺 CPU。
    private let queue = DispatchQueue(label: CPUServiceIdentity.label, qos: .utility)
    /// 当前存活的连接数，修改仅在 queue 上执行。
    private var connections = 0
    /// 连续刷新期间复用进程路径缓存。
    private let reader = CPUProcessReader()
    /// 最近一次结果；限制重复请求造成的采集开销。
    private var cached: Data?
    /// 最近采样完成的单调时刻。
    private var lastSample: TimeInterval = 0
    /// 空闲退出的一次性任务，不创建额外周期定时器。
    private var idleExit: DispatchWorkItem?

    /// 校验客户端后仅导出只读协议；内核 XPC 签名要求还会逐条验证消息来源。
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(CPUServiceIdentity.clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: CPUServiceProtocol.self)
        connection.exportedObject = self
        queue.sync { connections += 1; idleExit?.cancel() }
        connection.invalidationHandler = { [weak self] in
            self?.queue.async { [weak self] in
                guard let self else { return }
                self.connections = max(0, self.connections - 1)
                if self.connections == 0 { self.armIdleExit() }
            }
        }
        connection.resume()
        return true
    }

    /// 返回当前计数器快照；失败只报告错误，不输出每帧日志或敏感进程信息。
    func readSnapshot(withReply reply: @escaping (Data?, String?) -> Void) {
        queue.async { [self] in
            let now = ProcessInfo.processInfo.systemUptime
            if let cached, now - lastSample < 0.5 { reply(cached, nil); return }
            do {
                let data = try JSONEncoder().encode(reader.snapshot())
                cached = data; lastSample = ProcessInfo.processInfo.systemUptime
                reply(data, nil)
            } catch { reply(nil, error.localizedDescription) }
        }
    }

    /// 关闭后立即释放排行缓存，空闲十秒退出，限制仅为再次展开而保留的后台内存。
    private func armIdleExit() {
        idleExit?.cancel()
        reader.reset(); cached = nil
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.connections == 0 else { return }
            exit(0)
        }
        idleExit = work
        queue.asyncAfter(deadline: .now() + 10, execute: work)
    }

    /// 安装服务可能会启动但没有客户端；此时同样尽快退出。
    func startIdleDeadline() { queue.async { [self] in armIdleExit() } }
}

// 有限诊断模式使用同一采集实现，不安装服务或更改权限。
if CommandLine.arguments.contains("--snapshot") {
    let data = try JSONEncoder().encode(CPUProcessReader().snapshot())
    FileHandle.standardOutput.write(data)
} else {
    guard geteuid() == 0 else { fputs("CPUHelper requires a system launchd service.\n", stderr); exit(1) }
    let helper = CPUHelper()
    let listener = NSXPCListener(machServiceName: CPUServiceIdentity.label)
    listener.setConnectionCodeSigningRequirement(CPUServiceIdentity.clientRequirement)
    listener.delegate = helper
    helper.startIdleDeadline()
    listener.resume()
    RunLoop.current.run()
}
