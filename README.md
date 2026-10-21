# NetworkSpeedMonitor

一个原生 macOS 菜单栏系统监控工具。随时查看上传下载速度、CPU 和电池状态，点击后进一步了解哪些应用占用资源，以及最近的资源变化。

项目从网速监控扩展而来，目前覆盖网络、CPU、内存、磁盘、电源和风扇，适合日常排查电脑变慢、后台流量、充电状态和耗电变化。

## 主要功能

| 资源 | 可以查看什么 |
| --- | --- |
| 网络 | 实时上传 / 下载速度、应用排行、设备直连流量和趋势 |
| CPU | 整机占用、应用排行、子进程和占用趋势 |
| 内存 | 已用 / 总量、内存压力、应用及子进程占用和趋势 |
| 磁盘 | 系统盘容量、整机读写趋势、应用读写排行 |
| 电源 | 电量、续航 / 充满时间、充放电功率、容量健康估算和循环次数 |
| 风扇 | 实际风扇数量、转速和趋势；无风扇机型自动隐藏 |

菜单栏可以分别显示 CPU、网络和电池，至少保留一项。支持 1 / 2 / 5 秒的统一采样设置、独立设置各类排行数量，以及登录后自动启动。后台功率和风扇至少间隔 5 秒读取，磁盘容量至少间隔 10 秒读取。

## 使用方法

1. 点击菜单栏监控按钮，打开资源概览。
2. 把鼠标移到资源区域，侧边显示对应排行和趋势。
3. 点击资源区域可锁定详情，避免鼠标移动时切换；关闭概览后解除锁定。
4. 在“设置…”中调整采样间隔、菜单栏内容、物理网络及排行数量。
5. 如需更多系统进程数据，在设置或资源区域中授权管理员采集服务。

CPU 和内存排行支持展开查看子进程。网络、CPU、内存、磁盘排行可分别设置为 1～50 项，默认分别为 10 / 10 / 10 / 5 项。概览底部也可直接打开系统活动监视器。

## 趋势与电量历史

资源趋势可查看最近 1 分钟、10 分钟、1 小时或 24 小时，默认显示 1 分钟。程序只记录实际采集到的整机资源数值，休眠、采样失败和数据缺口会使曲线断开。

资源历史保存在本机 `~/Library/Application Support/NetworkSpeedMonitor/History.sqlite`，约每分钟批量写入，查询范围限定为最近 24 小时。概览关闭期间，功率和风扇仍会低频采样以保留趋势；锁屏、息屏和休眠时暂停。历史只保存整机标量，不保存应用排行或连接明细。

在电源详情中切换到“电量历史”，可查看 1 小时、10 小时、24 小时或 7 天的电量百分比记录，默认 10 小时。这些记录单独读取自 macOS 已有的 Powerlog；工具不自行建立电量百分比采集库。系统记录缺失或权限不支持时会显示缺口或不可用。

## 环境与安装

- macOS 13 或更新版本。
- Xcode Command Line Tools；使用 Swift、C 和系统框架，无第三方包依赖。
- 风扇、详细功率和系统历史的可用性取决于机型及 macOS 版本。

在项目目录执行：

```bash
./scripts/build.sh --run
```

脚本构建、校验并安装到 `/Applications/NetworkSpeedMonitor.app`，随后启动应用。只安装可使用 `--install`；不传参数只进行构建检查，临时构建包会在退出时清理。

当前构建依赖作者本机已有的 `InputHoldSwitcher Local Code Signing` 证书，缺少该证书时会停止。其他 Mac 需要适配 [构建脚本](scripts/build.sh)、[主程序签名约束](Info.plist) 和 [辅助服务签名约束](Helper/Info.plist)，使主程序与服务使用一致的稳定身份。

主程序 Bundle ID 为 `com.local.NetworkSpeedMonitor`。更新时保留证书、标识和固定安装位置，以维持系统授权。

## 权限与数据

普通权限即可查看整机资源概览和当前用户可读的部分进程。读取系统及其他用户的完整 CPU、内存、磁盘进程排行时，需要通过 macOS 管理员认证安装只读辅助服务；应用不接触或保存管理员密码。

辅助服务为 `com.local.NetworkSpeedMonitor.CPUHelper`，安装在 `/Library/PrivilegedHelperTools/`，通过双向签名校验的 XPC 接口提供统计。进程排行主要在概览打开时采集，关闭后释放连接，服务空闲后退出。

监控统计及资源历史仅用于本机展示，不上传统计、不抓取网络报文内容。详细功率、风扇和部分网络接口依赖系统内部实现，系统升级后可能需要兼容性调整。

## 如何理解统计结果

- CPU 占用按整机逻辑核心数归一化，整机满负载表示 100%。
- 应用内存以进程 physical footprint 聚合；排行合计不等于整机已用内存。
- 网络总量包含普通物理网络与设备直连，排除回环和 VPN 虚拟接口，避免隧道内外重复计数。应用排行与接口总量属于不同统计层。
- “设备直连”可能包含隔空投送和后台设备通信，出现该行不代表一定在传文件。
- 磁盘应用排行统计进程读写，与整块物理 SSD 的吞吐量不必相等。
- 适配器能力不等于实际输入功率；系统功率估算不等于插座侧实测功率。估算值以 `≈` 标记，不可用值显示 `—`。

## 常见问题

**首次启动网速显示短横线？** 程序需要建立计数基线。启动、修改采样间隔或唤醒后，等待一轮有效采样。

**排行缺少部分进程？** 检查是否启用了管理员采集；受系统保护或在采样期间退出的进程仍可能无法读取，界面会显示实际覆盖状态。

**没有风扇或详细功率？** 无风扇机型会隐藏风扇区域，部分机型和系统版本没有可用的详细遥测字段。

**历史曲线不完整？** 本应用的资源历史从运行时开始积累；电量历史来自系统已有记录。休眠、未运行、记录清理或读取失败都会留下真实缺口。

## 诊断与源码

已安装应用提供有限时长的只读 JSON 诊断入口，例如：

```bash
/Applications/NetworkSpeedMonitor.app/Contents/MacOS/NetworkSpeedMonitor --self-check
/Applications/NetworkSpeedMonitor.app/Contents/MacOS/NetworkSpeedMonitor --diagnose 12 --with-ranking
/Applications/NetworkSpeedMonitor.app/Contents/MacOS/NetworkSpeedMonitor --cpu-diagnose 12 --with-ranking
/Applications/NetworkSpeedMonitor.app/Contents/MacOS/NetworkSpeedMonitor --power-history-diagnose
```

其他入口见 [main.swift](Sources/main.swift)。资源历史见 [TrendHistory.swift](Sources/TrendHistory.swift)，采样见 [TrendSampler.swift](Sources/TrendSampler.swift)，界面设置见 [SettingsController.swift](Sources/SettingsController.swift)。
