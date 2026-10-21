import Foundation
import Security
import ServiceManagement

/// 管理固定身份的只读管理员服务；安装由系统授权界面完成，应用不接触密码。
enum CPUPrivilege {
    /// 仅表示已有安装文件；实际 root 身份、协议及服务签名仍由连接和快照验证。
    static var isInstalled: Bool { FileManager.default.fileExists(atPath: CPUServiceIdentity.installedPath) }

    /// 请求系统安装或升级签名匹配的辅助工具，取消授权时原有菜单栏采样继续工作。
    static func install() throws {
        var authorization: AuthorizationRef?
        let create = AuthorizationCreate(nil, nil, [], &authorization)
        guard create == errAuthorizationSuccess, let authorization else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(create))
        }
        defer { AuthorizationFree(authorization, []) }
        let result = kSMRightBlessPrivilegedHelper.withCString { name -> OSStatus in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { pointer in
                var rights = AuthorizationRights(count: 1, items: pointer)
                return AuthorizationCopyRights(authorization, &rights, nil,
                    [.interactionAllowed, .extendRights, .preAuthorize], nil)
            }
        }
        guard result == errAuthorizationSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(result))
        }
        var error: Unmanaged<CFError>?
        // 本机固定自签名不具备公证身份；使用系统仍支持的签名校验安装通道，保持现有证书。
        guard SMJobBless(kSMDomainSystemLaunchd, CPUServiceIdentity.label as CFString, authorization, &error) else {
            if let error { throw error.takeRetainedValue() as Error }
            throw NSError(domain: "CPUPrivilege", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "系统未能安装 CPU 采集服务。"])
        }
    }
}

/// 每个展开的 CPU 面板只持有一条本地连接，关闭即释放并让管理员服务空闲退出。
final class CPUPrivilegedClient {
    /// 已验证签名的服务连接，所有访问由 CPUMonitor 的串行队列协调。
    private var connection: NSXPCConnection?

    /// 发起固定的无参数只读查询；连接两端互相验证代码签名。
    func read(completion: @escaping (Result<CPUProcessSnapshot, Error>) -> Void) {
        if connection == nil {
            let value = NSXPCConnection(machServiceName: CPUServiceIdentity.label, options: .privileged)
            value.remoteObjectInterface = NSXPCInterface(with: CPUServiceProtocol.self)
            value.setCodeSigningRequirement(CPUServiceIdentity.helperRequirement)
            value.resume()
            connection = value
        }
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ error in
            // 系统明确报告签名要求不匹配时需要更新服务；普通连接中断仍按暂时故障重试。
            let value = error as NSError
            if value.domain == NSCocoaErrorDomain && value.code == NSXPCConnectionCodeSigningRequirementFailure {
                completion(.failure(CPUServiceValidationError.updateRequired))
            } else {
                completion(.failure(error))
            }
        }) as? CPUServiceProtocol else {
            completion(.failure(NSError(domain: "CPUService", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法连接 CPU 采集服务。"])))
            return
        }
        proxy.readSnapshot { data, message in
            do {
                guard let data else {
                    throw NSError(domain: "CPUService", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: message ?? "采集服务没有返回数据。"])
                }
                let snapshot: CPUProcessSnapshot
                do {
                    snapshot = try JSONDecoder().decode(CPUProcessSnapshot.self, from: data)
                } catch {
                    throw CPUServiceValidationError.updateRequired
                }
                guard snapshot.version == CPUServiceIdentity.protocolVersion else {
                    throw CPUServiceValidationError.updateRequired
                }
                guard snapshot.privileged else { throw CPUServiceValidationError.authorizationRequired }
                completion(.success(snapshot))
            } catch { completion(.failure(error)) }
        }
    }

    /// 主动断开，清空连接，避免失效连接或辅助进程长期驻留。
    func close() { connection?.invalidate(); connection = nil }

    /// 释放时也结束 XPC 连接。
    deinit { connection?.invalidate() }
}
