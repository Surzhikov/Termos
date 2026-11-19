import AppKit

/// Commands available over the control socket (used by the MCP server).
extension AppController {
    func handleControl(_ cmd: String, _ a: [String: Any]) throws -> Any {
        switch cmd {
        case "list":
            return listAll()

        case "create_workspace":
            guard ensureProject(interactive: false) else { throw ControlError("no project is open; use termos_new_project or termos_open_session first") }
            return try createWorkspace(a)

        case "add_terminal":
            guard ensureProject(interactive: false) else { throw ControlError("no project is open; use termos_new_project or termos_open_session first") }
            let ws: Workspace
            if let ref = a.str("workspace") {
                ws = try findWorkspace(ref)
            } else if let cur = current {
                ws = cur
            } else {
                let n = workspaces.count + 1
                ws = Workspace(name: "Workspace \(n)", color: AppController.workspaceColors[0])
                workspaces.append(ws)
            }
            let spec = TerminalSpec(a)
            let pane = makePane(cwd: spec.cwd ?? ws.focusedPane?.cwd, themeId: spec.theme ?? ws.focusedPane?.theme.id,
                                background: spec.background, label: spec.label ?? .none, name: spec.name,
                                command: spec.command)
            let dir = a.str("direction") ?? "right"
            let edge: DropEdge = ["left": .left, "up": .top, "down": .bottom][dir] ?? .right
            if ws.id != selectedId { select(ws) }
            if a.str("next_to") == nil, a.str("direction") == nil, let (anchor, axis) = roomiestSplit(in: ws) {
                // No placement given: wherever there is most room.
                ws.split(anchor, with: pane, axis: axis)
            } else if let anchorRef = a.str("next_to") {
                let anchor = try findPane(anchorRef)
                guard ws.root?.find(anchor) != nil else { throw ControlError("next_to terminal is in another workspace") }
                ws.split(anchor, with: pane, axis: edge.axis, before: edge.before)
            } else if let anchor = ws.focusedPane ?? ws.panes.last {
                ws.split(anchor, with: pane, axis: edge.axis, before: edge.before)
            } else {
                ws.root = LayoutNode(pane: pane)
            }
            ws.zoomedPane = nil
            ws.focusedPane = pane
            select(ws)
            scheduleSave()
            return describe(pane, in: ws)

        case "run":
            let pane = try findPane(try a.req("terminal"))
            let text = try a.req("command")
            pane.terminal.send(txt: text + ((a["enter"] as? Bool ?? true) ? "\r" : ""))
            return "sent"

        case "read":
            let pane = try findPane(try a.req("terminal"))
            let n = max(1, min(2000, a["lines"] as? Int ?? 60))
            let data = pane.terminal.getTerminal().getBufferAsData()
            var lines = (String(data: data, encoding: .utf8) ?? "").components(separatedBy: "\n")
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
            return lines.suffix(n).joined(separator: "\n")

        case "update_terminal":
            let pane = try findPane(try a.req("terminal"))
            if let n = a.str("name") { pane.customName = n.isEmpty ? nil : n }
            if let t = a.str("theme") {
                guard TerminalTheme.all.contains(where: { $0.id == t }) else { throw ControlError("unknown theme \(t)") }
                pane.setTheme(TerminalTheme.byId(t))
            }
            if let bg = a.str("background") {
                guard let c = NSColor(hex: bg) else { throw ControlError("background must be a hex color") }
                pane.setCustomBackground(c)
            }
            if let l = a.str("label") { pane.borderLabel = try parseLabel(l) }
            if let c = a["startup_command"] as? String { pane.startupCommand = c.isEmpty ? nil : c }
            return describe(pane, in: workspace(of: pane))

        case "update_workspace":
            let ws = try findWorkspace(try a.req("workspace"))
            if let n = a.str("name"), !n.isEmpty { ws.name = n }
            if let c = a.str("color") { ws.color = try parseColor(c) }
            if ws.id == selectedId { window.title = ws.name }
            scheduleSave()
            return describe(ws)

        case "focus":
            if let t = a.str("terminal") {
                let pane = try findPane(t)
                if pane.isHeld, a["restore"] as? Bool == true { pane.restore() }
                focus(pane)
            } else if let w = a.str("workspace") { select(try findWorkspace(w)) }
            return "ok"

        case "freeze_terminal":
            let pane = try findPane(try a.req("terminal"))
            pane.freeze()
            return describe(pane, in: workspace(of: pane))

        case "restore_terminal":
            let pane = try findPane(try a.req("terminal"))
            pane.restore()
            return describe(pane, in: workspace(of: pane))

        case "open_session":
            let url = URL(fileURLWithPath: (try a.req("path") as NSString).expandingTildeInPath)
            openProject(from: url)
            return workspaces.map(describe)

        case "new_project":
            let url = URL(fileURLWithPath: (try a.req("path") as NSString).expandingTildeInPath)
            startProject(at: url)
            return workspaces.map(describe)

        case "close_terminal":
            let pane = try findPane(try a.req("terminal"))
            if pane.hasRunningProgram, a["force"] as? Bool != true {
                throw ControlError("“\(pane.foregroundProcess ?? "a program")” is running in this terminal; pass force: true to close it anyway")
            }
            close(pane)
            return "closed"

        case "close_workspace":
            let ws = try findWorkspace(try a.req("workspace"))
            let busy = ws.panes.filter(\.hasRunningProgram)
            if !busy.isEmpty, a["force"] as? Bool != true {
                throw ControlError("programs are running in \(busy.count) terminal(s); pass force: true to close anyway")
            }
            closeWorkspace(ws, confirm: false)
            return "closed"

        case "save_layout":
            let url = URL(fileURLWithPath: (try a.req("path") as NSString).expandingTildeInPath)
            try Persistence.write(AppSnapshot(workspaces: workspaces.map(Persistence.snapshot),
                                              selected: selectedId, sidebarCollapsed: nil), to: url)
            return "saved \(workspaces.count) workspace(s) to \(url.path)"

        case "open_layout":
            // A layout file is now opened as the project of this window.
            let url = URL(fileURLWithPath: (try a.req("path") as NSString).expandingTildeInPath)
            openProject(from: url)
            return workspaces.map(describe)

        default:
            throw ControlError("unknown command \(cmd)")
        }
    }

    // MARK: - Workspace grid

    private func createWorkspace(_ a: [String: Any]) throws -> Any {
        let specs = (a["terminals"] as? [[String: Any]] ?? []).map(TerminalSpec.init)
        let count = max(1, specs.count)
        var cols = a["columns"] as? Int ?? 0
        var rows = a["rows"] as? Int ?? 0
        if cols <= 0 && rows <= 0 {
            cols = Int(Double(count).squareRoot().rounded(.up))
            rows = Int((Double(count) / Double(cols)).rounded(.up))
        } else if cols <= 0 {
            cols = Int((Double(count) / Double(rows)).rounded(.up))
        } else if rows <= 0 {
            rows = Int((Double(count) / Double(cols)).rounded(.up))
        }
        guard cols * rows >= count else {
            throw ControlError("\(count) terminals don't fit into \(cols)×\(rows); create several workspaces")
        }
        guard cols <= 8, rows <= 6 else { throw ControlError("grid is limited to 8 columns × 6 rows") }

        let n = workspaces.count + 1
        let color = try a.str("color").map(parseColor)
            ?? AppController.workspaceColors[(n - 1) % AppController.workspaceColors.count]
        let ws = Workspace(name: a.str("name") ?? "Workspace \(n)", color: color)

        let panes: [PaneView] = (0..<count).map { i in
            let s = i < specs.count ? specs[i] : TerminalSpec([:])
            return makePane(cwd: s.cwd ?? a.str("cwd"), themeId: s.theme ?? a.str("theme"), background: s.background,
                            label: s.label ?? .none, name: s.name, command: s.command)
        }
        // Rows top to bottom, each row split into columns; the last row may be shorter.
        var rowNodes: [LayoutNode] = []
        for r in 0..<rows {
            let slice = Array(panes.dropFirst(r * cols).prefix(cols))
            if slice.isEmpty { break }
            let leaves = slice.map { LayoutNode(pane: $0) }
            rowNodes.append(leaves.count == 1 ? leaves[0] : LayoutNode(axis: .horizontal, children: leaves))
        }
        ws.root = rowNodes.count == 1 ? rowNodes[0] : LayoutNode(axis: .vertical, children: rowNodes)
        ws.focusedPane = panes.first
        workspaces.append(ws)
        select(ws)
        scheduleSave()
        return describe(ws)
    }

    // MARK: - Lookup and description

    static func shortId(_ id: UUID) -> String { String(id.uuidString.prefix(8)).lowercased() }

    func findWorkspace(_ ref: String) throws -> Workspace {
        let r = ref.lowercased()
        if let w = workspaces.first(where: { AppController.shortId($0.id) == r || $0.id.uuidString.lowercased() == r }) { return w }
        let byName = workspaces.filter { $0.name.lowercased() == r }
        if byName.count == 1 { return byName[0] }
        if byName.count > 1 { throw ControlError("several workspaces are named “\(ref)”; use the id") }
        throw ControlError("no workspace “\(ref)”")
    }

    func findPane(_ ref: String) throws -> PaneView {
        let r = ref.lowercased()
        let all = workspaces.flatMap(\.panes)
        if let p = all.first(where: { AppController.shortId($0.id) == r || $0.id.uuidString.lowercased() == r }) { return p }
        let byName = all.filter { $0.customName?.lowercased() == r || $0.displayTitle.lowercased() == r }
        if byName.count == 1 { return byName[0] }
        if byName.count > 1 { throw ControlError("several terminals match “\(ref)”; use the id") }
        throw ControlError("no terminal “\(ref)”")
    }

    private func listAll() -> Any {
        [
            "workspaces": workspaces.map(describe),
            "selected_workspace": selectedId.map(AppController.shortId) as Any,
        ]
    }

    func describe(_ ws: Workspace) -> [String: Any] {
        [
            "id": AppController.shortId(ws.id),
            "name": ws.name,
            "color": ws.color.hexString,
            "selected": ws.id == selectedId,
            "terminals": ws.panes.map { describe($0, in: ws) },
        ]
    }

    func describe(_ p: PaneView, in ws: Workspace?) -> [String: Any] {
        var d: [String: Any] = [
            "id": AppController.shortId(p.id),
            "title": p.displayTitle,
            "cwd": p.cwd,
            "theme": p.theme.id,
            "label": p.borderLabel.rawValue,
            "focused": ws?.focusedPane === p,
        ]
        if let n = p.customName { d["name"] = n }
        if p.isHeld { d["held"] = true }
        if let fg = p.foregroundProcess { d["running"] = fg }
        if let c = p.startupCommand { d["startup_command"] = c }
        if let bg = p.customBackground { d["background"] = bg.hexString }
        return d
    }

    private func parseLabel(_ s: String) throws -> BorderLabel {
        guard let l = BorderLabel(rawValue: s.lowercased()) else {
            throw ControlError("label must be one of \(BorderLabel.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return l
    }

    private func parseColor(_ s: String) throws -> NSColor {
        if let l = BorderLabel(rawValue: s.lowercased()), let c = l.color { return c }
        if let c = NSColor(hex: s) { return c }
        throw ControlError("color must be a hex value or one of red, orange, yellow, green, blue, purple, pink")
    }
}

/// Terminal description passed by MCP tools.
struct TerminalSpec {
    var name, cwd, command, theme: String?
    var label: BorderLabel?
    var background: NSColor?

    init(_ a: [String: Any]) {
        name = a.str("name")
        cwd = a.str("cwd").map { ($0 as NSString).expandingTildeInPath }
        command = a.str("command")
        theme = a.str("theme").flatMap { t in TerminalTheme.all.first { $0.id == t }?.id }
        label = a.str("label").flatMap { BorderLabel(rawValue: $0.lowercased()) }
        background = a.str("background").flatMap(NSColor.init(hex:))
    }
}

extension Dictionary where Key == String, Value == Any {
    func str(_ key: String) -> String? {
        guard let s = self[key] as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    func req(_ key: String) throws -> String {
        guard let s = str(key) else { throw ControlError("missing “\(key)”") }
        return s
    }
}
