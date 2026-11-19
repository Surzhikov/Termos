import AppKit

/// Lays out children by `node.ratios` with gaps between them; gaps can be dragged to resize.
final class SplitContainerView: NSView {
    // Lives partly under the transparent title bar: clicks here must not move the window.
    override var mouseDownCanMoveWindow: Bool { false }

    static let gap: CGFloat = 6
    static let minSize: CGFloat = 80

    let node: LayoutNode
    var onRatiosChanged: (() -> Void)?
    private var dragIndex: Int?

    init(node: LayoutNode, children: [NSView]) {
        self.node = node
        super.init(frame: .zero)
        children.forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var axis: SplitAxis { node.axis ?? .horizontal }
    private var length: CGFloat { axis == .horizontal ? bounds.width : bounds.height }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let n = subviews.count
        guard n > 0, node.ratios.count == n else { return }
        let gap = SplitContainerView.gap
        let avail = max(0, length - gap * CGFloat(n - 1))
        var pos: CGFloat = 0
        for (i, v) in subviews.enumerated() {
            let size = i == n - 1 ? max(0, length - pos) : (avail * node.ratios[i]).rounded()
            if axis == .horizontal {
                v.frame = NSRect(x: pos, y: 0, width: size, height: bounds.height)
            } else {
                v.frame = NSRect(x: 0, y: pos, width: bounds.width, height: size)
            }
            pos += size + gap
        }
        window?.invalidateCursorRects(for: self)
    }

    /// Gap rectangle after child `i`.
    private func gapRect(_ i: Int) -> NSRect {
        let f = subviews[i].frame
        let g = SplitContainerView.gap
        if axis == .horizontal {
            return NSRect(x: f.maxX - 1, y: 0, width: g + 2, height: bounds.height)
        } else {
            return NSRect(x: 0, y: f.maxY - 1, width: bounds.width, height: g + 2)
        }
    }

    override func resetCursorRects() {
        guard subviews.count > 1 else { return }
        for i in 0..<(subviews.count - 1) {
            addCursorRect(gapRect(i), cursor: axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        if subviews.count > 1 {
            for i in 0..<(subviews.count - 1) where gapRect(i).contains(p) { return self }
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        dragIndex = (0..<max(0, subviews.count - 1)).first { gapRect($0).contains(p) }
        if event.clickCount == 2, dragIndex != nil {
            // Double-click on a divider equalizes.
            node.ratios = Array(repeating: 1 / CGFloat(subviews.count), count: subviews.count)
            needsLayout = true
            onRatiosChanged?()
            dragIndex = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let i = dragIndex else { return }
        let p = convert(event.locationInWindow, from: nil)
        let coord = axis == .horizontal ? p.x : p.y
        let n = subviews.count
        let gap = SplitContainerView.gap
        let avail = max(1, length - gap * CGFloat(n - 1))

        // Start of the (i, i+1) pair and their combined share.
        let start = axis == .horizontal ? subviews[i].frame.minX : subviews[i].frame.minY
        let pairShare = node.ratios[i] + node.ratios[i + 1]
        let pairLen = avail * pairShare
        let minShare = min(SplitContainerView.minSize, pairLen / 2) / avail
        var first = (coord - start - gap / 2) / avail
        first = max(minShare, min(pairShare - minShare, first))
        node.ratios[i] = first
        node.ratios[i + 1] = pairShare - first
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func mouseUp(with event: NSEvent) {
        if dragIndex != nil { onRatiosChanged?() }
        dragIndex = nil
    }
}

/// Area that displays the layout of one workspace.
final class WorkspaceView: NSView {
    // Lives partly under the transparent title bar: clicks here must not move the window.
    override var mouseDownCanMoveWindow: Bool { false }

    var onLayoutChanged: (() -> Void)?
    private var content: NSView?

    override var isFlipped: Bool { true }

    func show(_ ws: Workspace?) {
        // Detach panes from old containers without destroying them.
        content?.removeFromSuperview()
        content = nil
        guard let ws else { return }

        let view: NSView?
        if let zoomed = ws.zoomedPane, ws.root?.find(zoomed) != nil {
            zoomed.removeFromSuperview()
            view = zoomed
        } else if let root = ws.root {
            view = build(root)
        } else {
            view = nil
        }
        if let view {
            addSubview(view)
            content = view
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
    }

    private func build(_ node: LayoutNode) -> NSView {
        if let pane = node.pane {
            pane.removeFromSuperview()
            return pane
        }
        let children = node.children.map(build)
        let split = SplitContainerView(node: node, children: children)
        split.onRatiosChanged = { [weak self] in self?.onLayoutChanged?() }
        return split
    }

    override func layout() {
        super.layout()
        content?.frame = bounds
    }
}
