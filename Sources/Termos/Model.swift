import AppKit

enum SplitAxis: String, Codable {
    /// Panes laid out left to right.
    case horizontal
    /// Panes laid out top to bottom.
    case vertical
}

/// Layout tree node: either a terminal pane or a split into several children.
final class LayoutNode {
    enum Kind {
        case pane(PaneView)
        case split(SplitAxis)
    }

    var kind: Kind
    var children: [LayoutNode] = []
    /// Size fractions of the children (sum = 1).
    var ratios: [CGFloat] = []
    weak var parent: LayoutNode?

    init(pane: PaneView) { kind = .pane(pane) }
    init(axis: SplitAxis, children: [LayoutNode], ratios: [CGFloat]? = nil) {
        kind = .split(axis)
        self.children = children
        self.ratios = ratios ?? Array(repeating: 1 / CGFloat(children.count), count: children.count)
        children.forEach { $0.parent = self }
    }

    var pane: PaneView? { if case .pane(let p) = kind { return p } else { return nil } }
    var axis: SplitAxis? { if case .split(let a) = kind { return a } else { return nil } }

    var allPanes: [PaneView] {
        if let p = pane { return [p] }
        return children.flatMap { $0.allPanes }
    }

    func find(_ pane: PaneView) -> LayoutNode? {
        if self.pane === pane { return self }
        for c in children { if let f = c.find(pane) { return f } }
        return nil
    }
}

/// Workspace: a group of terminals with its own layout.
final class Workspace: ObservableObject, Identifiable {
    let id: UUID
    @Published var name: String
    @Published var color: NSColor
    @Published var root: LayoutNode?
    /// Focused pane in this workspace.
    weak var focusedPane: PaneView?
    /// Pane zoomed to fill the workspace (like tmux zoom).
    weak var zoomedPane: PaneView?
    /// Change counter used to refresh the sidebar.
    @Published var revision = 0

    init(id: UUID = UUID(), name: String, color: NSColor) {
        self.id = id
        self.name = name
        self.color = color
    }

    var panes: [PaneView] { root?.allPanes ?? [] }

    func touch() { revision &+= 1 }

    // MARK: - Tree operations

    /// Splits `target` and inserts `newPane` after it.
    /// `before: true` puts the new pane to the left of / above the target.
    func split(_ target: PaneView, with newPane: PaneView, axis: SplitAxis, before: Bool = false) {
        guard let node = root?.find(target) else {
            root = LayoutNode(pane: newPane)
            return
        }
        let newNode = LayoutNode(pane: newPane)
        if let parent = node.parent, parent.axis == axis, let idx = parent.children.firstIndex(where: { $0 === node }) {
            // Halve the current pane's share; siblings keep their sizes.
            let half = parent.ratios[idx] / 2
            parent.ratios[idx] = half
            parent.children.insert(newNode, at: before ? idx : idx + 1)
            parent.ratios.insert(half, at: before ? idx : idx + 1)
            newNode.parent = parent
        } else {
            // Replace the leaf with a two-way split.
            let parent = node.parent
            let idx = parent?.children.firstIndex(where: { $0 === node })
            let split = LayoutNode(axis: axis, children: before ? [newNode, node] : [node, newNode])
            split.parent = parent
            if let parent, let idx {
                parent.children[idx] = split
            } else {
                root = split
            }
        }
        touch()
    }

    /// Removes a pane from the tree, collapsing redundant splits.
    func remove(_ pane: PaneView) {
        guard let node = root?.find(pane) else { return }
        if zoomedPane === pane { zoomedPane = nil }
        defer { if focusedPane === pane { focusedPane = panes.first } }
        guard let parent = node.parent, let idx = parent.children.firstIndex(where: { $0 === node }) else {
            root = nil
            touch()
            return
        }
        let freed = parent.ratios[idx]
        parent.children.remove(at: idx)
        parent.ratios.remove(at: idx)
        // Give the freed space to a neighbor.
        let neighbor = min(idx, parent.children.count - 1)
        parent.ratios[neighbor] += freed

        if parent.children.count == 1 {
            let only = parent.children[0]
            if let grand = parent.parent, let pIdx = grand.children.firstIndex(where: { $0 === parent }) {
                // If the only child is a split on the grandparent's axis, merge it in.
                if let a = only.axis, a == grand.axis {
                    let share = grand.ratios[pIdx]
                    grand.children.remove(at: pIdx)
                    grand.ratios.remove(at: pIdx)
                    for (i, c) in only.children.enumerated() {
                        grand.children.insert(c, at: pIdx + i)
                        grand.ratios.insert(only.ratios[i] * share, at: pIdx + i)
                        c.parent = grand
                    }
                } else {
                    grand.children[pIdx] = only
                    only.parent = grand
                }
            } else {
                root = only
                only.parent = nil
            }
        }
        touch()
    }

    /// Equalizes all fractions in the tree.
    func equalize() {
        func walk(_ n: LayoutNode) {
            if !n.children.isEmpty {
                n.ratios = Array(repeating: 1 / CGFloat(n.children.count), count: n.children.count)
                n.children.forEach(walk)
            }
        }
        if let root { walk(root) }
        touch()
    }
}
