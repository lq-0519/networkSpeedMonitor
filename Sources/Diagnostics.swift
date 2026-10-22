import AppKit

/// 自包含诊断入口；不创建历史文件、不修改设置、不申请权限，便于复现采集准确性与生命周期。
enum Diagnostics {
    /// 验证首帧抑制、CSV 分块、列重排、路由去重和唤醒基线等数据正确性边界。
    static func selfCheck() {
        var assertions = 0
        /// 失败时立即停止诊断，并提供具体边界名称。
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
            assertions += 1
        }
        check(AppDelegate.initialPauseReasons(session: ["CGSSessionScreenIsLocked": true,
                                                        kCGSessionOnConsoleKey as String: true]) == ["lock"],
              "锁屏中启动或更新立即暂停，不依赖过去的锁屏通知")
        check(AppDelegate.initialPauseReasons(session: ["CGSSessionScreenIsLocked": false,
                                                        kCGSessionOnConsoleKey as String: false]) == ["session"],
              "启动时的非活动用户会话不采样")
        check(AppDelegate.initialPauseReasons(session: ["CGSSessionScreenIsLocked": false,
                                                        kCGSessionOnConsoleKey as String: true]).isEmpty,
              "正常解锁会话允许采样")
        check(AppDelegate.initialPauseReasons(session: nil).isEmpty, "未知启动会话仍由生命周期通知控制")
        // 显示偏好不写入真实设置；覆盖升级默认、未知键过滤和连续颜色的完整取值范围。
        check(MenuBarPreferences.validated(nil) == Set(MenuBarComponent.allCases), "首次启动默认显示 CPU、网络与电池")
        check(MenuBarPreferences.validated([]) == Set(MenuBarComponent.allCases), "空配置不能隐藏整个菜单栏入口")
        check(MenuBarPreferences.validated(["future", "battery"]) == [.battery], "忽略未知选项并保留有效电池选择")
        /// 在统一 sRGB 空间比较最大通道差值，避免用动态 NSColor 对象身份判断视觉颜色。
        func colorDistance(_ first: NSColor?, _ last: NSColor?) -> CGFloat {
            guard let first = first?.usingColorSpace(.sRGB), let last = last?.usingColorSpace(.sRGB) else { return .infinity }
            return max(abs(first.redComponent - last.redComponent), abs(first.greenComponent - last.greenComponent),
                       abs(first.blueComponent - last.blueComponent))
        }
        check(colorDistance(StatusItemColorScale.cpu(percent: 0), .systemGreen) < 0.000001,
              "CPU 零占用为绿色")
        check(colorDistance(StatusItemColorScale.cpu(percent: 100), .systemRed) < 0.000001,
              "CPU 满占用为红色")
        check(colorDistance(StatusItemColorScale.battery(percent: 100), .systemGreen) < 0.000001
              && colorDistance(StatusItemColorScale.battery(percent: 0), .systemRed) < 0.000001,
              "电量满电为绿色、耗尽为红色")
        check((1...100).allSatisfy {
            let difference = colorDistance(StatusItemColorScale.cpu(percent: Double($0 - 1)),
                                           StatusItemColorScale.cpu(percent: Double($0)))
            return difference > 0 && difference < 0.04
        }, "CPU 的每个百分比均平滑改变颜色，不存在固定三档或阈值跳色")
        check((0...100).allSatisfy {
            colorDistance(StatusItemColorScale.cpu(percent: Double($0)),
                          StatusItemColorScale.battery(percent: 100 - $0)) < 0.000001
        }, "CPU 与电量使用同一连续色带的相反方向")
        check(colorDistance(StatusItemColorScale.cpu(percent: 12.2), StatusItemColorScale.cpu(percent: 12.8)) > 0,
              "CPU 小数占用变化也会改变颜色，不依赖整数舍入")
        check(StatusItemColorScale.cpu(percent: nil) == nil && StatusItemColorScale.cpu(percent: .nan) == nil
              && StatusItemColorScale.cpu(percent: .infinity) == nil
              && StatusItemColorScale.cpu(percent: -1) == nil && StatusItemColorScale.cpu(percent: 101) == nil,
              "未知、非有限或非法 CPU 占用不着色")
        check(StatusItemColorScale.battery(percent: nil) == nil && StatusItemColorScale.battery(percent: -1) == nil
              && StatusItemColorScale.battery(percent: 101) == nil, "未知或非法电量不着色")
        var batterySource: [String: Any] = ["Power Source State": "AC Power", "Current Capacity": 95,
            "Max Capacity": 100, "Is Charging": false, "Is Charged": false, "Time to Full Charge": 0]
        check(BatteryReader.decode(batterySource).secondaryText == "未充电", "95% 插电未充电不推断已充满或充电上限")
        batterySource["Is Charged"] = true
        check(BatteryReader.decode(batterySource).secondaryText == "已充满", "只采用系统报告的已充满状态")
        batterySource["Is Charged"] = false; batterySource["Is Charging"] = true
        batterySource["Time to Full Charge"] = 80
        let chargingBattery = BatteryReader.decode(batterySource)
        check(chargingBattery.secondaryText == "1:20" && chargingBattery.showsLightning,
              "正在充电显示充满所需小时分钟和闪电")
        for invalid in [-1, 0, 65535] {
            batterySource["Time to Full Charge"] = invalid
            check(BatteryReader.decode(batterySource).secondaryText == "估算中", "无效预计分钟数不渲染为时间")
        }
        batterySource["Optimized Battery Charging Engaged"] = true
        check(BatteryReader.decode(batterySource).secondaryText == "已暂停"
              && !BatteryReader.decode(batterySource).showsLightning, "优化充电暂停时不显示充电倒计时或闪电")
        batterySource["Optimized Battery Charging Engaged"] = false
        batterySource["Power Source State"] = "Battery Power"; batterySource["Is Charging"] = false
        batterySource["Time to Empty"] = 550
        let remainingBattery = BatteryReader.decode(batterySource)
        check(remainingBattery.secondaryText == "9:10" && !remainingBattery.showsLightning,
              "电池供电显示预计续航并隐藏闪电")
        batterySource["Time to Empty"] = 751
        check(BatteryReader.decode(batterySource).secondaryText == "12:31", "超过十小时仍保留小时分钟格式")
        batterySource["Time to Empty"] = 8
        check(BatteryReader.decode(batterySource).secondaryText == "0:08", "不足一小时仍保留小时和两位分钟")
        batterySource["Is Charged"] = true
        check(BatteryReader.decode(batterySource).secondaryText == "0:08", "拔电后即使仍有满电标志也显示续航")
        let originalStatus = StatusItemImage.make(download: "276 KB/s", upload: "36 KB/s", cpuPercent: 25,
                                                  components: [.cpu, .network], battery: nil)
        check(originalStatus.size.height == 22 && !originalStatus.isTemplate,
              "CPU 和固定宽度网速保持 22pt 高度，并合为一张原生彩色按钮图像")
        let batteryStatus = StatusItemImage.make(download: "276 KB/s", upload: "36 KB/s", cpuPercent: 25,
                                                 components: [.cpu, .network, .battery], battery: remainingBattery)
        check(!batteryStatus.isTemplate && batteryStatus.size.height == 22,
              "CPU、电量和文字合为一张原生图像，不再叠加独立彩色视图")
        let shortSpeedExamples = ["—", "0 B/s", "999 B/s", "1000 B/s", "14 KB/s", "99 KB/s"]
        let compactStatus = StatusItemImage.make(download: "14 KB/s", upload: "14 KB/s", cpuPercent: 25,
                                                 components: [.cpu, .network, .battery], battery: remainingBattery)
        check(shortSpeedExamples.allSatisfy {
            StatusItemImage.make(download: $0, upload: "14 KB/s", cpuPercent: 25,
                                 components: [.cpu, .network, .battery], battery: remainingBattery).size == compactStatus.size
        }, "缩小后的缓冲仍能吸收短数字和首次未知状态，不改变菜单栏宽度")
        let speedExamples = ["—", "0 B/s", "999 B/s", "1000 B/s", "14 KB/s", "999 KB/s", "1000 KB/s",
                             "1.0 MB/s", "999.9 MB/s", "1000.0 MB/s", "1.0 GB/s", "999.9 GB/s", "1000.0 GB/s"]
        let peakWidth = StatusItemImage.networkWidth(download: "1000.0 MB/s", upload: "1000.0 GB/s")
        let expandedStatus = StatusItemImage.make(download: "1000.0 MB/s", upload: "1000.0 GB/s", cpuPercent: 25,
                                                  components: [.cpu, .network, .battery], battery: remainingBattery,
                                                  minimumNetworkWidth: peakWidth)
        check(speedExamples.allSatisfy {
            StatusItemImage.make(download: $0, upload: "14 KB/s", cpuPercent: 25,
                                 components: [.cpu, .network, .battery], battery: remainingBattery,
                                 minimumNetworkWidth: peakWidth).size == expandedStatus.size
        }, "长数字扩展后的列宽在下载回落或单位切换时不回缩")
        check(speedExamples.allSatisfy {
            StatusItemImage.make(download: "14 KB/s", upload: $0, cpuPercent: 25,
                                 components: [.cpu, .network, .battery], battery: remainingBattery,
                                 minimumNetworkWidth: peakWidth).size == expandedStatus.size
        }, "已保留的最大列宽同样覆盖上传数字回落，不推动电池位置")
        let expandedNetworkStatus = StatusItemImage.make(download: "1000.0 MB/s", upload: "1000.0 GB/s", cpuPercent: 25,
                                                         components: [.cpu, .network], battery: nil, minimumNetworkWidth: peakWidth)
        check(speedExamples.allSatisfy {
            StatusItemImage.make(download: $0, upload: "14 KB/s", cpuPercent: 25,
                                 components: [.cpu, .network], battery: nil,
                                 minimumNetworkWidth: peakWidth).size == expandedNetworkStatus.size
        }, "未勾选电池时同样保留已占用的列宽")
        let unknownCPUStatus = StatusItemImage.make(download: "—", upload: "—", cpuPercent: nil,
                                                   components: [.cpu], battery: nil)
        check(unknownCPUStatus.isTemplate && unknownCPUStatus.size == NSSize(width: 14, height: 22),
              "CPU 无有效采样时仍显示原尺寸中性模板图")
        let networkStatus = StatusItemImage.make(download: "276 KB/s", upload: "36 KB/s", cpuPercent: 95,
                                                components: [.network], battery: remainingBattery)
        check(networkStatus.isTemplate, "只显示网速时继续使用原生模板图像，不残留彩色内容")
        let statusBitmaps = batteryStatus.representations.compactMap { $0 as? NSBitmapImageRep }
        check(statusBitmaps.count == 2 && statusBitmaps.count == batteryStatus.representations.count,
              "菜单栏已提前生成全部像素，不保留系统快照反复执行的绘图回调")
        check(statusBitmaps.map(\.pixelsHigh).sorted() == [22, 44]
              && statusBitmaps.allSatisfy { $0.size == batteryStatus.size },
              "普通和 Retina 位图使用相同逻辑尺寸且保持正确像素密度")
        check(statusBitmaps.allSatisfy {
            let scale = $0.pixelsHigh / 22
            return ($0.colorAt(x: 7 * scale, y: 11 * scale)?.alphaComponent ?? 0) > 0
                && ($0.colorAt(x: 0, y: 0)?.alphaComponent ?? 1) == 0
        }, "位图中 CPU 图像实际可见，边角保持透明，未产生空白或不透明背景")
        let parser = TrafficParser()
        _ = parser.consume(Data(",bytes_in,bytes_out,\nApp.12,999999,888888,\n".utf8), at: 100)
        check(parser.finish() == nil, "首次累计采样不能作为实时速度")
        _ = parser.consume(Data(",bytes_out,bytes_in,\n\"App, Helper.12\",40,".utf8), at: 102)
        check(parser.finish() == nil, "半行 CSV 不提前提交")
        _ = parser.consume(Data("200,\n".utf8), at: 102.01)
        let frame = parser.finish()
        check(frame?.duration == 2, "使用真实帧头间隔")
        check(frame?.rows["App, Helper.12"] == ByteCount(received: 200, sent: 40), "引号与列顺序")
        check(parser.finish() == nil, "帧只发布一次")
        let grouped = NetworkMonitor.routeTotal([
            "default -> en0 -> gateway": ByteCount(received: 100, sent: 20),
            "destination": ByteCount(received: 100, sent: 20),
            "default -> utun0 -> gateway": ByteCount(received: 100, sent: 20),
            "network -> lo0": ByteCount(received: 100, sent: 20),
            "subnet -> en1": ByteCount(received: 50, sent: 10)
        ], allowed: ["en0", "en1", "lo0"])
        check(grouped.bytes == ByteCount(received: 150, sent: 30), "父子路由及 VPN 回环去重")
        check(grouped.interfaces == ["en0", "en1"], "保留实际统计物理接口")
        // 普通网络与直连使用互斥接口集合；汇总相加，不能再加应用排行或 VPN 字节。
        let directRows: [String: ByteCount] = [
            "physical -> en0": ByteCount(received: 100, sent: 20),
            "physical -> awdl0": ByteCount(received: 200, sent: 40),
            "physical -> nan0": ByteCount(received: 50, sent: 10),
            "physical -> llw0": ByteCount(received: 0, sent: 0),
            "child route": ByteCount(received: 200, sent: 40),
            "physical -> utun0": ByteCount(received: 500, sent: 100)
        ]
        let ordinary = NetworkMonitor.routeTotal(directRows, allowed: ["en0"])
        let direct = NetworkMonitor.routeTotal(directRows, allowed: NetworkMonitor.directInterfaceNames)
        check(ordinary.bytes == ByteCount(received: 100, sent: 20), "普通网速不重复计入设备直连或 VPN")
        check(direct.bytes == ByteCount(received: 250, sent: 50), "设备直连独立汇总且排除子路由及 VPN")
        check(direct.interfaces == ["awdl0", "llw0", "nan0"], "零流量直连接口保留可读取状态")
        check(NetworkMonitor.routeTotal([:], allowed: NetworkMonitor.directInterfaceNames).interfaces.isEmpty,
              "没有直连接口的帧区别于可读取接口的零流量")
        var networkTotal = ordinary.bytes
        networkTotal.add(direct.bytes)
        check(networkTotal == ByteCount(received: 350, sent: 70), "顶部总量包含普通网络与直连各一次")
        let connections = TrafficParser()
        let connectionCSV = ",interface,bytes_in,bytes_out,\nsharingd.12,,999999,888888,\ntcp6 endpoint,en0,100,20,\ntcp6 peer,awdl0,200,8200000,\nudp4 local,lo0,500,600,\nChrome.13,,777777,666666,\ntcp4 proxy,utun0,50,80,\n"
        _ = connections.consume(Data(connectionCSV.utf8), at: 100)
        check(connections.finish() == nil, "连接明细首帧不展示历史累计")
        _ = connections.consume(Data(connectionCSV.utf8), at: 102)
        let connectionFrame = connections.finish()!
        check(connectionFrame.rows["sharingd.12"] == ByteCount(received: 300, sent: 8200020),
              "进程只汇总连接行且排除回环，不重复相加系统进程汇总")
        check(connectionFrame.directApplications["sharingd.12"] == ByteCount(received: 200, sent: 8200000),
              "按接口定位 sharingd 的直连子集，不把全部共享流量认作投送")
        check(NetworkMonitor.interfaceTotal(connectionFrame, allowed: ["en0"]).bytes == ordinary.bytes,
              "兼容模式按接口计算普通流量，不计 VPN")
        check(NetworkMonitor.interfaceTotal(connectionFrame, allowed: NetworkMonitor.directInterfaceNames).bytes.sent == 8200000,
              "连接路径可以读取根路由之外的大量直连发送")
        check(!connectionFrame.rows.keys.contains(where: { $0.contains("endpoint") || $0.contains("peer") }),
              "连接地址不进入采样模型")
        // 实测隔空投送使用 quic6；包含尚未绑定接口的 QUIC 行，不能误认成另一个进程。
        let quic = TrafficParser()
        let quicCSV = ",interface,bytes_in,bytes_out,\nsharingd.1355,,324887,459301853,\nquic6 pending.123,,0,0,\nquic6 peerA,awdl0,198757,229682671,\nquic6 peerB,awdl0,122516,229613875,\nquic4 peerC,awdl0,3614,5307,\n"
        _ = quic.consume(Data(quicCSV.utf8), at: 100)
        check(quic.finish() == nil, "真实 QUIC 历史累计量不能作为实时峰值")
        _ = quic.consume(Data(quicCSV.utf8), at: 102)
        let quicFrame = quic.finish()!
        check(quicFrame.rows.keys.sorted() == ["sharingd.1355"], "空接口 quic4/quic6 连接不改变进程归属")
        check(NetworkMonitor.interfaceTotal(quicFrame, allowed: NetworkMonitor.directInterfaceNames).bytes ==
              ByteCount(received: 324887, sent: 459301853), "按实际 AWDL 接口合计多条 QUIC，父汇总不重复")
        _ = connections.consume(Data("#RESET\n".utf8), at: 104)
        _ = connections.consume(Data(connectionCSV.utf8), at: 106)
        check(connections.finish() == nil, "连接兼容切换后重新建立基线")
        // 验证临时条目的活动、短暂间歇、过期和错误边界，不需要启动网络进程或 UI 定时器。
        var activity = DirectTrafficActivity()
        activity.consume(download: 0, upload: 0, at: 100, interval: 2)
        check(!activity.isVisible, "空闲直连不预留列表行")
        activity.consume(download: 1, upload: 0, at: 102, interval: 2)
        check(activity.isVisible && !activity.isIdle, "低速接收也能立即显示直连条目")
        activity.consume(download: 0, upload: 0, at: 104, interval: 2)
        check(activity.isVisible && activity.isIdle, "短暂停顿保留条目但标注当前零流量")
        activity.consume(download: 0, upload: 0, at: 106, interval: 2)
        check(activity.isVisible && activity.isIdle, "连续两个空帧不再让两秒档直连条目闪没")
        activity.consume(download: 0, upload: 0, at: 110, interval: 2)
        check(!activity.isVisible, "持续空闲移除直连条目")
        activity.consume(download: 0, upload: 2000, at: 112, interval: 2)
        check(activity.isVisible && !activity.isIdle, "只有发送流量时同样显示")
        activity.consume(download: nil, upload: nil, at: 113, interval: 2)
        check(!activity.isVisible, "直连接口不可用时立即隐藏旧活动")
        activity.consume(download: 10, upload: 0, at: 114, interval: 2)
        activity.consume(download: .nan, upload: 0, at: 115, interval: 2)
        check(!activity.isVisible, "无效直连速度不能保留旧活动")
        activity.consume(download: 10, upload: 0, at: 116, interval: 2)
        activity.reset()
        check(!activity.isVisible && !activity.isIdle, "采样重启和休眠清除直连防抖状态")
        for interval in [1, 2, 5] {
            activity.reset()
            let grace = DirectTrafficActivity.idleGracePeriod(for: interval)
            check(grace == (interval == 5 ? 15 : 8), "防抖随一、二、五秒刷新档位设置")
            activity.consume(download: 0, upload: 10, at: 200, interval: interval)
            activity.consume(download: 0, upload: 0, at: 200 + grace - 0.01, interval: interval)
            check(activity.isVisible && activity.isIdle, "防抖窗口内保留有效零流量条目")
            activity.consume(download: 0, upload: 0, at: 200 + grace, interval: interval)
            check(!activity.isVisible && !activity.isIdle, "防抖到期由现有采样移除条目")
        }
        // 复现截图的大量直连上传，同时验证下载排序、停顿零值及同名软件的稳定顺序。
        let chat = NetworkRankingRow.application(AppTraffic(key: "chat", name: "ChatGPT", bundlePath: nil,
            download: 157_000, upload: 2_000, processes: 2))
        let chrome = NetworkRankingRow.application(AppTraffic(key: "chrome", name: "Google Chrome", bundlePath: nil,
            download: 3_000, upload: 10_000, processes: 1))
        let directRanking = NetworkRankingRow.direct(download: 15_000, upload: 30_700_000, idle: false)
        let ranking = [chat, chrome, directRanking]
        check(NetworkRankingRow.sorted(ranking, by: .combined).first?.application == nil,
              "合计排序将截图中的大量直连传输置于首位")
        check(NetworkRankingRow.sorted(ranking, by: .upload).first?.upload == 30_700_000,
              "上传排序统一比较软件及直连速度")
        let downloadRanking = NetworkRankingRow.sorted(ranking, by: .download)
        check(downloadRanking.map(\.download) == [157_000, 15_000, 3_000],
              "下载排序使用实际下载值，直连不强制置顶或置底")
        let idleRanking = NetworkRankingRow.direct(download: 0, upload: 0, idle: true)
        let idleRows = NetworkRankingRow.sorted([idleRanking, chat], by: .combined)
        check(idleRows.count == 2 && idleRows.last?.isIdle == true && idleRows.last?.value(for: .combined) == 0,
              "短暂停顿条目参与排序并显示真实零值，不保留旧速度")
        let sameName = ["b", "a"].map { key in
            NetworkRankingRow.application(AppTraffic(key: key, name: "App", bundlePath: nil,
                download: 1, upload: 1, processes: 1))
        }
        check(NetworkRankingRow.sorted(sameName, by: .combined).compactMap { $0.application?.key } == ["a", "b"],
              "同名同速的软件按稳定身份排序，避免刷新时换位")
        _ = parser.consume(Data(",bytes_in,bytes_out,\nApp.12,400,30,\n".utf8), at: 200)
        check(parser.finish() == nil, "长时间暂停不显示异常速率")
        let restarted = TrafficParser()
        _ = restarted.consume(Data(",bytes_in,bytes_out,\nApp.12,9999999,3000000,\n".utf8), at: 300)
        check(restarted.finish() == nil, "重启后重新丢弃累计基线")
        _ = parser.consume(Data("#RESET\n,bytes_in,bytes_out,\nApp.12,9999999,3000000,\n".utf8), at: 400)
        check(parser.finish() == nil, "采集兼容回退重置累计基线")
        check(SpeedText.string(1_500_000) == "1.5 MB/s", "单位一致")
        check(SpeedText.string(.nan) == "—", "无效数值不显示为零")
        // 固定时间基准与逻辑核心数验证整机占比，防止与单核口径混淆。
        let cpu = CPUUsageAccumulator()
        /// 构造边界快照，测试 PID 重用、时钟换算与管理员采样切换。
        func snapshot(_ time: Double, ticks: UInt64, start: UInt64 = 10, privileged: Bool = true) -> CPUProcessSnapshot {
            CPUProcessSnapshot(version: 1, uptime: time, cores: 4, secondsPerTick: 1.0 / 24_000_000,
                privileged: privileged, denied: 0, skipped: 0,
                processes: [CPUProcessCounter(pid: 12, started: start, ticks: ticks, name: "test", path: "")])
        }
        check(cpu.consume(snapshot(100, ticks: 24_000_000)) == nil, "CPU 首帧只建立基线")
        let normalized = cpu.consume(snapshot(102, ticks: 72_000_000))
        check(abs((normalized?.first?.percent ?? -1) - 25) < 0.00001, "CPU 时钟换算并除以整机核心数")
        check(cpu.consume(snapshot(104, ticks: 90_000_000, start: 20))?.isEmpty == true, "PID 重用不能串接旧 CPU 时间")
        check(cpu.consume(snapshot(106, ticks: 1, start: 20))?.isEmpty == true, "CPU 计数回退不能产生负值或峰值")
        check(cpu.consume(snapshot(108, ticks: 10, start: 20, privileged: false)) == nil, "权限变化重建 CPU 基线")
        check(cpu.consume(snapshot(200, ticks: 90, start: 20, privileged: false)) == nil, "长时间暂停丢弃旧 CPU 窗口")
        cpu.reset()
        check(cpu.consume(snapshot(202, ticks: 100)) == nil, "关闭后再次打开 CPU 排行重新建基线")
        let cpuNode = CPUOutlineItem()
        let firstCPUProcess = CPUProcessUsage(process: snapshot(202, ticks: 100).processes[0], percent: 1)
        check(cpuNode.updateProcesses([firstCPUProcess]), "CPU 首次进程结构触发子树加载")
        let existingCPUChild = cpuNode.children[0]
        check(!cpuNode.updateProcesses([CPUProcessUsage(process: firstCPUProcess.process, percent: 2)])
              && cpuNode.children[0] === existingCPUChild && cpuNode.children[0].process?.percent == 2,
              "CPU 纯数值变化复用原节点并呈现最新占用，不重建子树")
        check(cpuNode.updateProcesses([CPUProcessUsage(process: snapshot(204, ticks: 100, start: 20).processes[0], percent: 3)])
              && cpuNode.children[0] !== existingCPUChild, "CPU 的 PID 重用生成新节点，不继承旧进程身份")
        let disk = DiskUsageAccumulator()
        /// 构造磁盘差分边界，启动时刻来自同一次累计计数查询。
        func diskSnapshot(_ time: Double, read: UInt64, write: UInt64, start: UInt64 = 10,
                          privileged: Bool = true) -> CPUProcessSnapshot {
            var result = snapshot(time, ticks: 0, privileged: privileged)
            result.diskProcesses = [DiskProcessCounter(pid: 12, started: start, readBytes: read,
                writtenBytes: write, name: "test", path: "")]
            result.diskDenied = 0; result.diskSkipped = 0
            return result
        }
        check(disk.consume(diskSnapshot(100, read: 1_000_000, write: 2_000_000)) == nil, "磁盘首帧不把累计量显示成实时速度")
        let diskDelta = disk.consume(diskSnapshot(102, read: 1_004_000, write: 2_010_000))?.first
        check(diskDelta?.read == 2000 && diskDelta?.write == 5000, "磁盘读写分别除以实际间隔且不除以 CPU 核心数")
        check(disk.consume(diskSnapshot(104, read: 1_010_000, write: 2_020_000, start: 20))?.isEmpty == true, "磁盘 PID 重用不串接累计字节")
        check(disk.consume(diskSnapshot(106, read: 1, write: 2, start: 20))?.isEmpty == true, "磁盘累计计数回退不能产生巨大速度")
        check(disk.consume(diskSnapshot(108, read: 5, write: 8, start: 20, privileged: false)) == nil, "磁盘权限变化重建基线")
        check(disk.consume(diskSnapshot(200, read: 50, write: 80, start: 20, privileged: false)) == nil, "磁盘休眠后不跨长窗口差分")
        disk.reset()
        check(disk.consume(diskSnapshot(202, read: 60, write: 90)) == nil, "关闭磁盘详情后首帧重新建基线")
        let legacyData = try! JSONEncoder().encode(snapshot(204, ticks: 1))
        let legacy = try! JSONDecoder().decode(CPUProcessSnapshot.self, from: legacyData)
        check(legacy.diskProcesses == nil && legacy.memoryProcesses == nil && legacy.processes.count == 1,
              "旧服务没有磁盘和内存字段时仍可解码 CPU")
        let capacity = DiskCapacity(total: 1000, free: 250)
        check(capacity.used == 750 && capacity.usedPercent == 75, "共享容量使用总量减实际空闲避免双计数")
        let memoryPages = MemoryPageCounts(active: 100, inactive: 50, speculative: 10, wired: 20,
                                           compressed: 30, purgeable: 20, external: 40)
        check(memoryPages.usedBytes(totalBytes: 1_000_000, pageSize: 4096) == 614_400,
              "整机已用内存按驻留和压缩页减去可回收及外部页")
        let reclaimableMemory = MemoryPageCounts(active: 1, inactive: 1, speculative: 0, wired: 0,
                                                 compressed: 0, purgeable: 5, external: 5)
        check(reclaimableMemory.usedBytes(totalBytes: 1_000_000, pageSize: 4096) == 0,
              "可回收页大于驻留页时已用内存下限保持为零")
        check(memoryPages.usedBytes(totalBytes: 100_000, pageSize: 4096) == 100_000,
              "异常页计数不能让已用内存超过物理总量")
        check(MemoryText.string(48 * 1024 * 1024 * 1024) == "48.0 GB",
              "48 GB 物理内存按二进制口径显示为硬件标称容量")
        check(MemoryText.string(1_610_612_736) == "1.5 GB",
              "内存总量和排行使用一致的 1024 进制单位")
        var memorySnapshot = snapshot(206, ticks: 1)
        memorySnapshot.memoryProcesses = [
            MemoryProcessCounter(pid: 12, started: 10, footprintBytes: 123_000_000, name: "test", path: "")
        ]
        memorySnapshot.memoryDenied = 2
        memorySnapshot.memorySkipped = 3
        let memoryNode = MemoryOutlineItem()
        let firstMemoryProcess = memorySnapshot.memoryProcesses![0]
        check(memoryNode.updateProcesses([firstMemoryProcess]), "内存首次进程结构触发子树加载")
        let existingMemoryChild = memoryNode.children[0]
        check(!memoryNode.updateProcesses([MemoryProcessCounter(pid: 12, started: 10,
              footprintBytes: 456, name: "test", path: "")])
              && memoryNode.children[0] === existingMemoryChild && memoryNode.children[0].process?.footprintBytes == 456,
              "内存纯 footprint 变化复用原节点并更新数值，不重建子树")
        check(memoryNode.updateProcesses([MemoryProcessCounter(pid: 12, started: 20,
              footprintBytes: 789, name: "new", path: "")]) && memoryNode.children[0] !== existingMemoryChild,
              "内存的 PID 重用不会沿用旧进程节点")
        let memoryData = try! JSONEncoder().encode(memorySnapshot)
        let decodedMemory = try! JSONDecoder().decode(CPUProcessSnapshot.self, from: memoryData)
        check(decodedMemory.memoryProcesses?.first?.footprintBytes == 123_000_000
            && decodedMemory.memoryDenied == 2 && decodedMemory.memorySkipped == 3,
              "内存 footprint 和独立覆盖数量可通过共享快照编码")
        // 暂时超时保留三类排行的差分窗口；确定的权限、旧协议和关闭状态不能继续展示旧结果。
        let recovering: ProcessCollectionStatus = .retrying("采集超时，正在自动重试。")
        let preservedCPU = CPUUsageAccumulator()
        _ = preservedCPU.consume(snapshot(300, ticks: 24_000_000))
        check(abs((preservedCPU.consume(snapshot(312, ticks: 48_000_000))?.first?.percent ?? -1)
                  - 100.0 / 12 / 4) < 0.00001,
              "短暂重连后 CPU 使用真实间隔差分，不把保留的旧样本显示成新峰值")
        check(preservedCPU.consume(snapshot(360, ticks: 96_000_000)) == nil,
              "超过三十秒的恢复首帧仍只建立 CPU 基线")
        let recoveryMemory = MemoryMonitor()
        recoveryMemory.setVisible(true)
        recoveryMemory.receive(decodedMemory, status: .live)
        let lastMemory = recoveryMemory.applications.first?.footprintBytes
        recoveryMemory.receive(nil, status: recovering)
        check(recoveryMemory.isRankingStale && recoveryMemory.privileged && recoveryMemory.supported
              && recoveryMemory.applications.first?.footprintBytes == lastMemory
              && recoveryMemory.rankingStatus.contains("过期")
              && !recoveryMemory.collectionStatus.requiresAuthorization,
              "内存超时保留旧排行及已验证权限，并明确显示过期")
        recoveryMemory.receive(decodedMemory, status: .live)
        check(!recoveryMemory.isRankingStale && recoveryMemory.rankingStatus == "实时",
              "内存新快照到达立即取消过期标记")
        recoveryMemory.receive(legacy, status: .live)
        check(recoveryMemory.applications.isEmpty && recoveryMemory.collectionStatus.requiresAuthorization
              && !recoveryMemory.collectionStatus.preservesResult,
              "实际旧服务缺少内存字段才要求更新，且不继续保留旧排行")
        recoveryMemory.receive(decodedMemory, status: .live)
        recoveryMemory.receive(nil, status: recovering)
        recoveryMemory.setVisible(false)
        recoveryMemory.receive(decodedMemory, status: .live)
        check(recoveryMemory.applications.isEmpty && !recoveryMemory.isRankingStale && recoveryMemory.sampleTime == nil,
              "关闭内存详情清空过期结果并拒绝迟到快照")
        let recoveryDisk = DiskMonitor()
        recoveryDisk.setVisible(true)
        recoveryDisk.receive(diskSnapshot(300, read: 1000, write: 2000), status: .live)
        recoveryDisk.receive(diskSnapshot(302, read: 5000, write: 8000), status: .live)
        let lastDiskRead = recoveryDisk.applications.first?.read
        recoveryDisk.receive(nil, status: recovering)
        check(recoveryDisk.isRankingStale && recoveryDisk.privileged && recoveryDisk.supported
              && recoveryDisk.applications.first?.read == lastDiskRead
              && !recoveryDisk.collectionStatus.requiresAuthorization,
              "磁盘超时保留最近读写与权限，避免误报需要授权")
        recoveryDisk.receive(diskSnapshot(314, read: 29000, write: 44000), status: .live)
        check(!recoveryDisk.isRankingStale && recoveryDisk.applications.first?.read == 2000,
              "短暂故障恢复后磁盘继续按真实间隔计算，不额外丢弃首帧")
        recoveryDisk.receive(nil, status: recovering)
        recoveryDisk.receive(diskSnapshot(360, read: 40000, write: 50000), status: .live)
        check(recoveryDisk.isRankingStale && recoveryDisk.applications.first?.read == 2000,
              "长缺口恢复的磁盘首帧保留旧结果并继续标注过期")
        recoveryDisk.receive(diskSnapshot(362, read: 46000, write: 60000), status: .live)
        check(!recoveryDisk.isRankingStale && recoveryDisk.applications.first?.read == 3000,
              "长缺口恢复的磁盘第二帧替换旧结果并取消过期标记")
        recoveryDisk.receive(nil, status: .authorizationRequired)
        check(recoveryDisk.applications.isEmpty && !recoveryDisk.isRankingStale && !recoveryDisk.privileged
              && recoveryDisk.collectionStatus.requiresAuthorization,
              "明确的权限失败清空磁盘旧数据，与暂时超时分别处理")
        recoveryDisk.setVisible(false)
        // 验证不同供电状态及驱动编码，防止把适配器能力、净电池功率和无效时间混为一谈。
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var powerRaw: [String: Any] = ["ExternalConnected": true, "UpdateTime": now.timeIntervalSince1970,
            "Voltage": 12000, "Amperage": -1000, "AdapterDetails": ["Watts": 65],
            "PowerTelemetryData": ["SystemPowerIn": 30000, "SystemLoad": 10000, "BatteryPower": 20000]]
        var powerSource: [String: Any] = ["Current Capacity": 25, "Max Capacity": 100,
            "Is Charging": true, "Time to Full Charge": 90]
        let chargingPower = PowerReader.decode(raw: powerRaw, source: powerSource, now: now)
        check(chargingPower.inputWatts == 30 && chargingPower.batteryWatts == 20 && chargingPower.systemWatts == 10
            && chargingPower.adapterWatts == 65 && chargingPower.minutes == 90, "实测输入、电池充电、系统负载和适配器能力独立")
        powerRaw["PowerTelemetryData"] = ["SystemPowerIn": 5000, "SystemLoad": 15000, "BatteryPower": -10000]
        let supplementalPower = PowerReader.decode(raw: powerRaw, source: powerSource, now: now)
        check(supplementalPower.charging && supplementalPower.batteryWatts == -10 && supplementalPower.systemWatts == 15,
            "充电标志不能覆盖插电时的实际放电方向")
        powerSource["Time to Full Charge"] = -1
        check(PowerReader.decode(raw: powerRaw, source: powerSource, now: now).minutes == nil, "未估算的充满时间不显示为分钟数")
        powerSource["Time to Full Charge"] = 65535
        check(PowerReader.decode(raw: powerRaw, source: powerSource, now: now).minutes == nil, "充满时间哨兵值不能显示为超长倒计时")
        powerSource["Time to Full Charge"] = 90; powerSource["Optimized Battery Charging Engaged"] = true
        check(PowerReader.decode(raw: powerRaw, source: powerSource, now: now).minutes == nil, "优化充电暂停时不显示充满倒计时")
        powerSource["Optimized Battery Charging Engaged"] = false
        powerRaw["ExternalConnected"] = false
        powerRaw["PowerTelemetryData"] = ["SystemPowerIn": 0, "SystemLoad": 12000, "BatteryPower": -12000]
        powerSource["Time to Empty"] = 120
        let dischargingPower = PowerReader.decode(raw: powerRaw, source: powerSource, now: now)
        check(dischargingPower.inputWatts == nil && dischargingPower.adapterWatts == nil
            && dischargingPower.batteryWatts == -12 && dischargingPower.minutes == 120, "电池供电不保留已断开的适配器读数")
        powerRaw.removeValue(forKey: "PowerTelemetryData"); powerRaw["Amperage"] = UInt32.max - 999
        let fallbackPower = PowerReader.decode(raw: powerRaw, source: powerSource, now: now)
        check(fallbackPower.estimated && fallbackPower.batteryWatts == -12 && fallbackPower.systemWatts == 12,
            "无符号电流恢复负号后按毫伏和毫安换算功率")
        powerRaw["UpdateTime"] = now.timeIntervalSince1970 - 121
        let stalePower = PowerReader.decode(raw: powerRaw, source: powerSource, now: now)
        check(stalePower.batteryWatts == nil && stalePower.systemWatts == nil, "过期的传感器读数不能冒充当前功率")
        let appleSiliconRPM: Float = 2318
        let floatBytes = withUnsafeBytes(of: appleSiliconRPM) { Array($0) }
        check(SMCNumericDecoder.decode(type: "flt ", bytes: floatBytes) == 2318,
              "Apple Silicon 风扇浮点编码按本机字节序解码")
        check(SMCNumericDecoder.decode(type: "fpe2", bytes: [0x17, 0x70]) == 1500,
              "Intel 风扇定点编码按大端四分之一 RPM 解码")
        check(SMCNumericDecoder.decode(type: "ui8 ", bytes: [2]) == 2,
              "SMC 风扇数量使用无符号单字节")
        check(FanReader.validRPM(0) == 0 && FanReader.validRPM(8_000) == 8_000,
              "停止状态和合理转速均可保留")
        check(FanReader.validRPM(.nan) == nil && FanReader.validRPM(30_001) == nil,
              "无效或异常风扇转速不会进入界面")
        let historySamples = [
            PowerHistorySample(time: 0, percent: 80, external: false, charging: false),
            PowerHistorySample(time: 600, percent: 78, external: false, charging: false),
            PowerHistorySample(time: 1200, percent: 82, external: true, charging: true),
            PowerHistorySample(time: 1800, percent: 85, external: true, charging: false),
            PowerHistorySample(time: 2400, percent: 84, external: false, charging: false),
            PowerHistorySample(time: 3000, percent: 82, external: false, charging: false),
            PowerHistorySample(time: 3600, percent: 83, external: false, charging: false)
        ]
        let history = PowerHistorySnapshot.make(start: 0, end: 3600, samples: historySamples, sleeps: [])
        check(history.summary?.batterySeconds == 2400, "电池供电摘要不把已接通电源但未充电计入")
        check(history.summary?.decline == 4, "下降百分点按电池区间累计，不用充电回升抵扣")
        let sparse = [historySamples[0], PowerHistorySample(time: 3600, percent: 78, external: false, charging: false)]
        check(PowerHistorySnapshot.make(start: 0, end: 3600, samples: sparse, sleeps: []).summary == nil,
              "无休眠证据的长缺口不连线，也不伪装成零耗电")
        let sleeping = PowerHistorySnapshot.make(start: 0, end: 3600, samples: sparse, sleeps: [
            PowerHistoryInterval(start: 0, end: 1700), PowerHistoryInterval(start: 1600, end: 3600)])
        check(sleeping.sleeps.count == 1 && sleeping.summary?.batterySeconds == 3600,
              "重叠休眠事件合并后，长休眠可以由真实记录支持")
        let pairedSleeps = PowerHistoryReader.sleepIntervals(from: [[1000, 900, 4], [1200, nil, 0], [1250, 900, 5]])
        check(pairedSleeps.count == 2 && pairedSleeps.allSatisfy { $0.start == 900 && $0.end == 1200 },
              "休眠终点配对真实唤醒事件，不误用休眠行或迟到通知的写入时间")
        let clippedHistory = PowerHistorySnapshot.make(start: 300, end: 900, samples: historySamples, sleeps: [])
        check(clippedHistory.summary?.batterySeconds == 300 && clippedHistory.summary?.decline == 1,
              "左边界按比例裁剪，最后记录之后不外推至现在")
        check(PowerHistorySnapshot.make(start: 0, end: 3600, samples: [historySamples[0]], sleeps: []).summary == nil,
              "单个电量点不能生成虚假的时长与下降摘要")
        let pluggedHistory = PowerHistorySnapshot.make(start: 1200, end: 1800,
            samples: Array(historySamples[2...3]), sleeps: [])
        check(pluggedHistory.summary?.batterySeconds == 0 && pluggedHistory.summary?.decline == 0,
              "有完整接电记录时允许显示真实零值，区别于无记录")
        let invalidHistory = PowerHistorySnapshot.make(start: 0, end: 600, samples: [historySamples[0],
            PowerHistorySample(time: 600, percent: .nan, external: false, charging: false),
            PowerHistorySample(time: 500, percent: 101, external: false, charging: false), historySamples[1],
            PowerHistorySample(time: 600, percent: 77, external: false, charging: false), historySamples[2]], sleeps: [])
        check(invalidHistory.samples.count == 2 && invalidHistory.samples.last?.percent == 77,
              "系统异常和未来电量剔除，同时间戳只保留最后有效记录")
        check(PowerHistoryRange.allCases.map(\.rawValue) == [1, 10, 24, 168] && PowerHistoryRange(rawValue: 12) == nil,
              "历史选项固定一小时、十小时、二十四小时和七天，不包含十二小时")
        check(PowerHistoryRange.week.seconds == 7 * 86400 && PowerHistoryRange.day.seconds == 86400,
              "跨日和七天窗口按真实秒数查询，不误当作当天或自然周")
        let rangeMonitor = PowerHistoryMonitor()
        check(rangeMonitor.range == .tenHours && rangeMonitor.snapshot == nil,
              "未打开历史时默认十小时，不创建隐藏查询")
        rangeMonitor.setRange(.week)
        check(rangeMonitor.range == .week && !rangeMonitor.loading && rangeMonitor.snapshot == nil,
              "隐藏时切换只改变范围，不触发数据库或归档读取")
        check(TrendRange.allCases.map(\.rawValue) == [60, 600, 3600, 86400],
              "新增趋势只提供一分钟、十分钟、一小时和二十四小时")
        /// 构造确定的真实时间点，验证长窗口压缩仍保留极值、缺失和生命周期边界。
        func trendPoint(_ index: Int, value: Double?, breakBefore: Bool = false) -> TrendPoint {
            TrendPoint(id: Int64(index), time: Double(index * 2), value: value,
                       segment: index < 1000 ? "before" : "after", spacing: 2, estimated: false, breakBefore: breakBefore)
        }
        var trendPoints = (0...2000).map { trendPoint($0, value: Double($0 % 20)) }
        trendPoints[101] = trendPoint(101, value: 999)
        trendPoints[202] = trendPoint(202, value: -99)
        trendPoints[303] = trendPoint(303, value: nil)
        trendPoints[404] = trendPoint(404, value: 4, breakBefore: true)
        let reducedTrend = TrendDownsampler.reduce(trendPoints, since: 0, range: .day)
        check(reducedTrend.compactMap(\.value).max() == 999 && reducedTrend.compactMap(\.value).min() == -99,
              "长窗口保留真实峰谷，不能被平均抹掉")
        check(reducedTrend.contains { $0.id == 303 && $0.value == nil }
              && reducedTrend.contains { $0.id == 404 && $0.breakBefore },
              "缺失读数与原始长缺口经压缩后仍然断线")
        check(reducedTrend.first?.id == 0 && reducedTrend.last?.id == 2000
              && reducedTrend.contains { $0.id == 999 } && reducedTrend.contains { $0.id == 1000 },
              "首末点及采集分段两侧的真实样本均保留")
        let reducedAgain = TrendDownsampler.reduce(reducedTrend, since: 0, range: .day)
        check(reducedAgain.map(\.id) == reducedTrend.map(\.id)
              && Set(reducedAgain.map(\.id)).count == reducedAgain.count,
              "增量压缩幂等，不重复绘制同一真实样本")
        let recentTrend = TrendDownsampler.reduce(trendPoints, since: 3990, range: .minute)
        check(recentTrend.allSatisfy { $0.time >= 3990 } && recentTrend.last?.id == 2000,
              "滚动窗口只保留真实范围内样本，不向左补造曲线")
        print("PASS: \(assertions) checks")
    }

    /// 显式诊断入口按范围单次读取系统历史并输出 JSON，不创建历史文件或启动周期采样。
    static func readPowerHistory(range: PowerHistoryRange = .tenHours) {
        do {
            let snapshot = try PowerHistoryReader.read(range: range)
            var result = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any] ?? [:]
            result["range_hours"] = range.rawValue
            if let summary = snapshot.summary {
                result["battery_seconds"] = summary.batterySeconds
                result["decline_percentage_points"] = summary.decline
            }
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            FileHandle.standardOutput.write(data); print("")
        } catch {
            fputs("\(error.localizedDescription)\n", stderr); exit(1)
        }
    }

    /// 有限时长验证真实电源模型，并确认关闭后的迟到回调不会发布；JSON 只在显式诊断时输出。
    static func samplePower(seconds: Double) {
        let monitor = PowerMonitor()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        var count = 0
        monitor.onUpdate = {
            guard let snapshot = monitor.snapshot,
                  let data = try? encoder.encode(snapshot), let text = String(data: data, encoding: .utf8) else { return }
            count += 1; print(text); fflush(stdout)
        }
        monitor.setVisible(true)
        let end = Date().addingTimeInterval(min(120, max(1, seconds)))
        while Date() < end { RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.25))) }
        monitor.setVisible(false); monitor.shutdown()
        let stoppedCount = count
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        guard count > 0 else { fputs("电源数据不可用。\n", stderr); exit(1) }
        guard count == stoppedCount else { fputs("关闭后仍发布电源数据。\n", stderr); exit(1) }
    }

    /// 有限时长读取真实 AppleSMC 风扇快照并输出 JSON，同时确认关闭后不再发布旧数据。
    static func sampleFans(seconds: Double) {
        let monitor = PowerMonitor()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var count = 0
        monitor.onUpdate = {
            guard let snapshot = monitor.fanSnapshot,
                  let data = try? encoder.encode(snapshot),
                  let text = String(data: data, encoding: .utf8) else { return }
            count += 1
            print(text)
            fflush(stdout)
        }
        monitor.setVisible(true)
        let end = Date().addingTimeInterval(min(120, max(1, seconds)))
        while Date() < end { RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.25))) }
        monitor.setVisible(false)
        monitor.shutdown()
        let stoppedCount = count
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        guard count > 0 else { fputs("风扇数据不可用。\n", stderr); exit(1) }
        guard count == stoppedCount else { fputs("关闭后仍发布风扇数据。\n", stderr); exit(1) }
    }

    /// 复用实际 CPU 模型与管理员连接做有限时长验证，不改设置或自动触发授权。
    static func sampleCPU(seconds: Double, ranking: Bool) {
        let monitor = CPUMonitor()
        var count = 0
        monitor.onUpdate = {
            guard let usage = monitor.usage else { return }
            count += 1
            // 和界面使用同一个 Top 设置，完整进程总数不受明细截取影响。
            let rows = monitor.applications.prefix(RankingPreferences.count(for: .cpu)).map { app -> [String: Any] in
                ["name": app.name, "whole_machine_percent": app.percent,
                 "process_count": app.processCount, "pids": app.processes.map { $0.process.pid }]
            }
            let result: [String: Any] = ["cpu_percent": usage.total, "user_percent": usage.user,
                "system_percent": usage.system, "privileged": monitor.privileged,
                "readable_processes": monitor.readableProcesses, "denied_processes": monitor.deniedProcesses,
                "ranking_status": monitor.rankingStatus, "applications": rows]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
               let line = String(data: data, encoding: .utf8) { print(line); fflush(stdout) }
        }
        monitor.restart()
        if ranking { monitor.setRankingVisible(true) }
        let end = Date().addingTimeInterval(min(120, max(3, seconds)))
        while Date() < end { RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.25))) }
        monitor.shutdown()
        if count == 0 { fputs("没有获取有效 CPU 采样。\n", stderr); exit(1) }
    }

    /// 验证实际管理员磁盘采集与关闭生命周期；旧服务或普通权限返回失败，不把容量成功冒充完整排行。
    static func sampleDisk(seconds: Double) {
        let cpu = CPUMonitor(), disk = DiskMonitor()
        var samples = 0, lastTime: TimeInterval?
        cpu.onProcessSnapshot = { snapshot, status in disk.receive(snapshot, status: status) }
        disk.onUpdate = {
            guard let time = disk.sampleTime, time != lastTime else { return }
            lastTime = time
            if disk.privileged && disk.supported { samples += 1 }
            let rows = disk.sortedApplications.prefix(RankingPreferences.count(for: .disk)).map { app -> [String: Any] in
                ["name": app.name, "read_Bps": app.read, "write_Bps": app.write, "process_count": app.processes]
            }
            let result: [String: Any] = ["uptime": time, "privileged": disk.privileged,
                "supported": disk.supported, "readable_processes": disk.readableProcesses,
                "denied_processes": disk.deniedProcesses, "skipped_processes": disk.skippedProcesses,
                "ranking_status": disk.rankingStatus, "top_count": RankingPreferences.count(for: .disk),
                "capacity_total_bytes": disk.capacity?.total ?? -1, "capacity_used_bytes": disk.capacity?.used ?? -1,
                "capacity_free_bytes": disk.capacity?.free ?? -1, "applications": rows]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
               let line = String(data: data, encoding: .utf8) { print(line); fflush(stdout) }
        }
        disk.setVisible(true); cpu.restart(); cpu.setRankingVisible(true)
        let end = Date().addingTimeInterval(min(120, max(3, seconds)))
        while Date() < end { RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.25))) }
        disk.setVisible(false); cpu.shutdown()
        let stoppedCount = samples
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        guard samples >= 2, samples == stoppedCount else {
            fputs("磁盘管理员采集尚未就绪，或关闭后仍发布快照。\n", stderr); exit(1)
        }
    }

    /// 验证整机内存摘要、进程 footprint 排行及关闭生命周期；输出与界面同口径的 JSON。
    static func sampleMemory(seconds: Double) {
        let cpu = CPUMonitor()
        let memory = MemoryMonitor()
        var samples = 0
        var lastTime: TimeInterval?
        cpu.onProcessSnapshot = { snapshot, status in memory.receive(snapshot, status: status) }
        memory.onUpdate = {
            guard let usage = memory.systemUsage else { return }
            let time = memory.sampleTime
            if let time, time != lastTime {
                lastTime = time
                if memory.supported { samples += 1 }
            }
            let rows = memory.applications.prefix(RankingPreferences.count(for: .memory)).map { app -> [String: Any] in
                ["name": app.name, "footprint_bytes": app.footprintBytes,
                 "process_count": app.processCount,
                 "processes": app.processes.map { ["pid": $0.pid, "footprint_bytes": $0.footprintBytes] }]
            }
            let result: [String: Any] = [
                "uptime": time ?? -1,
                "total_bytes": usage.totalBytes,
                "used_bytes": usage.usedBytes,
                "pressure": usage.pressure.title,
                "pressure_level": usage.pressure.rawValue,
                "privileged": memory.privileged,
                "supported": memory.supported,
                "readable_processes": memory.readableProcesses,
                "denied_processes": memory.deniedProcesses,
                "skipped_processes": memory.skippedProcesses,
                "ranking_status": memory.rankingStatus,
                "top_count": RankingPreferences.count(for: .memory),
                "applications": rows
            ]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
               let line = String(data: data, encoding: .utf8) {
                print(line)
                fflush(stdout)
            }
        }
        memory.setVisible(true)
        cpu.restart()
        cpu.setRankingVisible(true)
        let end = Date().addingTimeInterval(min(120, max(3, seconds)))
        while Date() < end {
            RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.25)))
        }
        memory.setVisible(false)
        cpu.shutdown()
        let stoppedCount = samples
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        guard samples > 0, samples == stoppedCount else {
            fputs("内存进程采集尚未就绪，或关闭后仍发布快照。\n", stderr)
            exit(1)
        }
    }

    /// 在有限时间内运行真实采集器，输出每个总量帧的 JSON，结束后验证子进程清理。
    static func sample(seconds: Double, ranking: Bool) {
        let monitor = NetworkMonitor()
        var count = 0
        var lastTime: TimeInterval?
        monitor.onUpdate = {
            guard let sampleTime = monitor.lastSampleTime, sampleTime != lastTime else { return }
            lastTime = sampleTime; count += 1
            let top = monitor.sortedApplications.prefix(5).map { app -> [String: Any] in
                ["name": app.name, "download_Bps": app.download, "upload_Bps": app.upload, "processes": app.processes]
            }
            let result: [String: Any] = ["sample": count, "download_Bps": monitor.download ?? -1,
                                         "upload_Bps": monitor.upload ?? -1, "interfaces": monitor.activeInterfaces,
                                         "status": monitor.status, "top": top,
                                         "uptime": sampleTime, "interval_seconds": monitor.preferences.interval,
                                         "direct_receive_Bps": monitor.directDownload ?? -1,
                                         "direct_send_Bps": monitor.directUpload ?? -1,
                                         "direct_interfaces": monitor.directInterfaces, "direct_status": monitor.directStatus,
                                         "direct_visible": monitor.directActivity.isVisible, "direct_idle": monitor.directActivity.isIdle]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
               let line = String(data: data, encoding: .utf8) { print(line); fflush(stdout) }
        }
        monitor.start()
        if ranking { monitor.setRankingVisible(true) }
        let end = Date().addingTimeInterval(min(120, max(3, seconds)))
        while Date() < end { RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.25))) }
        monitor.shutdown()
        if count == 0 { fputs("未获取可靠采样\n", stderr); exit(1) }
    }
}
