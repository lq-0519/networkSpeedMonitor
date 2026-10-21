import Foundation
import IOKit
import IOKit.ps

/// 一次电源快照；功率均以瓦为单位，nil 表示系统未提供有效数据，不能当作零。
struct PowerSnapshot: Codable {
    /// 系统报告的电量百分比；不把百分比容量误当成毫安时。
    let percent: Int?
    /// 当前是否连接外部电源，与电池净功率的充放电方向分别表达。
    let external: Bool
    /// 系统充电标志，仅用于状态描述，不据此推断电池功率。
    let charging: Bool
    /// 满电状态优先于充电时间，避免把已充满显示成正在估算。
    let charged: Bool
    /// 系统是否正在执行优化充电，暂停时不显示虚假的充满倒计时。
    let optimized: Bool
    /// 进入 Mac 的实际输入功率，不等同于适配器协商能力。
    let inputWatts: Double?
    /// 系统负载功率；遥测缺失时可由有效电池功率推算，并标注估算。
    let systemWatts: Double?
    /// 电池净功率，正值充入、负值放出；优先使用同组遥测，避免混合不同采样时刻。
    let batteryWatts: Double?
    /// 适配器报告的标称或协商功率，与实际输入功率独立展示。
    let adapterWatts: Double?
    /// 当前供电模式下的系统剩余时间估算，单位为分钟；负值和哨兵值不会保留。
    let minutes: Int?
    /// 当前满充容量相对设计容量的估算百分比，不冒充系统设置的校准健康度。
    let health: Int?
    /// 系统报告的电池循环次数。
    let cycles: Int?
    /// 驱动的最近更新时间；用于提示数据年龄以及剔除过期功率。
    let updatedAt: Date?
    /// 功率来自电压乘电流或收支推算时为 true，界面明确标记近似值。
    let estimated: Bool
}

/// 直接读取 IOKit 电源数据，不启动 ioreg、powermetrics 或管理员辅助服务。
enum PowerReader {
    /// 合并公开电源状态与只读电池遥测；不支持的机型返回 nil，字段缺失则逐项降级。
    static func read() -> PowerSnapshot? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let raw = properties?.takeRetainedValue() as? [String: Any] else { return nil }
        var source: [String: Any] = [:]
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for handle in list {
                if let description = IOPSGetPowerSourceDescription(info, handle)?.takeUnretainedValue() as? [String: Any],
                   description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType {
                    source = description; break
                }
            }
        }
        return decode(raw: raw, source: source, now: Date())
    }

    /// 解析同一帧驱动属性与系统电源描述；时间参数用于拒绝过期数据，亦可独立验证充放电边界。
    static func decode(raw: [String: Any], source: [String: Any], now: Date) -> PowerSnapshot {
        let external = (raw["ExternalConnected"] as? Bool) ?? (source[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
        let charging = (source[kIOPSIsChargingKey] as? Bool) ?? (raw["IsCharging"] as? Bool) ?? false
        let charged = (source[kIOPSIsChargedKey] as? Bool) ?? (raw["FullyCharged"] as? Bool) ?? false
        let optimized = (source["Optimized Battery Charging Engaged"] as? NSNumber)?.boolValue ?? false
        let capacity = number(source[kIOPSCurrentCapacityKey]) ?? number(raw["CurrentCapacity"])
        let maximum = number(source[kIOPSMaxCapacityKey]) ?? number(raw["MaxCapacity"])
        let percent = capacity.flatMap { current in
            maximum.flatMap { max in max > 0 ? Int(min(100, Swift.max(0, current / max * 100)).rounded()) : nil }
        }
        let updated = number(raw["UpdateTime"]).map { Date(timeIntervalSince1970: $0) }
        let age = updated.map { now.timeIntervalSince($0) }
        let fresh = age.map { $0 >= -5 && $0 <= 120 } ?? true
        let telemetry = raw["PowerTelemetryData"] as? [String: Any] ?? [:]
        var input = external && fresh ? watts(telemetry["SystemPowerIn"]) : nil
        var load: Double?, battery: Double?
        var estimated = false
        if fresh, let measuredInput = watts(telemetry["SystemPowerIn"]),
           let measuredLoad = watts(telemetry["SystemLoad"]),
           let measuredBattery = watts(telemetry["BatteryPower"], signed: true),
           abs(measuredInput - measuredLoad - measuredBattery) <= max(0.05, measuredInput * 0.02),
           external || (measuredInput < 0.1 && measuredBattery <= 0) {
            load = measuredLoad; battery = measuredBattery
        } else if fresh, let voltage = number(raw["Voltage"]), voltage > 0, voltage < 30000,
                  let current = (raw["InstantAmperage"] as? NSNumber) ?? (raw["Amperage"] as? NSNumber) {
            // 某些驱动将负电流作为无符号 32/64 位整数输出，必须恢复符号再计算方向。
            let rawCurrent = current.int64Value
            let signedCurrent = rawCurrent > Int64(Int32.max) ? Int64(Int32(truncatingIfNeeded: rawCurrent)) : rawCurrent
            if signedCurrent > -30000 && signedCurrent < 30000 {
                battery = voltage * Double(signedCurrent) / 1_000_000
                if let input, let battery { load = max(0, input - battery) }
                else if !external, let battery, battery <= 0 { load = -battery }
                estimated = true
            }
        }
        if !external { input = nil }
        let adapter = raw["AdapterDetails"] as? [String: Any] ?? [:]
        let batteryData = raw["BatteryData"] as? [String: Any] ?? [:]
        let full = number(raw["AppleRawMaxCapacity"]) ?? number(batteryData["FullChargeCapacity"])
        let design = number(raw["DesignCapacity"]) ?? number(batteryData["DesignCapacity"])
        let health = full.flatMap { capacity in
            design.flatMap { size in size > 0 ? Int(min(100, max(0, capacity / size * 100)).rounded()) : nil }
        }
        let remaining = number(source[external ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey])
        let minutes = remaining.flatMap { $0 > 0 && $0 < 65535 ? Int($0) : nil }
        return PowerSnapshot(percent: percent, external: external, charging: charging, charged: charged,
            optimized: optimized, inputWatts: input, systemWatts: load, batteryWatts: battery,
            adapterWatts: external ? number(adapter["Watts"]).flatMap { $0 > 0 ? $0 : nil } : nil,
            minutes: external && (!charging || charged || optimized) ? nil : minutes,
            health: health, cycles: number(raw["CycleCount"]).flatMap { $0 >= 0 ? Int($0) : nil },
            updatedAt: updated, estimated: estimated)
    }

    /// 只接受有限数值，避免损坏的驱动字段进入 UI 或功率计算。
    private static func number(_ value: Any?) -> Double? {
        guard let result = (value as? NSNumber)?.doubleValue, result.isFinite else { return nil }
        return result
    }

    /// 将遥测毫瓦换算为瓦并检查合理范围；仅电池净功率允许负值。
    private static func watts(_ value: Any?, signed: Bool = false) -> Double? {
        guard let raw = number(value), abs(raw) < 500_000, signed || raw >= 0 else { return nil }
        return raw / 1000
    }
}

/// 弹窗专用的电源与风扇低频采样模型；关闭弹窗后取消定时器，迟到的回调无法重新发布旧数据。
final class PowerMonitor {
    /// 真实可见采样结果同时交给历史记录，后台路径不重复读取同一电源与风扇。
    var onSample: ((PowerSnapshot?, FanSnapshot?, Date, Int) -> Void)?
    /// 主线程通知，仅更新电源与风扇区域，不触发菜单栏或其他排行重绘。
    var onUpdate: (() -> Void)?
    /// 最近一轮快照，nil 表示无内置电池或数据不可用。
    private(set) var snapshot: PowerSnapshot?
    /// 与电源同轮读取的风扇快照；nil 表示 SMC 接口不可用，空数组表示无风扇。
    private(set) var fanSnapshot: FanSnapshot?
    /// 与网络和 CPU 共用的间隔；面板隐藏时只读取配置，不启动采样。
    var interval: Int { SamplingPreferences.interval }
    /// 主线程上的可见状态，重复设置不会重建计时器。
    private var visible = false
    /// 每次打开或关闭都会更新的世代，阻止旧采样覆盖新状态。
    private var epoch = UUID()
    /// 串行低优先级读取，IOKit 工作不占用 UI 线程。
    private let queue = DispatchQueue(label: "com.local.NetworkSpeedMonitor.power", qos: .utility)
    /// 仅在弹窗打开期间存在的计时器，周期取自统一采样偏好。
    private var timer: DispatchSourceTimer?

    /// 打开立即采样，随后按统一周期读取；关闭立即失效并清理队列中的定时器。
    func setVisible(_ value: Bool) {
        guard visible != value else { return }
        visible = value; restart()
    }

    /// 设置修改时重建当前可见采样并失效旧回调；面板隐藏时仅取消旧任务，不创建计时器。
    func restart() {
        epoch = UUID(); snapshot = nil; fanSnapshot = nil
        let current = epoch
        let enabled = visible, seconds = interval
        queue.async { [self] in
            timer?.cancel(); timer = nil
            guard enabled else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .seconds(seconds), leeway: .milliseconds(150))
            source.setEventHandler { [weak self] in
                let sampledAt = Date()
                let snapshot = PowerReader.read()
                let fanSnapshot = FanReader.read()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.visible, self.epoch == current else { return }
                    self.onSample?(snapshot, fanSnapshot, sampledAt, seconds)
                    self.snapshot = snapshot; self.fanSnapshot = fanSnapshot; self.onUpdate?()
                }
            }
            timer = source; source.resume()
        }
    }

    /// 退出时同步取消采样，不保留进程、连接或后台工作。
    func shutdown() {
        visible = false; epoch = UUID()
        queue.sync { timer?.cancel(); timer = nil }
    }
}
