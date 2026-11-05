import Foundation
import Darwin
import IOKit

/// 可识别的独立部件类别；声明顺序仅用于同功率时稳定排序，不代表显示顺序。
enum PowerComponent: String, CaseIterable {
    /// 处理器整体能耗模型，不累加重复的逐核或逐簇计数。
    case cpu
    /// 图形处理器整体能耗模型。
    case gpu
    /// DRAM、DCS 与 AMCC 内存相关能耗模型。
    case memory
    /// 内置屏幕背光的只读 SMC 功率。
    case display
    /// Apple Neural Engine 能耗模型。
    case ane
    /// AVE 视频编码引擎，合并同类编号通道，不与 GPU 聚合计数混用。
    case videoEncode
    /// AVD 视频解码引擎，仅在系统提供对应能耗通道时参与展示。
    case videoDecode
    /// ISP 摄像头图像信号处理器，不把摄像头开启状态换算为功率。
    case camera
    /// MSR 图像缩放引擎，仅表示独立模型报告的能耗。
    case imageScale
    /// 独立 ProRes 编解码引擎，缺失时不从其他媒体通道猜测。
    case proRes
    /// JPG 静态图像编解码引擎，不与视频编解码合并累计。
    case jpeg
    /// 整机扣除已读取部件后的估算余量，不对应独立传感器。
    case other

    /// 常驻核心类别即使未知也作为展示候选；可选媒体通道必须实际存在才加入。
    static let coreComponents: [PowerComponent] = [.cpu, .gpu, .memory, .display, .ane]

    /// 原生图形和辅助功能共用短名称，避免把硬件键名放入用户界面。
    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return "内存"
        case .display: return "屏幕"
        case .ane: return "ANE"
        case .videoEncode: return "视频编码"
        case .videoDecode: return "视频解码"
        case .camera: return "摄像头"
        case .imageScale: return "图像缩放"
        case .proRes: return "ProRes"
        case .jpeg: return "JPEG"
        case .other: return "其他"
        }
    }
}

/// 一轮部件读取的结果，仅在内存保存；缺失键不插入字典，真实零值仍保留。
struct PowerComponentSnapshot {
    /// 部件功率，单位瓦；能耗模型是本轮间隔平均值，屏幕为同轮背光读数。
    let watts: [PowerComponent: Double]
    /// 首次读取只建立累计能耗基线，界面据此显示采集中而不是零功率。
    let measuring: Bool
    /// 实际订阅成功或直接读到的部件集合，用于区分可选硬件缺失与本轮读数未知。
    let availableComponents: Set<PowerComponent>
}

/// 可见弹窗专用的能耗读取器；只订阅所需 IOReport 通道，不启动子进程或申请管理员权限。
final class PowerComponentReader {
    /// IOReport 按组枚举通道的 C ABI，只在本次弹窗首次采样时调用。
    private typealias ChannelsFunction = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    /// IOReport 订阅指定通道，并返回系统实际接受的通道集合。
    private typealias SubscribeFunction = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary,
        UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> Unmanaged<CFTypeRef>?
    /// 读取订阅通道的累计能耗，返回值按 Create 规则由调用者释放。
    private typealias SamplesFunction = @convention(c) (CFTypeRef, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    /// 计算两次有效累计计数的差分，不依赖预设采样周期。
    private typealias DeltaFunction = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    /// 通道名称和单位字符串为借用引用，不能按 Create 规则释放。
    private typealias StringFunction = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    /// Energy Model 的第零个整数元素是该通道的能耗计数。
    private typealias ValueFunction = @convention(c) (CFDictionary, Int32) -> Int64
    /// 通道与驱动身份的借用读取，低三十二位报告键用于消除同一计数器的索引别名。
    private typealias IdentifierFunction = @convention(c) (CFDictionary) -> UInt64

    /// 动态符号集合；系统没有这些私有接口时整组降级，不调用空函数地址。
    private struct API {
        /// 按 Energy Model 组发现通道。
        let channels: ChannelsFunction
        /// 订阅过滤后的通道集合。
        let subscribe: SubscribeFunction
        /// 读取当前累计能耗。
        let samples: SamplesFunction
        /// 产生两个样本之间的能耗差分。
        let delta: DeltaFunction
        /// 读取通道名称。
        let name: StringFunction
        /// 读取能耗单位。
        let unit: StringFunction
        /// 区分旧 Energy Model 与 macOS 27 的 CLPC 聚合计数，避免同一部件重复相加。
        let group: StringFunction
        /// 获取通道的完整报告身份。
        let identifier: IdentifierFunction
        /// 获取通道所属的当前驱动注册身份。
        let driver: IdentifierFunction
        /// 读取整数能耗差分。
        let value: ValueFunction
    }

    /// 首次真实采集才加载系统库；只保留函数地址，没有计时器、线程或后台采样工作。
    private static let api: API? = {
        guard let library = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW | RTLD_LOCAL) else { return nil }
        guard let channels = symbol("IOReportCopyChannelsInGroup", in: library, as: ChannelsFunction.self),
              let subscribe = symbol("IOReportCreateSubscription", in: library, as: SubscribeFunction.self),
              let samples = symbol("IOReportCreateSamples", in: library, as: SamplesFunction.self),
              let delta = symbol("IOReportCreateSamplesDelta", in: library, as: DeltaFunction.self),
              let name = symbol("IOReportChannelGetChannelName", in: library, as: StringFunction.self),
              let unit = symbol("IOReportChannelGetUnitLabel", in: library, as: StringFunction.self),
              let group = symbol("IOReportChannelGetGroup", in: library, as: StringFunction.self),
              let identifier = symbol("IOReportChannelGetChannelID", in: library, as: IdentifierFunction.self),
              let driver = symbol("IOReportChannelGetDriverID", in: library, as: IdentifierFunction.self),
              let value = symbol("IOReportSimpleGetIntegerValue", in: library, as: ValueFunction.self) else {
            dlclose(library)
            return nil
        }
        return API(channels: channels, subscribe: subscribe, samples: samples, delta: delta,
                   name: name, unit: unit, group: group, identifier: identifier, driver: driver, value: value)
    }()

    /// 固件已核实的 macOS 27 聚合报告键；固定来源为 macmon 39e98aa73e49256e6281b2a228f6ef3499ae3209/src/clpc.rs。
    /// 只在系统主版本及驱动 Bundle ID 同时匹配时启用，不推测未来系统或未知芯片的索引。
    private static let clpcKeys: [String: (cpu: UInt32, gpu: UInt32, ane: UInt32)] = [
        "com.apple.driver.AppleT6000CLPCv3": (0x47479059, 0x4519bf1e, 0x9aaa17f8),
        "com.apple.driver.AppleT6002CLPC": (0xb501816b, 0x9e2c3e8b, 0x14d5a574),
        "com.apple.driver.AppleT6020CLPC": (0xe301cd75, 0x8f34cc7a, 0x7415fb0f),
        "com.apple.driver.AppleT6022CLPC": (0x76f5fd21, 0x90624499, 0x3c097307),
        "com.apple.driver.AppleT6030CLPC": (0xbe03a01a, 0x472d6c9c, 0xb8990c38),
        "com.apple.driver.AppleT6031CLPC": (0xd81e0084, 0x1085f98b, 0x313a3be1),
        "com.apple.driver.AppleT6032CLPC": (0xf4a21308, 0x85e80513, 0x63dc8e25),
        "com.apple.driver.AppleT6041CLPC": (0x263cf1f0, 0x22e4cf59, 0x7849fb5c),
        "com.apple.driver.AppleT6050CLPC": (0xd3ab60bb, 0x27cd4ce5, 0x8c0f1c59),
        "com.apple.driver.AppleT6050dCLPC": (0x18b3010e, 0xedeca11a, 0x188bd883),
        "com.apple.driver.AppleT8103CLPCv3": (0x2cdd31f2, 0x21becf42, 0x0667fb81),
        "com.apple.driver.AppleT8112CLPC": (0xb5435137, 0x638d9d52, 0xea089c36),
        "com.apple.driver.AppleT8122CLPC": (0x54b51c99, 0xce2dd9dc, 0x960afe2f),
        "com.apple.driver.AppleT8132CLPC": (0x4a854d94, 0x3b3e3b79, 0x1ff4a9ec),
        "com.apple.driver.AppleT8140CLPC": (0x9bf54436, 0xef70589c, 0x569d941b),
        "com.apple.driver.AppleT8142CLPC": (0x43708744, 0x6a010933, 0xbc5efdf0),
        "com.apple.driver.AppleT8152CLPC": (0x485d4bfc, 0x11784654, 0x9380c6bb)
    ]

    /// 同一驱动内的报告键唯一标识计数器，替代不同表索引下的重复通道身份。
    private struct ChannelKey: Hashable {
        /// 当前 IORegistry 服务的注册身份，不使用跨重启缓存值。
        let driver: UInt64
        /// 报告 ID 的低三十二位，表索引不同仍视为同一计数器。
        let report: UInt32
    }

    /// 本次可见生命周期的订阅，读取器释放时由 ARC 同步释放 CF 引用。
    private var subscription: CFTypeRef?
    /// 系统接受的少量通道，与订阅一起释放。
    private var channels: CFMutableDictionary?
    /// 上一帧累计能耗与单调时间；关闭、失败或供电模式变化后不跨区间差分。
    private var previous: (sample: CFDictionary, uptime: TimeInterval)?
    /// 每次打开最多尝试一次订阅，不支持的机型不反复探测。
    private var attemptedSubscription = false
    /// 用于切断插拔电源前后的差分窗口，不将两种供电状态混合展示。
    private var previousExternal: Bool?
    /// 本次订阅实际支持的类别，关闭读取器时连同订阅释放。
    private var availableComponents = Set<PowerComponent>()

    /// 解析动态 C 函数，仅在符号存在时转换已知 ABI，缺失时不产生非法调用。
    private static func symbol<T>(_ name: String, in library: UnsafeMutableRawPointer, as type: T.Type) -> T? {
        guard let address = dlsym(library, name) else { return nil }
        return unsafeBitCast(address, to: type)
    }

    /// 仅接受整体 CPU/GPU、内存及已知引擎的编号通道，不订阅逐核重复项、预算或驻留时间。
    private static func component(for name: String) -> PowerComponent? {
        if name == "CPU Energy" || name.hasSuffix(" CPU Energy") { return .cpu }
        if name == "GPU Energy" || name.hasSuffix(" GPU Energy") { return .gpu }
        let prefixes: [(String, PowerComponent)] = [
            ("DRAM", .memory), ("DCS", .memory), ("AMCC", .memory), ("ANE", .ane),
            ("AVE", .videoEncode), ("AVD", .videoDecode), ("ISP", .camera),
            ("MSR", .imageScale), ("PRORES", .proRes), ("JPG", .jpeg)
        ]
        for (prefix, component) in prefixes {
            guard name.hasPrefix(prefix),
                  name.dropFirst(prefix.count).allSatisfy({ $0.isNumber || $0 == "_" }) else { continue }
            return component
        }
        return nil
    }

    /// 为已知 macOS 27 驱动构造三个聚合能耗描述；读取注册信息只发生在本次打开的订阅阶段。
    /// nJ 单位和 simple/power/one-element 格式与已核实 ABI 一致，CPU/GPU/ANE 不包含内存的替代估算。
    private static func clpcChannels() -> [NSDictionary] {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27 else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleCLPC"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [NSDictionary] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            var driver: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &driver) == KERN_SUCCESS,
                  let bundle = IORegistryEntryCreateCFProperty(service, "CFBundleIdentifier" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String,
                  let keys = clpcKeys[bundle] else { continue }
            let reports: [(UInt32, UInt32, String)] = [
                (16, keys.cpu, "CPU Energy"), (25, keys.gpu, "GPU Energy"), (24, keys.ane, "ANE")
            ]
            for (index, key, name) in reports {
                let identifier = UInt64(index) << 32 | UInt64(key)
                result.append(NSMutableDictionary(dictionary: [
                    "DriverID": NSNumber(value: driver), "DriverName": "AppleCLPC",
                    "IOReportGroupName": "CLPC", "IOReportSubGroupName": "Energy Counters",
                    "IOReportChannelInfo": ["IOReportChannelUnit": NSNumber(value: UInt64(3) << 56 | UInt64(118) << 32)],
                    "LegendChannel": [NSNumber(value: identifier),
                        NSNumber(value: UInt64(1) | UInt64(2) << 16 | UInt64(1) << 32), name]
                ]))
            }
        }
        return result
    }

    /// 过滤通道后建立一次订阅；失败保留不可用状态，直到下次打开弹窗重新创建读取器。
    private func prepare(_ api: API) {
        guard !attemptedSubscription else { return }
        attemptedSubscription = true
        let dictionary = api.channels("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue()
        let entries = dictionary.flatMap { ($0 as NSDictionary)["IOReportChannels"] as? [NSDictionary] } ?? []
        var selected = entries.filter { entry in
            guard let name = api.name(entry as CFDictionary)?.takeUnretainedValue() as String? else { return false }
            return Self.component(for: name) != nil
        }
        selected.append(contentsOf: Self.clpcChannels())
        var seen = Set<ChannelKey>()
        selected = selected.filter {
            seen.insert(ChannelKey(driver: api.driver($0 as CFDictionary),
                                   report: UInt32(truncatingIfNeeded: api.identifier($0 as CFDictionary)))).inserted
        }
        guard !selected.isEmpty else { return }
        let filtered = dictionary.map { NSMutableDictionary(dictionary: $0 as NSDictionary) } ?? NSMutableDictionary()
        filtered["IOReportChannels"] = selected
        var accepted: Unmanaged<CFMutableDictionary>?
        let createdSubscription = api.subscribe(nil, filtered as CFMutableDictionary, &accepted, 0, nil)?.takeRetainedValue()
        let acceptedChannels = accepted?.takeRetainedValue()
        guard let subscription = createdSubscription, let channels = acceptedChannels else { return }
        self.subscription = subscription; self.channels = channels
        let acceptedEntries = (channels as NSDictionary)["IOReportChannels"] as? [NSDictionary] ?? []
        availableComponents = Set(acceptedEntries.compactMap {
            guard let name = api.name($0 as CFDictionary)?.takeUnretainedValue() as String? else { return nil }
            return Self.component(for: name)
        })
    }

    /// 统一携带订阅覆盖范围，直接读到的屏幕值也计入可用类别；未知读数仍不写入瓦数字典。
    private func snapshot(watts: [PowerComponent: Double], measuring: Bool) -> PowerComponentSnapshot {
        PowerComponentSnapshot(watts: watts, measuring: measuring,
                               availableComponents: availableComponents.union(watts.keys))
    }

    /// 同轮读取背光及能耗模型，真实间隔超出三十秒时重建基线；没有字段的部件保持未知。
    func sample(smc: SMCReadConnection?, external: Bool?) -> PowerComponentSnapshot {
        var watts: [PowerComponent: Double] = [:]
        if let display = smc?.readNumber("PDBR"), display.isFinite, display >= 0, display < 200 {
            watts[.display] = display
        }
        if previousExternal != external { previous = nil }
        previousExternal = external
        guard let api = Self.api else { return snapshot(watts: watts, measuring: false) }
        prepare(api)
        guard let subscription, let channels else { return snapshot(watts: watts, measuring: false) }
        guard let sample = api.samples(subscription, channels, nil)?.takeRetainedValue() else {
            previous = nil
            return snapshot(watts: watts, measuring: false)
        }
        let uptime = ProcessInfo.processInfo.systemUptime
        let old = previous
        previous = (sample, uptime)
        guard let old else { return snapshot(watts: watts, measuring: true) }
        let seconds = uptime - old.uptime
        guard seconds > 0.05, seconds <= 30,
              let delta = api.delta(old.sample, sample, nil)?.takeRetainedValue(),
              let entries = (delta as NSDictionary)["IOReportChannels"] as? [NSDictionary] else {
            return snapshot(watts: watts, measuring: true)
        }
        var modeled: [PowerComponent: Double] = [:], clpc: [PowerComponent: Double] = [:]
        var invalidModel = Set<PowerComponent>(), invalidCLPC = Set<PowerComponent>()
        for entry in entries {
            let channel = entry as CFDictionary
            guard let name = api.name(channel)?.takeUnretainedValue() as String?,
                  let component = Self.component(for: name) else { continue }
            let isCLPC = api.group(channel)?.takeUnretainedValue() as String? == "CLPC"
            guard let unit = api.unit(channel)?.takeUnretainedValue() as String? else {
                if isCLPC { invalidCLPC.insert(component) } else { invalidModel.insert(component) }
                continue
            }
            let value = api.value(channel, 0)
            guard value >= 0 else {
                if isCLPC { invalidCLPC.insert(component) } else { invalidModel.insert(component) }
                continue
            }
            let divisor: Double
            switch unit.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "J": divisor = 1
            case "mJ": divisor = 1_000
            case "uJ", "µJ": divisor = 1_000_000
            case "nJ": divisor = 1_000_000_000
            default:
                if isCLPC { invalidCLPC.insert(component) } else { invalidModel.insert(component) }
                continue
            }
            let power = Double(value) / divisor / seconds
            guard power.isFinite, power >= 0, power < 500 else {
                if isCLPC { invalidCLPC.insert(component) } else { invalidModel.insert(component) }
                continue
            }
            if isCLPC { clpc[component, default: 0] += power }
            else { modeled[component, default: 0] += power }
        }
        for component in invalidModel { modeled.removeValue(forKey: component) }
        for component in invalidCLPC { clpc.removeValue(forKey: component) }
        // 持续供电的 CPU/内存整组零差分不能证明零耗电；旧计数停滞时保留未知，非活动引擎仍允许真实零值。
        for component in [PowerComponent.cpu, .memory] where modeled[component] == 0 {
            modeled.removeValue(forKey: component)
        }
        if clpc[.cpu] == 0 { clpc.removeValue(forKey: .cpu) }
        for (component, power) in modeled where power < 500 { watts[component] = power }
        // 新旧来源只能择一，优先已匹配固件的 CLPC；无效或拒绝订阅时仍保留可用的旧模型。
        for (component, power) in clpc where power < 500 { watts[component] = power }
        return snapshot(watts: watts, measuring: false)
    }
}
