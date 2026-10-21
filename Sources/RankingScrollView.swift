import AppKit

/// 排行专用滚动区域：按实际可见宽度分配列宽，仅允许纵向滚动，数字列不随长名称扩展。
final class RankingScrollView: NSScrollView {
    /// 名称列之后各数字列的固定宽度；网络为下载 / 上传，CPU 为整机占比。
    private let numberColumnWidths: [CGFloat]
    /// 调整文档宽度可能触发 AppKit 再次排布，避免嵌套回调重复修改列宽。
    private var fittingColumns = false

    /// 数字列保留完整单位与右侧留白，名称列使用剩余空间；保留系统纵向滚动条风格。
    init(numberColumnWidths: [CGFloat]) {
        self.numberColumnWidths = numberColumnWidths
        super.init(frame: .zero)
        hasVerticalScroller = true; autohidesScrollers = true
        hasHorizontalScroller = false; horizontalScrollElasticity = .none
        drawsBackground = false; borderType = .noBorder
    }

    /// 排行区域仅通过代码创建。
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 系统滚动条出现、隐藏或切换风格时，使用排布完成后的真实视口宽度重新适配。
    override func tile() {
        super.tile()
        fitColumns()
    }

    /// 响应父布局约束和弹窗高度变化，不依赖数据刷新或额外计时器来修正列宽。
    override func layout() {
        super.layout()
        fitColumns()
    }

    /// 表格宽度包含每列的 intercellSpacing；先预留数字列，再让名称吸收剩余宽度。
    private func fitColumns() {
        guard !fittingColumns, let table = documentView as? NSTableView,
              table.tableColumns.count == numberColumnWidths.count + 1 else { return }
        fittingColumns = true
        defer { fittingColumns = false }
        // 自动样式可能采用 inset 并额外扩展左右留白，plain 才能让列宽总和严格匹配视口。
        if table.style != .plain { table.style = .plain }
        let viewportWidth = floor(contentView.bounds.width)
        let spacing = table.intercellSpacing.width * CGFloat(table.tableColumns.count)
        let nameWidth = viewportWidth - spacing - numberColumnWidths.reduce(0, +)
        guard nameWidth > 0 else { return }
        for (column, width) in zip(table.tableColumns, [nameWidth] + numberColumnWidths) {
            if abs(column.width - width) > 0.01 { column.width = width }
        }
        // 文档不得比可见区域更宽；拖动横向滚轮也不能把名称或数值移到视口之外。
        if abs(table.frame.width - viewportWidth) > 0.01 {
            table.setFrameSize(NSSize(width: viewportWidth, height: table.frame.height))
        }
        if contentView.bounds.origin.x != 0 {
            contentView.scroll(to: NSPoint(x: 0, y: contentView.bounds.origin.y))
            reflectScrolledClipView(contentView)
        }
    }
}
