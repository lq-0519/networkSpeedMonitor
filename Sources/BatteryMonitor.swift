import Foundation
import IOKit.ps

/// 菜单栏专用的轻量电池快照；仅包含公开电源描述，不读取功率、风扇或电量历史。
struct BatteryStatus: Equatable {
    /// 系统当前电量百分比；未知值不伪装成零电量。
    let percent: Int?
    /// 系统报告的当前供电模式，决定使用充满时间还是剩余续航。
    let external: Bool
    /// 系统是否报告正在充电，不根据电量阈值或外接电源自行推断。
    let charging: Bool
    /// 仅采用系统的已充满标志，不读取或推断用户、第三方软件设定的充电上限。
    let charged: Bool
    /// 系统优化充电暂停标志，缺失时保留普通未充电状态。
    let optimized: Bool
    /// 当前供电模式对应的有效预计分钟数；未知和哨兵值保持 nil。
    let minutes: Int?

    /// 上行固定带百分号；无法读取电量时使用破折号。
    var percentageText: String { percent.map { "\($0)%" } ?? "—" }

    /// 闪电仅表示系统正在向电池充电；接通电源或已充满本身不显示闪电。
    var showsLightning: Bool { external && charging && !charged && !optimized }

    /// 下行使用小时:分钟格式；只有外接电源且系统明确已充满时显示“已充满”。
    var secondaryText: String {
        if external {
            if charged { return "已充满" }
            if optimized { return "已暂停" }
            if !charging { return "未充电" }
        }
        return minutes.map { "\($0 / 60):" + String(format: "%02d", $0 % 60) } ?? "估算中"
    }

    /// 悬停和辅助功能补充时间含义，避免把预计续航与充满所需时间混淆。
    var detailText: String {
        let state: String
        if !external { state = "电池供电，预计续航 \(secondaryText)" }
        else if charged || optimized || !charging { state = secondaryText }
        else { state = "充电中，预计充满 \(secondaryText)" }
        return "电池 \(percentageText)，\(state)"
    }
}

/// 通过公开 IOPowerSources 接口读取内置电池；不启动子进程或访问原始硬件遥测。
enum BatteryReader {
    /// 仅返回实际存在的内置电池，排除 UPS、外设和其他电源描述。
    static func read() -> BatteryStatus? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for handle in list {
            guard let source = IOPSGetPowerSourceDescription(info, handle)?.takeUnretainedValue() as? [String: Any],
                  source[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  source[kIOPSIsPresentKey] as? Bool != false else { continue }
            return decode(source)
        }
        return nil
    }

    /// 按系统容量口径换算百分比，并只接受当前供电模式下有效的正分钟数。
    static func decode(_ source: [String: Any]) -> BatteryStatus {
        let external = source[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        let charging = source[kIOPSIsChargingKey] as? Bool ?? false
        let charged = source[kIOPSIsChargedKey] as? Bool ?? false
        let optimized = source["Optimized Battery Charging Engaged"] as? Bool ?? false
        let capacity = (source[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue
        let maximum = (source[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue
        var percent: Int?
        if let capacity, let maximum, capacity.isFinite, maximum.isFinite, capacity >= 0, maximum > 0 {
            percent = Int(min(100, max(0, capacity / maximum * 100)).rounded())
        }
        let rawMinutes = (source[external ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? NSNumber)?.doubleValue
        let minutes = rawMinutes.flatMap { $0.isFinite && $0 > 0 && $0 < 65535 ? Int($0) : nil }
        return BatteryStatus(percent: percent, external: external, charging: charging, charged: charged,
                             optimized: optimized, minutes: external && (!charging || charged || optimized) ? nil : minutes)
    }
}

/// 菜单栏电池仅随系统电源通知更新；隐藏、锁屏或休眠时移除观察并拒绝迟到的快照。
final class BatteryMonitor {
    /// 主线程通知；只在电池快照变化或生命周期失效时触发菜单栏刷新。
    var onUpdate: (() -> Void)?
    /// 最近一次有效快照；无电池、暂停或读取失败时为 nil。
    private(set) var snapshot: BatteryStatus?
    /// 用户是否选择显示电池，不影响弹窗电源模块的独立采样。
    private var enabled = false
    /// 复用应用统一的锁屏、屏幕和系统睡眠暂停状态。
    private var suspended = false
    /// 主线程 RunLoop 上注册的系统电源变化通知。
    private var notificationSource: CFRunLoopSource?
    /// 极少数通知接口创建失败时才使用一分钟兜底，不参与正常刷新。
    private var fallbackTimer: Timer?
    /// 每次启停更新，防止休眠前或隐藏前的读取覆盖当前状态。
    private var epoch = UUID()
    /// 将 IOKit 读取移出 UI 线程，串行执行且不与功率、风扇采样绑定。
    private let queue = DispatchQueue(label: "com.local.NetworkSpeedMonitor.battery", qos: .utility)
    /// 同一观察世代最多排队一个读取，避免通知集中到达时堆积任务。
    private var readPending = false
    /// 读取期间若有新通知，仅在该轮完成后追加一次最新读取。
    private var readAgain = false

    /// 组件选择变化后立即启停观察，重复设置不重新注册或清空当前电量。
    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value; configure()
    }

    /// 暂停时失效旧读取；恢复后立即读一次，不依赖睡眠期间是否丢失过系统通知。
    func setSuspended(_ value: Bool) {
        guard suspended != value else { return }
        suspended = value; configure()
    }

    /// 在主线程重建系统通知，并在正常启用时立即请求电池快照。
    private func configure() {
        removeObservation()
        epoch = UUID(); readPending = false; readAgain = false; snapshot = nil
        onUpdate?()
        guard enabled && !suspended else { return }
        notificationSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue().refresh()
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let notificationSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), notificationSource, .commonModes)
        } else {
            fallbackTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
            fallbackTimer?.tolerance = 5
        }
        refresh()
    }

    /// 合并密集通知，后台读取完成后仅向同一世代发布变化后的快照。
    private func refresh() {
        guard enabled && !suspended else { return }
        guard !readPending else { readAgain = true; return }
        readPending = true
        let current = epoch
        queue.async { [weak self] in
            let value = BatteryReader.read()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.epoch == current, self.enabled, !self.suspended else { return }
                self.readPending = false
                if self.snapshot != value { self.snapshot = value; self.onUpdate?() }
                if self.readAgain { self.readAgain = false; self.refresh() }
            }
        }
    }

    /// 先移除 RunLoop 来源再失效回调，确保释放对象后系统不再使用其非持有指针。
    private func removeObservation() {
        fallbackTimer?.invalidate(); fallbackTimer = nil
        if let notificationSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), notificationSource, .commonModes)
            CFRunLoopSourceInvalidate(notificationSource)
        }
        notificationSource = nil
    }

    /// 退出时同步停止通知和兜底计时器，已排队快照因世代变化无法回写。
    func shutdown() {
        enabled = false; epoch = UUID(); removeObservation(); snapshot = nil
    }

    /// 即使诊断调用方未显式 shutdown，也不遗留指向已释放对象的电源通知。
    deinit { removeObservation() }
}
