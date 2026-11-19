import AppKit
import SwiftUI

enum FocusDirection { case left, right, up, down }

/// Central controller: workspaces, focus, menu commands, persistence.
final class AppController: NSObject, ObservableObject, PaneViewDelegate, NSWindowDelegate {
    @Published var workspaces: [Workspace] = [] {
        didSet { emptyView?.isHidden = !workspaces.isEmpty }
    }
    /// Shown in place of the terminals when there are no workspaces.
    private var emptyView: NSView?
    @Published private(set) var selectedId: UUID?
    @Published var dimInactive: Bool = UserDefaults.standard.object(forKey: "dimInactive") as? Bool ?? true {
        didSet { UserDefaults.standard.set(dimInactive, forKey: "dimInactive"); refreshFocusVisuals() }
    }

    let workspaceView = WorkspaceView()
    private(set) var window: TermosWindow!
    private var splitVC: NSSplitViewController!
    private var sidebarItem: NSSplitViewItem!
    private var saveScheduled = false
    private var controlServer: ControlServer?
    /// Layout file the current session was opened from / saved to. While set, every change
    /// is written to it, so the file always mirrors the live state (held terminals included).
    @Published var sessionFileURL: URL?

    static let workspaceColors: [NSColor] = BorderLabel.allCases.compactMap(\.color)

    var current: Workspace? { workspaces.first { $0.id == selectedId } }
    var focusedPane: PaneView? { current?.focusedPane }

    // MARK: - Startup

    func start() {
        buildWindow()
        controlServer = ControlServer { [weak self] cmd, args in
            guard let self else { throw ControlError("app is shutting down") }
            return try self.handleControl(cmd, args)
        }
        controlServer?.infoProvider = { [weak self] in
            // Shown by the MCP server when several Termos instances are running,
            // so the user can tell them apart by their workspaces.
            ["workspaces": self?.workspaces.map(\.name) ?? []]
        }
        controlServer?.start()
        workspaceView.onLayoutChanged = { [weak self] in self?.scheduleSave() }

        // Always start clean: pick a project (new or existing) to work in, like VS Code.
        if let collapsed = (try? Persistence.read(from: Persistence.fileURL))?.sidebarCollapsed, collapsed {
            sidebarItem.isCollapsed = true
        }
        // Start empty: no workspaces, no terminals.
        showNothing()
        if ProcessInfo.processInfo.environment["TERMOS_BACKGROUND"] != nil {
            window.orderBack(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func buildWindow() {
        let w = TermosWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
        w.controller = self
        // A regular title bar strip (in the window's color) above everything: the window is dragged
        // by it like any Mac window, and no terminal sits underneath it. It shows the workspace name.
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .visible
        w.title = "Termos"
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = NSColor(hex: "121316")!
        w.collectionBehavior.insert(.fullScreenPrimary)
        w.minSize = NSSize(width: 600, height: 400)
        w.delegate = self
        w.isReleasedWhenClosed = false

        let sidebarVC = NSHostingController(rootView: SidebarView(app: self))
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 190
        sidebarItem.maximumThickness = 360
        sidebarItem.canCollapse = true

        let contentVC = ContentViewController(workspaceView: workspaceView)
        let empty = NSHostingView(rootView: EmptyStateView(app: self))
        contentVC.emptyView = empty
        emptyView = empty
        let contentItem = NSSplitViewItem(viewController: contentVC)
        contentItem.minimumThickness = 300

        splitVC = NSSplitViewController()
        splitVC.splitView.autosaveName = "TermosMainSplit"
        splitVC.addSplitViewItem(sidebarItem)
        splitVC.addSplitViewItem(contentItem)
        contentVC.sidebarItem = sidebarItem

        w.contentViewController = splitVC
        w.setContentSize(NSSize(width: 1280, height: 800))
        if !w.setFrameUsingName("TermosMainWindow") { w.center() }
        w.setFrameAutosaveName("TermosMainWindow")
        window = w
    }

    /// Builds a live workspace (starting its shells) from a snapshot.
    /// `freshIds` is used for imports so the same file can be opened several times.
    func makeWorkspace(_ ws: WorkspaceSnapshot, freshIds: Bool) -> Workspace {
        let w = Workspace(id: freshIds ? UUID() : ws.id, name: ws.name,
                          color: NSColor(hex: ws.color) ?? AppController.workspaceColors[0])
        var focusedNew: PaneView?
        if let root = ws.root {
            w.root = Persistence.restore(root) { p in
                let pane = makePane(id: freshIds ? UUID() : p.id, cwd: p.cwd, themeId: p.theme,
                                    background: p.background.flatMap(NSColor.init(hex:)), label: p.label,
                                    name: p.name, fontSize: CGFloat(p.fontSize), command: p.command,
                                    held: p.held == true)
                if p.id == ws.focused { focusedNew = pane }
                return pane
            }
        }
        if w.root == nil { w.root = LayoutNode(pane: makePane(cwd: nil, themeId: nil)) }
        w.focusedPane = focusedNew ?? w.panes.first
        return w
    }

    // MARK: - Projects

    /// A project is a .termos file holding all workspaces. While it is open, every change
    /// is written to it automatically. Working without a project is not allowed.
    /// From the control socket (MCP) never asks: just reports failure.
    @discardableResult
    func ensureProject(interactive: Bool = true) -> Bool {
        if sessionFileURL != nil { return true }
        guard interactive, let url = newProjectPanel() else { return false }
        startProject(at: url)
        return true
    }

    private func newProjectPanel() -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Persistence.contentType]
        panel.nameFieldStringValue = "Project.termos"
        panel.message = "Choose where to save the new project"
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Creates a fresh project: clears everything, starts with one workspace, saves the file.
    func startProject(at url: URL) {
        workspaces.flatMap(\.panes).forEach { $0.terminate(); $0.removeFromSuperview() }
        workspaces.removeAll()
        sessionFileURL = url
        newWorkspace(nil)
        saveNow()
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    /// Replaces everything with the project from a file and keeps the file updated live.
    func openProject(from url: URL) {
        guard let snap = try? Persistence.read(from: url), !snap.workspaces.isEmpty else {
            NSAlert(error: ControlError("could not read a project from \(url.path)")).runModal()
            return
        }
        workspaces.flatMap(\.panes).forEach { $0.terminate(); $0.removeFromSuperview() }
        workspaces.removeAll()
        let added = snap.workspaces.map { makeWorkspace($0, freshIds: false) }
        workspaces.append(contentsOf: added)
        sessionFileURL = url
        if let sel = snap.selected, let ws = workspaces.first(where: { $0.id == sel }) {
            select(ws)
        } else {
            select(added[0])
        }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    // MARK: - Saving

    func scheduleSave() {
        guard sessionFileURL != nil else { return }  // nothing to save without a project
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.saveScheduled = false
            self?.saveNow()
        }
    }

    func saveNow() {
        controlServer?.writeInfo()  // workspace names may have changed (used by MCP discovery)
        guard let url = sessionFileURL else { return }
        let snap = AppSnapshot(workspaces: workspaces.map(Persistence.snapshot),
                               selected: selectedId,
                               sidebarCollapsed: sidebarItem?.isCollapsed)
        // The project file always mirrors the live state (held terminals included).
        try? Persistence.write(snap, to: url)
    }

    func shutdown() {
        controlServer?.stop()
        saveNow()
        workspaces.flatMap(\.panes).forEach { $0.terminate() }
    }

    // MARK: - Panes

    func makePane(id: UUID = UUID(), cwd: String?, themeId: String?, background: NSColor? = nil,
                          label: BorderLabel = .none, name: String? = nil, fontSize: CGFloat = 13,
                          command: String? = nil, held: Bool = false) -> PaneView {
        let p = PaneView(id: id, cwd: cwd, themeId: themeId, customBackground: background,
                         borderLabel: label, customName: name, fontSize: fontSize)
        p.startupCommand = command
        p.delegate = self
        if held {
            p.startShellIfNeeded()
            p.freeze()
        } else {
            p.startShell()
        }
        return p
    }

    func workspace(of pane: PaneView) -> Workspace? {
        workspaces.first { $0.root?.find(pane) != nil }
    }

    func focus(_ pane: PaneView) {
        guard let ws = workspace(of: pane) else { return }
        if ws.id != selectedId {
            ws.focusedPane = pane
            select(ws)
            return
        }
        if ws.zoomedPane != nil, ws.zoomedPane !== pane {
            ws.zoomedPane = nil
            workspaceView.show(ws)
        }
        ws.focusedPane = pane
        refreshFocusVisuals()
        if !pane.isHeld, window.firstResponder !== pane.terminal { pane.focusTerminal() }
        ws.touch()
    }

    /// Called by the window when a terminal becomes first responder (e.g. on click).
    func terminalBecameFirstResponder(_ pane: PaneView) {
        guard let ws = current, ws.root?.find(pane) != nil, ws.focusedPane !== pane else { return }
        ws.focusedPane = pane
        refreshFocusVisuals()
        ws.touch()
    }

    private func refreshFocusVisuals() {
        guard let ws = current else { return }
        let multiple = ws.panes.count > 1 && ws.zoomedPane == nil
        for p in ws.panes {
            let f = p === ws.focusedPane
            p.isFocused = f
            p.isZoomed = p === ws.zoomedPane
            p.setDimmed(dimInactive && multiple && !f)
        }
    }

    func split(_ axis: SplitAxis, from pane: PaneView? = nil) {
        guard let ws = current, let src = pane ?? ws.focusedPane ?? ws.panes.first else {
            newWorkspace(nil); return
        }
        guard ensureProject() else { return }
        let p = makePane(cwd: src.cwd, themeId: src.theme.id, background: src.customBackground, fontSize: src.fontSize)
        ws.zoomedPane = nil
        ws.split(src, with: p, axis: axis)
        workspaceView.show(ws)
        focus(p)
        scheduleSave()
    }

    /// Adds a terminal to `ws` wherever there is most room: the largest terminal is split
    /// along its longer side (right if it's wide, down if it's tall).
    func addTerminal(to ws: Workspace) {
        guard ensureProject() else { return }
        if ws.id != selectedId { select(ws) }
        ws.zoomedPane = nil
        workspaceView.show(ws)
        guard let (target, axis) = roomiestSplit(in: ws) else {
            let p = makePane(cwd: nil, themeId: nil)
            ws.root = LayoutNode(pane: p)
            workspaceView.show(ws)
            focus(p)
            scheduleSave()
            return
        }
        split(axis, from: target)
    }

    /// The largest terminal in a (visible) workspace and the direction to split it.
    func roomiestSplit(in ws: Workspace) -> (PaneView, SplitAxis)? {
        guard let target = ws.panes.max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height })
        else { return nil }
        // Split side by side unless the terminal is clearly taller than wide.
        let axis: SplitAxis = target.bounds.width >= target.bounds.height * 1.2 ? .horizontal : .vertical
        return (target, axis)
    }

    func close(_ pane: PaneView) {
        guard let ws = workspace(of: pane) else { return }
        let panes = ws.panes
        let idx = panes.firstIndex { $0 === pane } ?? 0
        pane.terminate()
        ws.remove(pane)
        pane.removeFromSuperview()

        if ws.root == nil {
            removeWorkspace(ws)
        } else {
            if ws.focusedPane === pane || ws.focusedPane == nil {
                let rest = ws.panes
                ws.focusedPane = rest[min(max(0, idx - 1), rest.count - 1)]
            }
            if ws.id == selectedId {
                workspaceView.show(ws)
                if let f = ws.focusedPane { focus(f) }
            }
        }
        scheduleSave()
    }

    func toggleZoom(_ pane: PaneView? = nil) {
        guard let ws = current, let p = pane ?? ws.focusedPane else { return }
        ws.zoomedPane = (ws.zoomedPane === p) ? nil : p
        ws.focusedPane = p
        workspaceView.show(ws)
        refreshFocusVisuals()
        p.focusTerminal()
        ws.touch()
    }

    func moveFocus(_ dir: FocusDirection) {
        guard let ws = current, ws.zoomedPane == nil, let from = ws.focusedPane,
              let p = neighbor(of: from, in: ws, dir) else { return }
        focus(p)
    }

    /// Swaps the focused terminal with its neighbor in the given direction.
    func swapFocused(_ dir: FocusDirection) {
        guard let ws = current, ws.zoomedPane == nil, let from = ws.focusedPane,
              let p = neighbor(of: from, in: ws, dir) else { return }
        movePane(from, to: p, edge: .center)
    }

    private func neighbor(of from: PaneView, in ws: Workspace, _ dir: FocusDirection) -> PaneView? {
        let a = from.convert(from.bounds, to: nil)
        var best: (PaneView, CGFloat)?
        for p in ws.panes where p !== from {
            let b = p.convert(p.bounds, to: nil)
            // Window coordinates are not flipped: y grows upward.
            let ok: Bool
            let dist: CGFloat
            let overlap: CGFloat
            switch dir {
            case .left:  ok = b.maxX <= a.minX + 1; dist = a.minX - b.maxX; overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
            case .right: ok = b.minX >= a.maxX - 1; dist = b.minX - a.maxX; overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
            case .up:    ok = b.minY >= a.maxY - 1; dist = b.minY - a.maxY; overlap = min(a.maxX, b.maxX) - max(a.minX, b.minX)
            case .down:  ok = b.maxY <= a.minY + 1; dist = a.minY - b.maxY; overlap = min(a.maxX, b.maxX) - max(a.minX, b.minX)
            }
            guard ok else { continue }
            // Prefer the nearest pane that overlaps on the other axis.
            let score = dist + (overlap > 0 ? 0 : 10_000)
            if best == nil || score < best!.1 { best = (p, score) }
        }
        return best?.0
    }

    // MARK: - Moving terminals

    /// Moves `pane` next to `target` (or swaps them for `.center`). Works across workspaces;
    /// the terminal keeps running, only its view is re-parented.
    func movePane(_ pane: PaneView, to target: PaneView, edge: DropEdge) {
        guard pane !== target, let src = workspace(of: pane), let dst = workspace(of: target) else { return }
        if edge == .center {
            guard let a = src.root?.find(pane), let b = dst.root?.find(target) else { return }
            a.kind = .pane(target)
            b.kind = .pane(pane)
            for ws in [src, dst] {
                ws.zoomedPane = nil
                if ws.focusedPane === pane || ws.focusedPane === target { ws.focusedPane = nil }
            }
            if src !== dst { src.focusedPane = target }
            src.touch()
            finishMove(pane, in: dst)
            return
        }
        detach(pane, from: src)
        dst.zoomedPane = nil
        dst.split(target, with: pane, axis: edge.axis, before: edge.before)
        finishMove(pane, in: dst)
    }

    func movePane(_ pane: PaneView, toWorkspace dst: Workspace) {
        guard let src = workspace(of: pane), src !== dst else { return }
        detach(pane, from: src)
        dst.zoomedPane = nil
        if let anchor = dst.focusedPane ?? dst.panes.last {
            dst.split(anchor, with: pane, axis: .horizontal)
        } else {
            dst.root = LayoutNode(pane: pane)
        }
        finishMove(pane, in: dst)
    }

    func movePaneToNewWorkspace(_ pane: PaneView) {
        guard let src = workspace(of: pane) else { return }
        if src.panes.count == 1 { return }  // it's already alone
        detach(pane, from: src)
        let n = workspaces.count + 1
        let ws = Workspace(name: pane.customName ?? "Workspace \(n)",
                           color: AppController.workspaceColors[(n - 1) % AppController.workspaceColors.count])
        ws.root = LayoutNode(pane: pane)
        workspaces.append(ws)
        finishMove(pane, in: ws)
    }

    /// Takes the pane out of its workspace; an emptied workspace is closed.
    private func detach(_ pane: PaneView, from ws: Workspace) {
        ws.remove(pane)
        pane.removeFromSuperview()
        if ws.root == nil { workspaces.removeAll { $0 === ws } }
        if ws.id == selectedId, ws.root != nil { workspaceView.show(ws) }
    }

    private func finishMove(_ pane: PaneView, in ws: Workspace) {
        ws.focusedPane = pane
        ws.touch()
        select(ws)
        scheduleSave()
    }

    /// Drop of the currently dragged terminal onto a workspace in the sidebar.
    func dropDraggedPane(on ws: Workspace?) -> Bool {
        guard let pane = PaneDrag.current else { return false }
        if let ws { movePane(pane, toWorkspace: ws) } else { movePaneToNewWorkspace(pane) }
        return true
    }

    func cyclePane(_ delta: Int) {
        guard let ws = current, !ws.panes.isEmpty else { return }
        let panes = ws.panes
        let i = panes.firstIndex { $0 === ws.focusedPane } ?? 0
        let p = panes[(i + delta + panes.count) % panes.count]
        if ws.zoomedPane != nil { ws.zoomedPane = p; workspaceView.show(ws) }
        focus(p)
    }

    // MARK: - Workspaces

    func newWorkspace(_ name: String?) {
        guard ensureProject() else { return }
        let n = workspaces.count + 1
        let color = AppController.workspaceColors[(n - 1) % AppController.workspaceColors.count]
        let ws = Workspace(name: name ?? "Workspace \(n)", color: color)
        let src = focusedPane
        let p = makePane(cwd: src?.cwd, themeId: src?.theme.id)
        ws.root = LayoutNode(pane: p)
        ws.focusedPane = p
        workspaces.append(ws)
        select(ws)
        scheduleSave()
    }

    func select(_ ws: Workspace) {
        selectedId = ws.id
        workspaceView.show(ws)
        window.title = ws.name
        if ws.focusedPane == nil { ws.focusedPane = ws.panes.first }
        refreshFocusVisuals()
        if let f = ws.focusedPane, !f.isHeld { f.focusTerminal() }
        scheduleSave()
    }

    func selectWorkspace(at index: Int) {
        guard workspaces.indices.contains(index) else { return }
        select(workspaces[index])
    }

    func cycleWorkspace(_ delta: Int) {
        guard let i = workspaces.firstIndex(where: { $0.id == selectedId }), !workspaces.isEmpty else { return }
        select(workspaces[(i + delta + workspaces.count) % workspaces.count])
    }

    func closeWorkspace(_ ws: Workspace, confirm: Bool = true) {
        if confirm {
            let n = ws.panes.count
            let msg = n == 1 ? "Its terminal will be closed." : "All \(n) terminals in it will be closed."
            Prompt.confirmSheet(on: window, "Close workspace “\(ws.name)”?", message: msg, ok: "Close Workspace") { ok in
                if ok { self.closeWorkspace(ws, confirm: false) } else { ws.focusedPane?.focusTerminal() }
            }
            return
        }
        ws.panes.forEach { $0.terminate(); $0.removeFromSuperview() }
        ws.root = nil
        removeWorkspace(ws)
    }

    /// Empty state: no workspace selected, placeholder with actions in the content area.
    private func showNothing() {
        selectedId = nil
        workspaceView.show(nil)
        window.title = "Termos"
        _ = window.makeFirstResponder(nil)
        emptyView?.isHidden = false
    }

    private func removeWorkspace(_ ws: Workspace) {
        guard let i = workspaces.firstIndex(where: { $0 === ws }) else { return }
        workspaces.remove(at: i)
        if workspaces.isEmpty {
            // A project always has at least one workspace.
            if sessionFileURL != nil { newWorkspace(nil) } else { showNothing() }
        } else if selectedId == ws.id {
            select(workspaces[max(0, i - 1)])
        }
        scheduleSave()
    }

    func rename(_ ws: Workspace) {
        if let n = Prompt.text(title: "Workspace Name", value: ws.name), !n.isEmpty {
            ws.name = n
            if ws.id == selectedId { window.title = n }
            scheduleSave()
        }
    }

    func setColor(_ color: NSColor, for ws: Workspace) {
        ws.color = color
        scheduleSave()
    }

    func move(_ ws: Workspace, by delta: Int) {
        guard let i = workspaces.firstIndex(where: { $0 === ws }) else { return }
        let j = i + delta
        guard workspaces.indices.contains(j) else { return }
        workspaces.swapAt(i, j)
        scheduleSave()
    }

    func moveWorkspace(from source: IndexSet, to destination: Int) {
        workspaces.move(fromOffsets: source, toOffset: destination)
        scheduleSave()
    }

    func toggleSidebar() {
        sidebarItem.animator().isCollapsed.toggle()
        scheduleSave()
    }

    // MARK: - PaneViewDelegate

    func paneWantsFocus(_ pane: PaneView) { focus(pane) }
    func pane(_ pane: PaneView, wantsSplit axis: SplitAxis) { split(axis, from: pane) }
    /// Closing by hand always asks first (a shell exiting on its own closes without asking).
    func paneWantsClose(_ pane: PaneView) {
        var message = "The shell in this terminal will be terminated."
        if pane.hasRunningProgram, let fg = pane.foregroundProcess {
            message = "“\(fg)” is still running and will be terminated."
        }
        Prompt.confirmSheet(on: window, "Close terminal “\(pane.displayTitle)”?", message: message, ok: "Close Terminal") { ok in
            if ok { self.close(pane) } else { pane.focusTerminal() }
        }
    }
    func paneProcessExited(_ pane: PaneView) { close(pane) }
    func paneWantsZoom(_ pane: PaneView) { toggleZoom(pane) }
    /// Freezing by hand always asks first: the shell (and anything running in it) is killed.
    func paneWantsFreeze(_ pane: PaneView) {
        var message = "The shell in this terminal will be stopped to free memory. Its name, startup command and place in the layout are kept; Restore starts it again."
        if pane.hasRunningProgram, let fg = pane.foregroundProcess {
            message = "“\(fg)” is running and will be stopped, along with the shell. The terminal keeps its name, startup command and place in the layout; Restore starts it again."
        }
        Prompt.confirmSheet(on: window, "Freeze terminal “\(pane.displayTitle)”?", message: message, ok: "Freeze") { ok in
            if ok { pane.freeze() } else { pane.focusTerminal() }
        }
    }
    func pane(_ pane: PaneView, droppedOn target: PaneView, edge: DropEdge) { movePane(pane, to: target, edge: edge) }

    func moveMenu(for pane: PaneView) -> NSMenu? {
        let m = NSMenu()
        let src = workspace(of: pane)
        for ws in workspaces where ws !== src {
            let i = ClosureMenuItem(title: ws.name) { [weak self, weak pane, weak ws] in
                if let self, let pane, let ws { self.movePane(pane, toWorkspace: ws) }
            }
            i.image = PaneView.swatch(ws.color, border: ws.color)
            m.addItem(i)
        }
        if !m.items.isEmpty { m.addItem(.separator()) }
        let n = ClosureMenuItem(title: "New Workspace") { [weak self, weak pane] in
            if let self, let pane { self.movePaneToNewWorkspace(pane) }
        }
        n.isEnabled = (src?.panes.count ?? 0) > 1
        m.addItem(n)
        m.autoenablesItems = false
        return m
    }
    func paneDidChange(_ pane: PaneView) {
        // Re-rendering sidebar rows dismisses an open context menu / submenu, and a running
        // program (spinner, clock) changes its title a few times per second. So: structural
        // changes (theme, label, freeze) refresh the sidebar at once, title-only churn is
        // debounced — applied after 2s of quiet.
        if pane.sidebarStructuralKey != pane.lastSidebarStructural {
            pane.lastSidebarStructural = pane.sidebarStructuralKey
            pane.sidebarTitleTimer?.invalidate()
            workspace(of: pane)?.touch()
        } else {
            pane.sidebarTitleTimer?.invalidate()
            pane.sidebarTitleTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self, weak pane] _ in
                guard let self, let pane else { return }
                self.workspace(of: pane)?.touch()
            }
        }
        scheduleSave()
    }

    // MARK: - Menu commands

    @objc func cmdNewWorkspace(_ sender: Any?) { newWorkspace(nil) }
    @objc func cmdNewProject(_ sender: Any?) {
        guard let url = newProjectPanel() else { return }
        startProject(at: url)
    }
    @objc func cmdOpenProject(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Persistence.contentType, .json]
        panel.allowsMultipleSelection = false
        panel.message = "Open a Termos project"
        panel.beginSheetModal(for: window) { resp in
            guard resp == .OK, let url = panel.url else { return }
            self.openProject(from: url)
        }
    }
    @objc func cmdSaveProject(_ sender: Any?) {
        // The project is saved continuously; this only flushes immediately if ⌘S is pressed.
        if ensureProject() { saveNow() }
    }

    /// File → New Window: a separate Termos process with its own workspaces, state and MCP socket.
    @objc func cmdNewWindow(_ sender: Any?) {
        // Prefer the installed app bundle; fall back to the binary this process runs from.
        let fm = FileManager.default
        let installed = URL(fileURLWithPath: "/Applications/Termos.app/Contents/MacOS/Termos")
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let thisBundle = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binary = fm.isExecutableFile(atPath: installed.path) && thisBundle.path != "/Applications/Termos.app"
            ? installed : exe

        var env = ProcessInfo.processInfo.environment
        if env["TERMOS_STATE_DIR"] == nil {
            // Own state dir, so this window's session doesn't collide with the main one.
            try? fm.createDirectory(at: Persistence.extraWindowsDir, withIntermediateDirectories: true)
            env["TERMOS_STATE_DIR"] = Persistence.extraWindowsDir
                .appendingPathComponent("w\(Date().timeIntervalSince1970)").path
        }
        let p = Process()
        p.executableURL = binary
        p.environment = env
        do {
            try p.run()
        } catch {
            NSAlert(error: error).runModal()
        }
    }
    @objc func cmdSplitRight(_ sender: Any?) { split(.horizontal) }
    @objc func cmdSplitDown(_ sender: Any?) { split(.vertical) }
    @objc func cmdClosePane(_ sender: Any?) { if let p = focusedPane { paneWantsClose(p) } }
    @objc func cmdCloseWorkspace(_ sender: Any?) { if let ws = current { closeWorkspace(ws) } }
    @objc func cmdRenameWorkspace(_ sender: Any?) { if let ws = current { rename(ws) } }
    @objc func cmdRenamePane(_ sender: Any?) { focusedPane?.menuRename() }
    @objc func cmdStartupCommand(_ sender: Any?) { focusedPane?.menuStartupCommand() }
    @objc func cmdImport(_ sender: Any?) { cmdOpenProject(sender) }
    @objc func cmdZoom(_ sender: Any?) { toggleZoom() }
    @objc func cmdFreezePane(_ sender: Any?) { if let p = focusedPane { menuFreezeHelper(p) } }
    private func menuFreezeHelper(_ pane: PaneView) {
        if pane.isHeld { pane.restore() } else { paneWantsFreeze(pane) }
    }
    @objc func cmdOpenSession(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Persistence.contentType, .json]
        panel.allowsMultipleSelection = false
        panel.message = "Open a session file: it replaces the current workspaces and is kept up to date"
        panel.beginSheetModal(for: window) { resp in
            guard resp == .OK, let url = panel.url else { return }
            self.openProject(from: url)
        }
    }
    @objc func cmdEqualize(_ sender: Any?) {
        guard let ws = current else { return }
        ws.equalize()
        workspaceView.show(ws)
        ws.focusedPane?.focusTerminal()
        scheduleSave()
    }
    @objc func cmdSwapLeft(_ sender: Any?) { swapFocused(.left) }
    @objc func cmdSwapRight(_ sender: Any?) { swapFocused(.right) }
    @objc func cmdSwapUp(_ sender: Any?) { swapFocused(.up) }
    @objc func cmdSwapDown(_ sender: Any?) { swapFocused(.down) }
    @objc func cmdFocusLeft(_ sender: Any?) { moveFocus(.left) }
    @objc func cmdFocusRight(_ sender: Any?) { moveFocus(.right) }
    @objc func cmdFocusUp(_ sender: Any?) { moveFocus(.up) }
    @objc func cmdFocusDown(_ sender: Any?) { moveFocus(.down) }
    @objc func cmdNextPane(_ sender: Any?) { cyclePane(1) }
    @objc func cmdPrevPane(_ sender: Any?) { cyclePane(-1) }
    @objc func cmdNextWorkspace(_ sender: Any?) { cycleWorkspace(1) }
    @objc func cmdPrevWorkspace(_ sender: Any?) { cycleWorkspace(-1) }
    @objc func cmdSelectWorkspace(_ sender: NSMenuItem) { selectWorkspace(at: sender.tag) }
    @objc func cmdToggleSidebar(_ sender: Any?) { toggleSidebar() }
    @objc func cmdToggleDim(_ sender: Any?) { dimInactive.toggle() }
    @objc func cmdFontBigger(_ sender: Any?) { if let p = focusedPane { p.fontSize = min(36, p.fontSize + 1) } }
    @objc func cmdFontSmaller(_ sender: Any?) { if let p = focusedPane { p.fontSize = max(8, p.fontSize - 1) } }
    @objc func cmdFontReset(_ sender: Any?) { focusedPane?.fontSize = 13 }
    @objc func cmdTheme(_ sender: NSMenuItem) { focusedPane?.menuTheme(sender) }
    @objc func cmdThemeAll(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        current?.panes.forEach { $0.setTheme(TerminalTheme.byId(id)) }
    }
    @objc func cmdLabel(_ sender: NSMenuItem) { focusedPane?.menuLabel(sender) }
    @objc func cmdCustomBackground(_ sender: Any?) { focusedPane?.menuCustomBackground() }

    // MARK: - NSWindowDelegate

    /// The red close button quits the app (after the same check as ⌘Q).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        Log.write("windowShouldClose")
        // Quit from the next run loop turn, outside the button's mouse tracking.
        DispatchQueue.main.async { NSApp.terminate(nil) }
        return false  // the window goes away when the app quits (or stays if quitting is cancelled)
    }

    /// Asked before every quit (red close button or ⌘Q). Calls back with the answer.
    func confirmQuit(_ completion: @escaping (Bool) -> Void) {
        let panes = workspaces.flatMap(\.panes)
        if panes.isEmpty { completion(true); return }  // nothing to lose
        let busy = panes.filter(\.hasRunningProgram)
        var message = "\(workspaces.count) workspace(s) with \(panes.count) terminal(s) will be closed."
        if !busy.isEmpty {
            let names = busy.compactMap(\.foregroundProcess).prefix(5).joined(separator: ", ")
            message += " Still running: \(names)."
        }
        message += " You can bring the layout back with Restore Previous Session."
        Prompt.confirmSheet(on: window, "Quit Termos?", message: message, ok: "Quit", completion: completion)
    }
}

/// Window that tells the controller which terminal got focus.
final class TermosWindow: NSWindow {
    weak var controller: AppController?

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let ok = super.makeFirstResponder(responder)
        if ok, let tv = responder as? TermView, let pane = tv.superview as? PaneView {
            controller?.terminalBecameFirstResponder(pane)
        }
        return ok
    }
}

/// Right side of the window: background and padding around the layout.
final class ContentViewController: NSViewController {
    let workspaceView: WorkspaceView
    var emptyView: NSView?
    weak var sidebarItem: NSSplitViewItem?

    init(workspaceView: WorkspaceView) {
        self.workspaceView = workspaceView
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(hex: "121316")!.cgColor
        workspaceView.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(workspaceView)
        if let empty = emptyView {
            empty.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(empty)
            NSLayoutConstraint.activate([
                empty.topAnchor.constraint(equalTo: v.topAnchor),
                empty.bottomAnchor.constraint(equalTo: v.bottomAnchor),
                empty.leadingAnchor.constraint(equalTo: v.leadingAnchor),
                empty.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            workspaceView.topAnchor.constraint(equalTo: v.topAnchor, constant: 8),
            workspaceView.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
            workspaceView.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -8),
            workspaceView.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -8),
        ])
        view = v
    }
}
