import AppKit

/// 无标题二级面板需要接收分段控件、滚动和展开操作，因此显式允许成为键盘窗口。
private final class ResourceDetailPanel: NSPanel {
    /// 点击详情中的控件时允许面板成为 key window，父级菜单栏弹窗仍由主程序管理。
    override var canBecomeKey: Bool { true }
    /// 二级详情不是应用主窗口，不参与主窗口选择。
    override var canBecomeMain: Bool { false }
}

/// 覆盖二级浮层完整区域的指针跟踪视图，用于跨一级与二级窗口时取消或启动关闭延迟。
private final class ResourceDetailContainerView: NSVisualEffectView {
    /// 指针进入浮层时取消待执行的关闭任务。
    var onEnter: (() -> Void)?
    /// 指针离开浮层时启动短暂关闭延迟。
    var onExit: (() -> Void)?
    /// 可见范围变化时需要替换的跟踪区域。
    private var hoverTrackingArea: NSTrackingArea?

    /// 创建原生 popover 材质背景，圆角和阴影由窗口及容器分别负责。
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
    }

    /// 二级浮层完全使用代码布局。
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 浮层改变大小或屏幕位置后按当前可见边界重新建立跟踪。
    override func updateTrackingAreas() {
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
        super.updateTrackingAreas()
    }

    /// 进入二级浮层后立即保留窗口，覆盖一级与二级之间的短间隙。
    override func mouseEntered(with event: NSEvent) { onEnter?() }

    /// 离开二级浮层后由协调器确认指针是否进入另一个资源行。
    override func mouseExited(with event: NSEvent) { onExit?() }
}

/// 二级浮层的内容宿主；切换资源时复用同一个窗口，只替换现有详情控制器。
private final class ResourceDetailHostController: NSViewController {
    /// 当前显示的详情控制器，切换时从层级移除但不销毁，以保留控制器自身轻量状态。
    private var current: NSViewController?
    /// 根视图同时负责跨窗口悬浮跟踪。
    let container = ResourceDetailContainerView(frame: .zero)

    /// 宿主没有模型，也不会主动创建任何详情页面。
    override func loadView() { view = container }

    /// 显示指定详情控制器，并为现有 392pt 内容保留 14pt 四周边距。
    func display(_ controller: NSViewController) {
        guard current !== controller else { return }
        clear()
        current = controller
        addChild(controller)
        let child = controller.view
        child.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            child.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            child.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            child.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14)
        ])
    }

    /// 移除当前详情视图和父子关系；实际控制器仍由一级面板强引用并可再次复用。
    func clear() {
        guard let current else { return }
        current.view.removeFromSuperview()
        current.removeFromParent()
        self.current = nil
    }
}

/// 管理唯一二级浮层的展示、资源切换、屏幕边缘定位和跨窗口关闭延迟。
final class ResourceDetailCoordinator {
    /// 资源详情控制器；电量历史生命周期由呈现和关闭回调按需管理。
    private let controllers: [ResourceSection: NSViewController]
    /// 可复用内容宿主，避免资源间移动时反复创建窗口。
    private let host = ResourceDetailHostController()
    /// 唯一二级面板，所有资源共用其位置、阴影和窗口层级。
    private let panel: ResourceDetailPanel
    /// 当前显示的资源类型；nil 表示二级浮层已关闭。
    private(set) var visibleSection: ResourceSection?
    /// 用户点击锁定的资源；锁定期间普通悬浮不能切换或关闭二级详情。
    private var pinnedSection: ResourceSection?
    /// 当前详情的一级锚点，内容高度变化后重新换算其屏幕位置。
    private weak var anchorView: NSView?
    /// 一级内容边界不包含 popover 透明箭头与阴影，用于维持两个浮窗贴边。
    private weak var primaryView: NSView?
    /// 离开一级与二级区域时等待执行的关闭任务。
    private var dismissWorkItem: DispatchWorkItem?
    /// 新详情装入宿主后触发，用于使用既有模型快照即时刷新可见表格。
    var onPresent: ((ResourceSection) -> Void)?
    /// 详情切换或关闭时触发，用于释放隐藏表格行与图标缓存。
    var onDismiss: ((ResourceSection) -> Void)?
    /// 点击锁定或一级关闭时触发，用于同步概览块的持续高亮状态。
    var onPinChange: ((ResourceSection?) -> Void)?

    /// 创建 420pt 宽的浮层；固定高度约容纳七至八行排行。
    init(controllers: [ResourceSection: NSViewController]) {
        self.controllers = controllers
        panel = ResourceDetailPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 315),
                                    styleMask: [.borderless], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.transient, .moveToActiveSpace]
        panel.contentViewController = host
        host.container.onEnter = { [weak self] in self?.cancelDismiss() }
        host.container.onExit = { [weak self] in self?.scheduleDismiss() }
    }

    /// 指针进入时展示详情，点击时锁定；一级内容视图提供不含 popover 透明装饰区的真实边界。
    func present(_ section: ResourceSection, anchoredTo anchor: NSView,
                 relativeTo primaryView: NSView, activate: Bool = false) {
        guard let controller = controllers[section], let parentWindow = anchor.window else { return }
        if !activate, pinnedSection != nil { return }
        anchorView = anchor; self.primaryView = primaryView
        if activate {
            pinnedSection = section
            onPinChange?(section)
        }
        cancelDismiss()
        if visibleSection != section {
            if let previous = visibleSection { onDismiss?(previous) }
            visibleSection = section
            host.display(controller)
            onPresent?(section)
        }
        attachPanel(to: parentWindow)
        positionPanel(beside: anchor, primaryView: primaryView,
                      parentWindow: parentWindow, section: section)
        if activate {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFront(nil)
        }
    }

    /// 离开一级行或二级浮层后等待 250ms，允许指针穿过两个窗口之间的窄间隙。
    func scheduleDismiss() {
        guard pinnedSection == nil else { return }
        dismissWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250), execute: work)
    }

    /// 进入任一有效区域或切换资源时取消尚未执行的关闭任务。
    func cancelDismiss() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
    }

    /// 立即关闭二级浮层并释放当前详情的渲染缓存，模型采样状态保持不变。
    func dismiss() {
        cancelDismiss()
        anchorView = nil; primaryView = nil
        if pinnedSection != nil {
            pinnedSection = nil
            onPinChange?(nil)
        }
        guard let section = visibleSection else {
            panel.orderOut(nil)
            return
        }
        visibleSection = nil
        onDismiss?(section)
        host.clear()
        if let parent = panel.parent { parent.removeChildWindow(panel) }
        panel.orderOut(nil)
    }

    /// 判断本地鼠标事件是否发生在二级浮层内，供一级弹窗的外部点击管理使用。
    func owns(window: NSWindow?) -> Bool { window === panel && panel.isVisible }

    /// 一级浮窗自适应高度后按当前锚点重新定位；未显示详情时不创建窗口或触发采集。
    func reposition() {
        guard let section = visibleSection, let anchor = anchorView, let primaryView,
              let parentWindow = anchor.window else { return }
        positionPanel(beside: anchor, primaryView: primaryView, parentWindow: parentWindow, section: section)
    }

    /// 将浮层附着到当前 popover 窗口，使其随一级窗口移动并始终位于一级之上。
    private func attachPanel(to parentWindow: NSWindow) {
        guard panel.parent !== parentWindow else { return }
        if let previous = panel.parent { previous.removeChildWindow(panel) }
        parentWindow.addChildWindow(panel, ordered: .above)
    }

    /// 优先贴合一级内容右侧，空间不足时自动贴到左侧，并按当前详情固定十行高度。
    private func positionPanel(beside anchor: NSView, primaryView: NSView,
                               parentWindow: NSWindow, section: ResourceSection) {
        let anchorInWindow = anchor.convert(anchor.bounds, to: nil)
        let anchorOnScreen = parentWindow.convertToScreen(anchorInWindow)
        let primaryInWindow = primaryView.convert(primaryView.bounds, to: nil)
        let primaryOnScreen = parentWindow.convertToScreen(primaryInWindow)
        let visibleFrame = (parentWindow.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let margin: CGFloat = 8
        let gap: CGFloat = 0
        let width: CGFloat = 420
        let height = min(fixedHeight(for: section), max(300, visibleFrame.height - margin * 2))
        // OverviewPanelController.view 的边界不包含 NSPopover 窗口的透明箭头和阴影区域。
        let rightX = primaryOnScreen.maxX + gap
        let leftX = primaryOnScreen.minX - gap - width
        let x = rightX + width <= visibleFrame.maxX - margin
            ? rightX
            : max(visibleFrame.minX + margin, leftX)
        let preferredY = anchorOnScreen.maxY - height
        let y = min(max(preferredY, visibleFrame.minY + margin),
                    visibleFrame.maxY - margin - height)
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    /// 趋势固定在排行上方；磁盘三图保留更多高度，电源突出系统耗电，实际尺寸仍受屏幕限制。
    private func fixedHeight(for section: ResourceSection) -> CGFloat {
        switch section {
        case .cpu, .memory: return 490
        case .network: return 510
        case .disk: return 650
        case .power: return 450
        case .fan: return 300
        }
    }
}
