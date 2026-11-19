import AppKit
import UniformTypeIdentifiers

/// State snapshot persisted between launches.
struct AppSnapshot: Codable {
    var workspaces: [WorkspaceSnapshot]
    var selected: UUID?
    var sidebarCollapsed: Bool?
}

struct WorkspaceSnapshot: Codable {
    var id: UUID
    var name: String
    var color: String
    var root: NodeSnapshot?
    var focused: UUID?
}

indirect enum NodeSnapshot: Codable {
    case pane(PaneSnapshot)
    case split(axis: SplitAxis, ratios: [Double], children: [NodeSnapshot])
}

struct PaneSnapshot: Codable {
    var id: UUID
    var cwd: String
    var theme: String
    var background: String?
    var label: BorderLabel
    var name: String?
    var fontSize: Double
    var command: String?
    /// Terminal frozen (process killed, placeholder shown until Restore).
    var held: Bool?
}

enum Persistence {
    /// Root directory of the per-instance state. TERMOS_STATE_DIR lets extra windows
    /// and test instances run without touching the real state.
    static var stateRoot: URL {
        let dir = ProcessInfo.processInfo.environment["TERMOS_STATE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Termos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var fileURL: URL {
        stateRoot.appendingPathComponent("state.json")
    }

    /// State dirs of extra windows (New Window). Each window gets its own, so several
    /// instances don't overwrite each other's autosave / previous session.
    static var extraWindowsDir: URL {
        stateRoot.appendingPathComponent("windows", isDirectory: true)
    }

    static var previousSessionURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("previous-session.json")
    }

    /// Moves the autosave of the last run aside so the new run starts clean.
    static func archiveLastSession() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }
        // A run that ended with nothing open must not overwrite the last real session.
        guard let last = try? read(from: fileURL), !last.workspaces.isEmpty else {
            try? fm.removeItem(at: fileURL)
            return
        }
        try? fm.removeItem(at: previousSessionURL)
        try? fm.moveItem(at: fileURL, to: previousSessionURL)
    }

    static func loadPreviousSession() -> AppSnapshot? {
        try? read(from: previousSessionURL)
    }

    static func save(_ s: AppSnapshot) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(s) { try? data.write(to: fileURL, options: .atomic) }
    }

    // MARK: - Layout files (.termos)

    static let fileExtension = "termos"
    static var contentType: UTType { UTType(filenameExtension: fileExtension, conformingTo: .json) ?? .json }

    static func write(_ s: AppSnapshot, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(s).write(to: url, options: .atomic)
    }

    static func read(from url: URL) throws -> AppSnapshot {
        try JSONDecoder().decode(AppSnapshot.self, from: Data(contentsOf: url))
    }

    // MARK: - Model → snapshot

    static func snapshot(_ ws: Workspace) -> WorkspaceSnapshot {
        WorkspaceSnapshot(id: ws.id, name: ws.name, color: ws.color.hexString,
                          root: ws.root.map(snapshot), focused: ws.focusedPane?.id)
    }

    static func snapshot(_ node: LayoutNode) -> NodeSnapshot {
        if let p = node.pane {
            return .pane(PaneSnapshot(id: p.id, cwd: p.cwd, theme: p.theme.id,
                                      background: p.customBackground?.hexString, label: p.borderLabel,
                                      name: p.customName, fontSize: Double(p.fontSize),
                                      command: p.startupCommand, held: p.isHeld ? true : nil))
        }
        return .split(axis: node.axis ?? .horizontal, ratios: node.ratios.map(Double.init),
                      children: node.children.map(snapshot))
    }

    // MARK: - Snapshot → model

    static func restore(_ s: NodeSnapshot, makePane: (PaneSnapshot) -> PaneView) -> LayoutNode {
        switch s {
        case .pane(let p):
            return LayoutNode(pane: makePane(p))
        case .split(let axis, let ratios, let children):
            let nodes = children.map { restore($0, makePane: makePane) }
            var r = ratios.map { CGFloat($0) }
            if r.count != nodes.count { r = Array(repeating: 1 / CGFloat(nodes.count), count: nodes.count) }
            return LayoutNode(axis: axis, children: nodes, ratios: r)
        }
    }
}
