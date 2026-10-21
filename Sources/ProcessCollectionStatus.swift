import Foundation

/// 三类进程排行共享的采集状态；暂时延迟、实际权限失败与协议不兼容分别传递，界面不根据文件存在猜测错误。
enum ProcessCollectionStatus {
    /// 正在建立首轮或恢复后的差分基线。
    case sampling
    /// 已成功接收本轮进程快照。
    case live
    /// 面板关闭、锁屏或休眠后停止采集并释放旧结果。
    case paused
    /// 请求仍在等待或已安排重试；保留最近成功的结果并标注过期。
    case retrying(String)
    /// 实际返回的进程快照没有管理员身份，或磁盘排行尚未启用完整采集。
    case authorizationRequired
    /// 实际快照的版本、格式、当前模块所需字段或服务签名不兼容。
    case updateRequired

    /// 可用于空列表和悬停说明的完整状态，不将等待超时描述成授权丢失。
    var message: String {
        switch self {
        case .sampling: return "正在采样…"
        case .live: return "实时"
        case .paused: return "已暂停"
        case .retrying(let reason): return reason
        case .authorizationRequired: return "请授权系统进程采集"
        case .updateRequired: return "请更新管理员采集服务"
        }
    }

    /// 概览与列表表头使用的短状态；成功时由各模块补充实际权限与覆盖信息。
    var summary: String? {
        switch self {
        case .sampling: return "正在采样…"
        case .live: return nil
        case .paused: return "已暂停"
        case .retrying: return "采集延迟"
        case .authorizationRequired: return "需要授权"
        case .updateRequired: return "需要更新"
        }
    }

    /// 等待或重试只影响数据新鲜度，不清除最近已验证的权限、覆盖范围和排行。
    var preservesResult: Bool {
        if case .retrying = self { return true }
        return false
    }

    /// 授权按钮仅用于已确认的权限或兼容性问题，暂时超时不要求用户重新认证。
    var requiresAuthorization: Bool {
        switch self {
        case .authorizationRequired, .updateRequired: return true
        default: return false
        }
    }
}

/// 客户端对实际快照校验得到的错误；传输中断和超时仍由采集器按暂时故障恢复。
enum CPUServiceValidationError: Error {
    /// 服务返回的实际有效用户不是 root，必须重新启用完整采集。
    case authorizationRequired
    /// 服务返回的协议版本、JSON 格式或系统校验的签名不兼容，必须更新服务。
    case updateRequired

    /// 将确定的校验失败转换为共享状态，避免界面靠错误字符串判断权限。
    var status: ProcessCollectionStatus {
        switch self {
        case .authorizationRequired: return .authorizationRequired
        case .updateRequired: return .updateRequired
        }
    }
}

/// 管理员查询的有界等待与退避策略；复用现有采样定时器，不增加常驻重试计时器。
enum CPURequestTiming {
    /// 超过五秒先报告延迟，保留原请求，让迟到但有效的服务回复仍可恢复排行榜。
    static let delayedAfter: TimeInterval = 5

    /// 新连接包含按需启动和签名校验，覆盖高负载下已观察到的三十余秒启动延迟。
    static let startupTimeout: TimeInterval = 45

    /// 已返回过快照的连接给慢采样十五秒恢复机会，达到期限后才断开重连。
    static let sampleTimeout: TimeInterval = 15

    /// 连续失败按二、四、八、十五秒退避；成功后由调用方清零，避免服务故障时密集重连。
    static func retryDelay(after failures: Int) -> TimeInterval {
        switch failures {
        case ...1: return 2
        case 2: return 4
        case 3: return 8
        default: return 15
        }
    }
}
