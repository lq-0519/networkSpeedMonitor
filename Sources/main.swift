import AppKit

// 诊断模式先于 GUI 启动，便于在无窗口环境验证采集并避免改变用户的登录项或偏好。
if CommandLine.arguments.contains("--self-check") {
    Diagnostics.selfCheck()
} else if CommandLine.arguments.contains("--power-history-diagnose") {
    // 单次只读查询系统已有历史，不启动实时电源、GUI 或任何后台采集器。
    var range = PowerHistoryRange.tenHours
    if let index = CommandLine.arguments.firstIndex(of: "--history-hours") {
        guard CommandLine.arguments.indices.contains(index + 1),
              let hours = Int(CommandLine.arguments[index + 1]), let selected = PowerHistoryRange(rawValue: hours) else {
            fputs("历史范围仅支持 1、10、24、168 小时。\n", stderr); exit(2)
        }
        range = selected
    }
    Diagnostics.readPowerHistory(range: range)
} else if CommandLine.arguments.contains("--upgrade-helper") {
    // 显式维护入口使用既有签名安装流程；密码仅在 macOS 认证窗口输入，不经过终端。
    do { try CPUPrivilege.install(); print("管理员 CPU / 内存 / 磁盘采集服务已更新。") }
    catch { fputs("管理员采集服务未更新：\(error.localizedDescription)\n", stderr); exit(1) }
} else if let index = CommandLine.arguments.firstIndex(of: "--memory-diagnose") {
    let value = CommandLine.arguments.indices.contains(index + 1) ? Double(CommandLine.arguments[index + 1]) : nil
    Diagnostics.sampleMemory(seconds: value ?? 12)
} else if let index = CommandLine.arguments.firstIndex(of: "--disk-diagnose") {
    let value = CommandLine.arguments.indices.contains(index + 1) ? Double(CommandLine.arguments[index + 1]) : nil
    Diagnostics.sampleDisk(seconds: value ?? 12)
} else if let index = CommandLine.arguments.firstIndex(of: "--power-diagnose") {
    let value = CommandLine.arguments.indices.contains(index + 1) ? Double(CommandLine.arguments[index + 1]) : nil
    Diagnostics.samplePower(seconds: value ?? 12)
} else if let index = CommandLine.arguments.firstIndex(of: "--fan-diagnose") {
    let value = CommandLine.arguments.indices.contains(index + 1) ? Double(CommandLine.arguments[index + 1]) : nil
    Diagnostics.sampleFans(seconds: value ?? 12)
} else if let index = CommandLine.arguments.firstIndex(of: "--cpu-diagnose") {
    let value = CommandLine.arguments.indices.contains(index + 1) ? Double(CommandLine.arguments[index + 1]) : nil
    Diagnostics.sampleCPU(seconds: value ?? 10, ranking: CommandLine.arguments.contains("--with-ranking"))
} else if let index = CommandLine.arguments.firstIndex(of: "--diagnose") {
    let value = CommandLine.arguments.indices.contains(index + 1) ? Double(CommandLine.arguments[index + 1]) : nil
    Diagnostics.sample(seconds: value ?? 10, ranking: CommandLine.arguments.contains("--with-ranking"))
} else {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
