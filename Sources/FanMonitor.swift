import Foundation
import IOKit

/// 单个物理风扇的一次读数；rpm 为 nil 表示该风扇存在，但本轮 SMC 数据不可用。
struct FanReading: Codable {
    /// SMC 中从零开始的风扇编号，用于稳定关联同一个物理风扇。
    let index: Int
    /// 面向用户的方位或顺序名称，不暴露底层 SMC key。
    let name: String
    /// 当前实际转速，保留 SMC 原始精度；界面按整数 RPM 展示。
    let rpm: Double?
}

/// 一个采样周期内的完整风扇快照；空数组表示该机型没有风扇。
struct FanSnapshot: Codable {
    /// 按 SMC 编号排列的物理风扇，数量来自 FNum 并受安全上限约束。
    let fans: [FanReading]
}

/// 只读 AppleSMC 风扇采集，不包含模式切换、目标转速或任何写操作。
enum FanReader {
    /// 四字符 SMC key 只为风扇编号保留一个十进制字符，限制数量也避免损坏的 FNum 触发大量读取。
    private static let maximumFanCount = 10

    /// 打开一次短生命周期 SMC 连接，按 FNum 读取当前转速；连接失败时返回 nil，无风扇时返回空快照。
    static func read() -> FanSnapshot? {
        guard let smc = SMCReadConnection.open() else { return nil }
        defer { smc.close() }

        let reportedCount = smc.readNumber("FNum").flatMap(validFanCount)
        if let count = reportedCount {
            let fans = (0..<count).map { index in
                FanReading(index: index, name: displayName(for: index, count: count),
                           rpm: smc.readNumber(fanKey(index)).flatMap(validRPM))
            }
            // FNum 声明存在风扇但全部读取失败时属于接口错误，不能伪装成有效快照。
            return count > 0 && fans.allSatisfy { $0.rpm == nil } ? nil : FanSnapshot(fans: fans)
        }

        // 少数系统不提供 FNum；仅保留实际可读取的键，无键时按无风扇机型处理。
        let fans = (0..<maximumFanCount).compactMap { index -> FanReading? in
            guard let rpm = smc.readNumber(fanKey(index)).flatMap(validRPM) else { return nil }
            return FanReading(index: index, name: "风扇 \(index + 1)", rpm: rpm)
        }
        return FanSnapshot(fans: fans)
    }

    /// 将有限整数 FNum 限制到 SMC 四字符键可表达的范围，拒绝负数、小数和异常大值。
    private static func validFanCount(_ value: Double) -> Int? {
        guard value.isFinite else { return nil }
        let count = Int(value.rounded())
        guard abs(value - Double(count)) < 0.001, (0...maximumFanCount).contains(count) else { return nil }
        return count
    }

    /// 接受停止状态的零转速并限制合理上界，防止损坏数据进入界面。
    static func validRPM(_ value: Double) -> Double? {
        guard value.isFinite, value >= 0, value <= 30_000 else { return nil }
        return value
    }

    /// 双风扇机型按 AppleSMC 的稳定编号显示左右方位，其他数量使用不臆测方位的顺序名称。
    private static func displayName(for index: Int, count: Int) -> String {
        if count == 2 { return index == 0 ? "左侧风扇" : "右侧风扇" }
        return count == 1 ? "风扇" : "风扇 \(index + 1)"
    }

    /// 根据零到九的风扇编号生成四字符实际转速键，例如 F0Ac。
    private static func fanKey(_ index: Int) -> String { "F\(index)Ac" }
}

/// AppleSMC 数值编码的最小解码器，仅支持风扇数量和实际转速需要的已知 ABI 格式。
enum SMCNumericDecoder {
    /// 解码 ui8、Apple Silicon 的本机浮点 flt 和 Intel 的大端 fpe2；未知或长度不符时返回 nil。
    static func decode(type: String, bytes: [UInt8]) -> Double? {
        switch type {
        case "ui8 ":
            return bytes.first.map(Double.init)
        case "flt ":
            guard bytes.count >= MemoryLayout<Float>.size else { return nil }
            var value: Float = 0
            withUnsafeMutableBytes(of: &value) { destination in
                destination.copyBytes(from: bytes.prefix(MemoryLayout<Float>.size))
            }
            let result = Double(value)
            return result.isFinite ? result : nil
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            return Double((UInt16(bytes[0]) << 8) | UInt16(bytes[1])) / 4
        default:
            return nil
        }
    }
}

/// AppleSMC 用户客户端要求的固定版本字段；字段顺序和宽度必须与内核 ABI 一致。
private struct SMCVersionData {
    /// SMC 主版本号。
    var major: UInt8 = 0
    /// SMC 次版本号。
    var minor: UInt8 = 0
    /// SMC 构建号。
    var build: UInt8 = 0
    /// ABI 保留字节。
    var reserved: UInt8 = 0
    /// SMC 发布版本。
    var release: UInt16 = 0
}

/// AppleSMC 用户客户端要求的性能限制占位字段；读取风扇时保持全零。
private struct SMCPLimitData {
    /// 性能限制结构版本。
    var version: UInt16 = 0
    /// 性能限制结构长度。
    var length: UInt16 = 0
    /// CPU 限制占位值。
    var cpu: UInt32 = 0
    /// GPU 限制占位值。
    var gpu: UInt32 = 0
    /// 内存限制占位值。
    var memory: UInt32 = 0
}

/// 单个 SMC key 的数据长度、类型和属性元信息。
private struct SMCKeyInfoData {
    /// 值的有效字节数，最大不能超过固定缓冲区。
    var dataSize: UInt32 = 0
    /// 四字符数据类型按大端整数保存。
    var dataType: UInt32 = 0
    /// SMC 固件提供的只读属性位。
    var attributes: UInt8 = 0
}

/// AppleSMC IOConnect 调用的固定 80 字节请求与响应结构。
private struct SMCKeyData {
    /// 固定 32 字节值缓冲区，避免动态内存跨越 IOKit ABI。
    typealias Bytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

    /// 四字符 key 的大端整数形式。
    var key: UInt32 = 0
    /// 固定版本字段，风扇读取请求保持默认值。
    var version = SMCVersionData()
    /// 固定性能限制字段，风扇读取请求保持默认值。
    var limits = SMCPLimitData()
    /// key 的长度与编码元信息。
    var keyInfo = SMCKeyInfoData()
    /// 对齐 Swift 嵌套结构尾部，使后续字段与 AppleSMC 的 C ABI 一致。
    var padding: UInt16 = 0
    /// SMC 固件级结果码，零表示成功。
    var result: UInt8 = 0
    /// SMC 固件状态码，读取路径不单独解释。
    var status: UInt8 = 0
    /// 本次调用的命令码。
    var command: UInt8 = 0
    /// 索引读取参数，普通 key 读取保持为零。
    var data32: UInt32 = 0
    /// 固定值缓冲区，只复制 keyInfo 指定的有效部分。
    var bytes: Bytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

/// 一个 SMC key 的原始类型和字节，数值解释由独立解码器完成。
private struct SMCRawValue {
    /// 四字符 SMC 数据类型。
    let type: String
    /// 已裁剪到 keyInfo 长度的原始值。
    let bytes: [UInt8]
}

/// 每次采样使用的只读 AppleSMC 短连接，析构时兜底关闭 Mach 端口。
private final class SMCReadConnection {
    /// 当前 IOKit 用户客户端连接；关闭后置零防止重复释放。
    private var connection: io_connect_t

    /// 仅允许 open() 在 IOServiceOpen 成功后创建有效连接。
    private init(connection: io_connect_t) { self.connection = connection }

    /// 查找 AppleSMC 服务并以普通权限打开只读用户客户端；任一步失败都不保留系统对象。
    static func open() -> SMCReadConnection? {
        guard MemoryLayout<SMCKeyData>.stride == 80 else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
        return SMCReadConnection(connection: connection)
    }

    /// 读取并解码一个 SMC 数值；缺失键、固件拒绝和未知编码统一返回 nil。
    func readNumber(_ key: String) -> Double? {
        guard let raw = readRaw(key) else { return nil }
        return SMCNumericDecoder.decode(type: raw.type, bytes: raw.bytes)
    }

    /// 关闭 IOKit 连接并清零句柄；显式关闭和析构可以安全重复调用。
    func close() {
        guard connection != 0 else { return }
        IOServiceClose(connection)
        connection = 0
    }

    /// 先查询 key 元信息，再读取有效字节；仅调用 AppleSMC 的 readKeyInfo 与 readBytes 命令。
    private func readRaw(_ key: String) -> SMCRawValue? {
        let characters = Array(key.utf8)
        guard characters.count == 4 else { return nil }
        var input = SMCKeyData()
        var output = SMCKeyData()
        input.key = characters.reduce(0) { ($0 << 8) | UInt32($1) }
        input.command = 9
        guard call(input: &input, output: &output) == kIOReturnSuccess,
              output.result == 0, output.keyInfo.dataSize > 0,
              output.keyInfo.dataSize <= 32, output.keyInfo.dataType != 0 else { return nil }

        let info = output.keyInfo
        input.keyInfo.dataSize = info.dataSize
        input.command = 5
        output = SMCKeyData()
        guard call(input: &input, output: &output) == kIOReturnSuccess, output.result == 0 else { return nil }
        let allBytes = withUnsafeBytes(of: &output.bytes) { Array($0) }
        let typeBytes = [UInt8((info.dataType >> 24) & 0xff), UInt8((info.dataType >> 16) & 0xff),
                         UInt8((info.dataType >> 8) & 0xff), UInt8(info.dataType & 0xff)]
        guard let type = String(bytes: typeBytes, encoding: .ascii) else { return nil }
        return SMCRawValue(type: type, bytes: Array(allBytes.prefix(Int(info.dataSize))))
    }

    /// 按 AppleSMC 固定 selector 2 发送结构调用，连接失效时立即返回 IOKit 错误。
    private func call(input: inout SMCKeyData, output: inout SMCKeyData) -> kern_return_t {
        guard connection != 0 else { return kIOReturnNotOpen }
        var outputSize = MemoryLayout<SMCKeyData>.stride
        return IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<SMCKeyData>.stride,
                                         &output, &outputSize)
    }

    /// 采样异常退出时仍释放 IOKit 连接。
    deinit { close() }
}
