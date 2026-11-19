import AppKit
import SwiftTerm

protocol PaneViewDelegate: AnyObject {
    func paneWantsFocus(_ pane: PaneView)
    func pane(_ pane: PaneView, wantsSplit axis: SplitAxis)
    func paneWantsClose(_ pane: PaneView)
    func paneProcessExited(_ pane: PaneView)
    func paneDidChange(_ pane: PaneView)
    func paneWantsZoom(_ pane: PaneView)
    func paneWantsFreeze(_ pane: PaneView)
    func pane(_ pane: PaneView, droppedOn target: PaneView, edge: DropEdge)
    func moveMenu(for pane: PaneView) -> NSMenu?
}

/// Where a dragged terminal lands relative to the pane under the cursor.
enum DropEdge {
    case center, left, right, top, bottom

    var axis: SplitAxis { self == .top || self == .bottom ? .vertical : .horizontal }
    var before: Bool { self == .left || self == .top }

    /// Middle area swaps, the rest inserts next to the nearest edge. `p` is in non-flipped coordinates.
    static func zone(for p: NSPoint, in b: NSRect) -> DropEdge {
        let nx = (p.x - b.minX) / max(1, b.width), ny = (p.y - b.minY) / max(1, b.height)
        if (0.28...0.72).contains(nx) && (0.28...0.72).contains(ny) { return .center }
        let d: [(DropEdge, CGFloat)] = [(.left, nx), (.right, 1 - nx), (.bottom, ny), (.top, 1 - ny)]
        return d.min { $0.1 < $1.1 }!.0
    }

    func highlightRect(in b: NSRect) -> NSRect {
        switch self {
        case .center: return b
        case .left: return NSRect(x: b.minX, y: b.minY, width: b.width / 2, height: b.height)
        case .right: return NSRect(x: b.midX, y: b.minY, width: b.width / 2, height: b.height)
        case .bottom: return NSRect(x: b.minX, y: b.minY, width: b.width, height: b.height / 2)
        case .top: return NSRect(x: b.minX, y: b.midY, width: b.width, height: b.height / 2)
        }
    }
}

/// The terminal currently being dragged (drags never leave the app).
enum PaneDrag {
    static let type = NSPasteboard.PasteboardType("local.termos.pane")
    static weak var current: PaneView?

    static func isPaneDrag(_ info: NSDraggingInfo) -> Bool {
        current != nil && info.draggingPasteboard.types?.contains(type) == true
    }
}

/// Terminal view that routes ⌘ shortcuts to the app menu instead of the shell.
final class TermView: LocalProcessTerminalView {
    /// Called when a drag enters/leaves so the pane can highlight itself.
    var onDropHighlight: ((Bool) -> Void)?

    /// Runs once when the shell's startup output goes quiet, i.e. the first prompt is shown.
    var onShellReady: (() -> Void)? {
        didSet {
            // Fallback in case the shell prints nothing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.fireShellReady() }
        }
    }
    private var readyWork: DispatchWorkItem?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        guard onShellReady != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.readyWork?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.fireShellReady() }
            self.readyWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
        }
    }

    private func fireShellReady() {
        guard let f = onShellReady else { return }
        onShellReady = nil
        readyWork?.cancel()
        f()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes(DropPayload.acceptedTypes + [PaneDrag.type])
        // Thin vertical caret instead of the wide block (programs can still override via DECSCUSR).
        getTerminal().setCursorStyle(.steadyBar)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), let menu = NSApp.mainMenu, menu.performKeyEquivalent(with: event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: - Drag & drop: files are inserted as shell-escaped paths, like Terminal.app

    private var pane: PaneView? { superview as? PaneView }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if PaneDrag.isPaneDrag(sender) { return pane?.draggingEntered(sender) ?? [] }
        guard DropPayload.canRead(sender.draggingPasteboard) else { return [] }
        onDropHighlight?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if PaneDrag.isPaneDrag(sender) { return pane?.draggingUpdated(sender) ?? [] }
        return DropPayload.canRead(sender.draggingPasteboard) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        pane?.draggingExited(sender)
        onDropHighlight?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) { onDropHighlight?(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if PaneDrag.isPaneDrag(sender) { return pane?.performDragOperation(sender) ?? false }
        onDropHighlight?(false)
        guard let text = DropPayload.text(from: sender.draggingPasteboard), !text.isEmpty else { return false }
        window?.makeFirstResponder(self)
        NSApp.activate(ignoringOtherApps: true)
        pasteText(text)
        return true
    }

    /// Sends text as a paste (bracketed when the app asked for it), so shells and TUIs
    /// such as Claude Code treat it as pasted input rather than typed keys.
    func pasteText(_ text: String) {
        let bracketed = getTerminal().bracketedPasteMode
        if bracketed { send(EscapeSequences.bracketedPasteStart) }
        send(txt: text)
        if bracketed { send(EscapeSequences.bracketedPasteEnd) }
    }
}

/// Terminal card: rounded corners, header, highlightable border.
final class PaneView: NSView, LocalProcessTerminalViewDelegate, NSMenuDelegate {
    static let headerHeight: CGFloat = 26
    static let cornerRadius: CGFloat = 10

    override var mouseDownCanMoveWindow: Bool { false }

    let id: UUID
    weak var delegate: PaneViewDelegate?

    /// Replaced with a fresh view on freeze, so the old one (with its scrollback) is freed.
    private(set) var terminal: TermView
    /// Frozen state: the process is killed and a placeholder is shown until Restore.
    private(set) var isHeld = false
    private var heldView: HeldPlaceholderView?
    private let header = PaneHeaderView()
    private let dimOverlay = PassthroughView()
    private let dropOverlay = PassthroughView()

    /// User-defined name (otherwise the terminal title / current directory).
    var customName: String? { didSet { refreshTitle(); notify() } }
    private(set) var terminalTitle: String = ""
    private(set) var cwd: String
    /// Program currently in the foreground (nil means just the shell).
    private(set) var foregroundProcess: String?
    private(set) var theme: TerminalTheme = .graphite
    private(set) var customBackground: NSColor?
    var borderLabel: BorderLabel = .none { didSet { updateBorder(); notify() } }
    var fontSize: CGFloat = 13 { didSet { applyFont(); notify() } }
    /// Command typed into the shell right after it starts (e.g. `npm run dev`).
    var startupCommand: String? { didSet { notify() } }

    var isFocused = false { didSet { updateBorder() } }
    var isZoomed = false { didSet { header.isZoomed = isZoomed } }
    private var paneDropEdge: DropEdge?
    private var exited = false
    private var cwdTimer: Timer?
    /// Sidebar refresh bookkeeping: title churn (spinner updates from running programs)
    /// must not re-render the sidebar constantly — it dismisses open context menus.
    var lastSidebarStructural: String?
    var sidebarTitleTimer: Timer?

    /// Sidebar-visible state that should refresh immediately when changed.
    var sidebarStructuralKey: String {
        "\(borderLabel.rawValue)|\(isHeld)|\(theme.id)|\(customBackground?.hexString ?? "-")"
    }

    var effectiveTheme: TerminalTheme {
        if let bg = customBackground { return theme.withBackground(bg) }
        return theme
    }

    var displayTitle: String {
        if let n = customName, !n.isEmpty { return n }
        if let fg = foregroundProcess {
            // A running program may set a meaningful title (e.g. Claude Code); shell titles are just paths.
            let t = terminalTitle.trimmingCharacters(in: .whitespaces)
            return t.isEmpty || PaneView.looksLikePath(t) ? fg : t
        }
        return PaneView.folderName(cwd)
    }

    /// Just the folder name, "~" for home.
    static func folderName(_ path: String) -> String {
        if path == NSHomeDirectory() { return "~" }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    static func looksLikePath(_ s: String) -> Bool {
        s.hasPrefix("~") || s.hasPrefix("/") || s.contains(":~") || s.contains(": ~") || s.contains(":/")
    }

    static func prettyPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    init(id: UUID = UUID(), cwd: String?, themeId: String?, customBackground: NSColor? = nil,
         borderLabel: BorderLabel = .none, customName: String? = nil, fontSize: CGFloat = 13) {
        self.id = id
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if let cwd, fm.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue {
            self.cwd = cwd
        } else {
            self.cwd = NSHomeDirectory()
        }
        self.terminal = TermView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        self.customName = customName
        self.borderLabel = borderLabel
        self.fontSize = fontSize
        self.customBackground = customBackground
        self.theme = TerminalTheme.byId(themeId)
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 300))

        wantsLayer = true
        layer?.cornerRadius = PaneView.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        terminal.processDelegate = self
        terminal.optionAsMetaKey = true
        let menu = NSMenu()
        menu.delegate = self  // rebuilt on every open, so it is always up to date
        terminal.menu = menu
        registerForDraggedTypes([PaneDrag.type])
        addSubview(terminal)

        header.pane = self
        header.menuProvider = { [weak self] in self?.makeContextMenu() }
        addSubview(header)

        dimOverlay.wantsLayer = true
        dimOverlay.isHidden = true
        addSubview(dimOverlay)

        dropOverlay.wantsLayer = true
        dropOverlay.isHidden = true
        dropOverlay.layer?.cornerRadius = PaneView.cornerRadius
        dropOverlay.layer?.cornerCurve = .continuous
        dropOverlay.layer?.borderWidth = 3
        addSubview(dropOverlay)
        terminal.onDropHighlight = { [weak self] on in self?.setDropHighlight(on) }

        applyFont()
        applyTheme()
        refreshTitle()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { cwdTimer?.invalidate() }

    // MARK: - Process

    /// Starts the shell only if it isn't running yet (restoring a held pane).
    @discardableResult
    func startShellIfNeeded() -> Bool {
        guard terminal.process?.shellPid != 0 else { startShell(); return true }
        return false
    }

    func startShell() {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        env.removeAll { $0.hasPrefix("TERM_PROGRAM=") || $0.hasPrefix("COLORTERM=") }
        env.append("TERM_PROGRAM=Termos")
        env.append("COLORTERM=truecolor")
        if !env.contains(where: { $0.hasPrefix("LANG=") }) { env.append("LANG=en_US.UTF-8") }
        // Pass through environment that matters for development.
        for key in ["PATH", "SSH_AUTH_SOCK", "TMPDIR", "XPC_FLAGS", "__CF_USER_TEXT_ENCODING"] {
            if let v = ProcessInfo.processInfo.environment[key], !env.contains(where: { $0.hasPrefix(key + "=") }) {
                env.append("\(key)=\(v)")
            }
        }
        let execName = "-" + (shell as NSString).lastPathComponent  // login shell, like Terminal.app
        // Tells programs started in this terminal which Termos instance to control via MCP
        // (so Claude Code in a pane talks to the Termos window that pane lives in).
        if let id = ControlServer.currentInstanceId {
            env.append("TERMOS_INSTANCE=\(id)")
        }
        terminal.startProcess(executable: shell, args: [], environment: env, execName: execName, currentDirectory: cwd)
        if let cmd = startupCommand?.trimmingCharacters(in: .whitespacesAndNewlines), !cmd.isEmpty {
            // Wait for the first prompt, so the command isn't echoed twice by the shell's line editor.
            terminal.onShellReady = { [weak self] in self?.terminal.send(txt: cmd + "\r") }
        }

        cwdTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollCwd()
        }
    }

    func terminate() {
        cwdTimer?.invalidate()
        exited = true
        terminal.terminate()
    }

    // MARK: - Freeze / Restore

    /// Kills the shell and shows a plain placeholder instead of the terminal.
    /// The pane keeps its name, startup command and place in the layout.
    func freeze() {
        guard !isHeld else { return }
        isHeld = true
        cwdTimer?.invalidate()
        foregroundProcess = nil
        terminalTitle = ""

        // Kill the whole process group: the shell and any program running in it (claude, npm…).
        // The shell leads its own session (forkpty), so its pgid == its pid.
        if let pid = terminal.process?.shellPid, pid > 0 {
            kill(-pid, SIGHUP)
            kill(-pid, SIGTERM)
        }
        exited = true  // the terminate() callback must not report this as a pane-closing exit
        terminal.terminate()

        let held = HeldPlaceholderView()
        held.title = displayTitle
        held.onRestore = { [weak self] in self?.restore() }
        addSubview(held)
        heldView = held

        // Swap in a brand-new terminal view so the old one (and its scrollback buffer) is released.
        let fresh = TermView(frame: terminal.frame)
        fresh.processDelegate = self
        fresh.optionAsMetaKey = true
        let menu = NSMenu()
        menu.delegate = self
        fresh.menu = menu
        fresh.onDropHighlight = { [weak self] on in self?.setDropHighlight(on) }
        fresh.isHidden = true
        addSubview(fresh)
        terminal.removeFromSuperview()
        terminal = fresh
        applyFont()
        applyTheme()

        needsLayout = true
        refreshTitle()
        notify()
    }

    /// Starts the shell again. If a startup command is set, it runs right after the prompt.
    func restore() {
        guard isHeld else { return }
        isHeld = false
        exited = false
        heldView?.removeFromSuperview()
        heldView = nil
        terminal.isHidden = false
        startShell()
        needsLayout = true
        refreshTitle()
        notify()
        focusTerminal()
    }

    private func pollCwd() {
        guard let proc = terminal.process, proc.shellPid > 0 else { return }
        var changed = false
        if let dir = ProcessInspector.cwd(of: proc.shellPid), dir != cwd {
            cwd = dir
            changed = true
        }
        var fg: String?
        if let pg = ProcessInspector.foregroundGroup(of: proc.shellPid), pg != proc.shellPid {
            fg = ProcessInspector.name(of: pg)
        }
        if fg != foregroundProcess {
            foregroundProcess = fg
            changed = true
        }
        if changed {
            refreshTitle()
            notify()
        }
    }

    /// Whether a program other than the shell is running.
    var hasRunningProgram: Bool {
        guard let proc = terminal.process, proc.shellPid > 0,
              let pg = ProcessInspector.foregroundGroup(of: proc.shellPid) else { return false }
        return pg != proc.shellPid
    }

    // MARK: - Appearance

    func setTheme(_ t: TerminalTheme) {
        theme = t
        customBackground = nil
        applyTheme()
        notify()
    }

    func setCustomBackground(_ color: NSColor?) {
        customBackground = color
        applyTheme()
        notify()
    }

    private func applyTheme() {
        let t = effectiveTheme
        terminal.installColors(t.swiftTermPalette)
        terminal.nativeBackgroundColor = t.background
        terminal.nativeForegroundColor = t.foreground
        terminal.caretColor = t.cursor
        terminal.selectedTextBackgroundColor = t.selection
        layer?.backgroundColor = t.background.cgColor
        header.apply(theme: t)
        dimOverlay.layer?.backgroundColor = (t.isLight ? NSColor.white : NSColor.black).withAlphaComponent(0.18).cgColor
        terminal.needsDisplay = true
        updateBorder()
    }

    private func applyFont() {
        terminal.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    func setDimmed(_ dim: Bool) { dimOverlay.isHidden = !dim }

    // MARK: - Dropping another terminal onto this one

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { updatePaneDrop(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { updatePaneDrop(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { clearPaneDrop() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { clearPaneDrop() }
        guard let edge = paneDropEdge, let src = PaneDrag.current, src !== self else { return false }
        delegate?.pane(src, droppedOn: self, edge: edge)
        return true
    }

    private func updatePaneDrop(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard PaneDrag.isPaneDrag(sender), let src = PaneDrag.current, src !== self else {
            clearPaneDrop()
            return []
        }
        let edge = DropEdge.zone(for: convert(sender.draggingLocation, from: nil), in: bounds)
        if edge != paneDropEdge {
            paneDropEdge = edge
            setDropHighlight(true, rect: edge.highlightRect(in: bounds))
        }
        return .move
    }

    private func clearPaneDrop() {
        paneDropEdge = nil
        setDropHighlight(false)
    }

    /// Small picture of the pane used as the drag image.
    func snapshotImage(maxWidth: CGFloat) -> NSImage {
        let scale = min(1, maxWidth / max(1, bounds.width))
        let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return NSImage(size: size) }
        cacheDisplay(in: bounds, to: rep)
        let img = NSImage(size: size)
        img.lockFocus()
        rep.draw(in: NSRect(origin: .zero, size: size))
        img.unlockFocus()
        return img
    }

    private func setDropHighlight(_ on: Bool, rect: NSRect? = nil) {
        dropOverlay.frame = rect ?? bounds
        let c = borderLabel.color ?? effectiveTheme.accent
        dropOverlay.layer?.borderColor = c.cgColor
        dropOverlay.layer?.backgroundColor = c.withAlphaComponent(0.12).cgColor
        dropOverlay.isHidden = !on
    }

    private func updateBorder() {
        let t = effectiveTheme
        if isFocused {
            let c = borderLabel.color ?? t.accent
            layer?.borderColor = c.cgColor
            layer?.borderWidth = 2
        } else if let c = borderLabel.color {
            layer?.borderColor = c.withAlphaComponent(0.75).cgColor
            layer?.borderWidth = 1.5
        } else {
            layer?.borderColor = (t.isLight ? NSColor.black : NSColor.white).withAlphaComponent(0.10).cgColor
            layer?.borderWidth = 1
        }
        header.setFocused(isFocused, label: borderLabel)
    }

    private func refreshTitle() {
        header.title = displayTitle
        header.toolTip = PaneView.prettyPath(cwd)
    }

    private func notify() { delegate?.paneDidChange(self) }

    override func layout() {
        super.layout()
        let h = PaneView.headerHeight
        header.frame = NSRect(x: 0, y: bounds.height - h, width: bounds.width, height: h)
        // Insets so text doesn't touch the rounded corners.
        terminal.frame = NSRect(x: 8, y: 6, width: max(10, bounds.width - 14), height: max(10, bounds.height - h - 6))
        dimOverlay.frame = bounds
        dropOverlay.frame = bounds
        heldView?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(10, bounds.height - h))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override var isFlipped: Bool { false }

    func focusTerminal() {
        guard !isHeld else { return }
        window?.makeFirstResponder(terminal)
    }

    // MARK: - Menu

    func makeContextMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        m.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(item("Split Right", #selector(menuSplitRight)))
        m.addItem(item("Split Down", #selector(menuSplitDown)))
        m.addItem(item(isZoomed ? "Unzoom" : "Zoom to Workspace", #selector(menuZoom)))
        m.addItem(item(isHeld ? "Restore Terminal" : "Freeze Terminal", #selector(menuFreeze)))
        if let move = delegate?.moveMenu(for: self) {
            let i = NSMenuItem(title: "Move to Workspace", action: nil, keyEquivalent: "")
            i.submenu = move
            m.addItem(i)
        }
        m.addItem(.separator())

        let colors = NSMenuItem(title: "Color Scheme", action: nil, keyEquivalent: "")
        colors.submenu = PaneView.themeMenu(target: self, action: #selector(menuTheme(_:)), current: customBackground == nil ? theme.id : nil)
        m.addItem(colors)
        m.addItem(item("Custom Background…", #selector(menuCustomBackground)))

        let labels = NSMenuItem(title: "Border Label", action: nil, keyEquivalent: "")
        labels.submenu = PaneView.labelMenu(target: self, action: #selector(menuLabel(_:)), current: borderLabel)
        m.addItem(labels)

        m.addItem(item("Rename…", #selector(menuRename)))
        m.addItem(item(startupCommand == nil ? "Startup Command…" : "Startup Command… ✓", #selector(menuStartupCommand)))
        m.addItem(.separator())
        m.addItem(item("Close Terminal", #selector(menuClose)))
        return m
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let fresh = makeContextMenu()
        for i in fresh.items {
            fresh.removeItem(i)
            menu.addItem(i)
        }
    }

    private func item(_ title: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        return i
    }

    static func swatch(_ color: NSColor, border: NSColor? = nil, size: CGFloat = 12) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            color.setFill(); path.fill()
            (border ?? NSColor.gray.withAlphaComponent(0.6)).setStroke(); path.lineWidth = 1; path.stroke()
            return true
        }
    }

    static func themeMenu(target: AnyObject, action: Selector, current: String?) -> NSMenu {
        let m = NSMenu()
        for t in TerminalTheme.all {
            let i = NSMenuItem(title: t.name, action: action, keyEquivalent: "")
            i.target = target
            i.representedObject = t.id
            i.image = swatch(t.background, border: t.foreground)
            i.state = t.id == current ? .on : .off
            m.addItem(i)
        }
        return m
    }

    static func labelMenu(target: AnyObject, action: Selector, current: BorderLabel) -> NSMenu {
        let m = NSMenu()
        for l in BorderLabel.allCases {
            let i = NSMenuItem(title: l.title, action: action, keyEquivalent: "")
            i.target = target
            i.representedObject = l.rawValue
            if let c = l.color { i.image = swatch(c, border: c) }
            i.state = l == current ? .on : .off
            m.addItem(i)
        }
        return m
    }

    @objc private func menuSplitRight() { delegate?.pane(self, wantsSplit: .horizontal) }
    @objc private func menuSplitDown() { delegate?.pane(self, wantsSplit: .vertical) }
    @objc private func menuZoom() { delegate?.paneWantsZoom(self) }
    @objc private func menuFreeze() {
        if isHeld { restore() } else { delegate?.paneWantsFreeze(self) }
    }
    @objc private func menuClose() { delegate?.paneWantsClose(self) }
    @objc func menuTheme(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { setTheme(TerminalTheme.byId(id)) }
    }
    @objc func menuLabel(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let l = BorderLabel(rawValue: raw) { borderLabel = l }
    }
    @objc func menuCustomBackground() {
        ColorPickerBridge.shared.pick(initial: effectiveTheme.background) { [weak self] c in
            self?.setCustomBackground(c)
        }
    }
    @objc func menuStartupCommand() {
        if let cmd = Prompt.multiline(title: "Startup Command",
                                      message: "Runs in this terminal when it starts, is restored or unfrozen (e.g. npm run dev, claude --resume <uuid>). Leave empty for none.",
                                      value: startupCommand ?? "") {
            startupCommand = cmd.isEmpty ? nil : cmd
        }
    }

    @objc func menuRename() {
        if let name = Prompt.text(title: "Terminal Name", message: "Leave empty to show the process title.",
                                  value: customName ?? "") {
            customName = name.isEmpty ? nil : name
        }
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        terminalTitle = title
        refreshTitle()
        notify()
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory, let url = URL(string: directory), url.isFileURL else { return }
        cwd = url.path
        refreshTitle()
        notify()
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard !exited else { return }
        exited = true
        cwdTimer?.invalidate()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.paneProcessExited(self)
        }
    }
}

// MARK: - Pane header

final class PaneHeaderView: NSView, NSDraggingSource {
    /// The header sits under the transparent title bar. AppKit moves the window when the clicked view
    /// (e.g. the title label or the dot) says it can, so everything except the buttons is routed to
    /// the header itself, and the header refuses to move the window.
    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit is NSButton || hit.superview is NSButton { return hit }
        return self
    }

    weak var pane: PaneView?
    var menuProvider: (() -> NSMenu?)?

    private let dot = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let buttons = NSStackView()
    private var tracking: NSTrackingArea?
    private var hovering = false { didSet { updateButtonsVisibility() } }
    private var mouseDownPoint: NSPoint?
    private var zoomButton: NSButton!

    var isZoomed = false {
        didSet {
            let symbol = isZoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
            zoomButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Zoom")
            zoomButton.toolTip = isZoomed ? "Unzoom (⇧⌘↩)" : "Zoom to workspace (⇧⌘↩)"
            updateButtonsVisibility()
        }
    }

    private func updateButtonsVisibility() {
        // While zoomed, keep the buttons visible so it's obvious how to get back.
        buttons.animator().alphaValue = hovering || isZoomed ? 1 : 0
    }
    private var textColor = NSColor.white

    var title: String = "" { didSet { titleLabel.stringValue = title; needsLayout = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        addSubview(dot)

        titleLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.truncatesLastVisibleLine = true
        addSubview(titleLabel)


        for (symbol, tip, sel) in [("arrow.up.left.and.arrow.down.right", "Zoom to workspace (⇧⌘↩)", #selector(zoom)),
                                   ("rectangle.split.2x1", "Split Right (⌘D)", #selector(splitRight)),
                                   ("rectangle.split.1x2", "Split Down (⇧⌘D)", #selector(splitDown)),
                                   ("ellipsis.circle", "Menu", #selector(showMenu(_:))),
                                   ("xmark", "Close (⌘W)", #selector(close))] {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: sel)
            b.isBordered = false
            b.toolTip = tip
            b.imageScaling = .scaleProportionallyDown
            b.symbolConfiguration = .init(pointSize: 11, weight: .medium)
            b.setFrameSize(NSSize(width: 20, height: 18))
            buttons.addArrangedSubview(b)
            if sel == #selector(zoom) { zoomButton = b }
        }
        buttons.spacing = 2
        buttons.alphaValue = 0
        addSubview(buttons)
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(theme t: TerminalTheme) {
        // Header is slightly darker/lighter than the terminal background.
        let shade = t.isLight ? NSColor.black : NSColor.white
        let bg = t.background.blended(withFraction: 0.06, of: shade) ?? t.background
        layer?.backgroundColor = bg.cgColor
        textColor = t.foreground
        titleLabel.textColor = t.foreground.withAlphaComponent(0.9)
        for case let b as NSButton in buttons.arrangedSubviews { b.contentTintColor = t.foreground.withAlphaComponent(0.7) }
        dot.layer?.backgroundColor = t.accent.cgColor
    }

    func setFocused(_ focused: Bool, label: BorderLabel) {
        titleLabel.alphaValue = focused ? 1 : 0.7
        if let c = label.color {
            dot.layer?.backgroundColor = c.cgColor
            dot.isHidden = false
        } else {
            dot.isHidden = !focused
            if let p = pane { dot.layer?.backgroundColor = p.effectiveTheme.accent.cgColor }
        }
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        dot.frame = NSRect(x: 10, y: (h - 7) / 2, width: 7, height: 7)
        let bw = buttons.fittingSize.width
        buttons.frame = NSRect(x: bounds.width - bw - 8, y: (h - 18) / 2, width: bw, height: 18)
        let x: CGFloat = 23
        let avail = bounds.width - x - bw - 16
        // The label gets all the free width, so it truncates only when the text really doesn't fit.
        titleLabel.frame = NSRect(x: x, y: (h - 16) / 2, width: max(0, avail), height: 16)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        guard let pane else { return }
        if event.clickCount == 2 {
            mouseDownPoint = nil
            pane.delegate?.paneWantsZoom(pane)
        } else {
            mouseDownPoint = event.locationInWindow
            pane.delegate?.paneWantsFocus(pane)
        }
    }

    // MARK: - Dragging the terminal by its header

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, let pane else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 5 else { return }
        mouseDownPoint = nil

        let item = NSPasteboardItem()
        item.setString(pane.id.uuidString, forType: PaneDrag.type)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        let img = pane.snapshotImage(maxWidth: 360)
        let loc = convert(event.locationInWindow, from: nil)
        dragItem.setDraggingFrame(NSRect(x: loc.x - img.size.width / 2, y: loc.y - img.size.height + 12,
                                         width: img.size.width, height: img.size.height), contents: img)
        PaneDrag.current = pane
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) { mouseDownPoint = nil }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        DispatchQueue.main.async { PaneDrag.current = nil }
    }

    override func rightMouseDown(with event: NSEvent) {
        if let m = menuProvider?() { NSMenu.popUpContextMenu(m, with: event, for: self) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    @objc private func zoom() { if let p = pane { p.delegate?.paneWantsZoom(p) } }
    @objc private func splitRight() { if let p = pane { p.delegate?.pane(p, wantsSplit: .horizontal) } }
    @objc private func splitDown() { if let p = pane { p.delegate?.pane(p, wantsSplit: .vertical) } }
    @objc private func close() { if let p = pane { p.delegate?.paneWantsClose(p) } }
    @objc private func showMenu(_ sender: NSButton) {
        guard let m = menuProvider?() else { return }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }
}

/// View that ignores clicks.
final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Shown instead of the terminal while the pane is frozen: plain dark-gray block with the
/// terminal name at the top (large), a "frozen" note below it, and a Restore button.
final class HeldPlaceholderView: NSView {
    var onRestore: (() -> Void)?

    var title: String = "" { didSet { titleLabel.stringValue = title } }

    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "Terminal frozen")
    private var restoreButton: NSButton!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 1).cgColor

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.85)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(titleLabel)

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = NSColor.white.withAlphaComponent(0.35)
        detailLabel.alignment = .center
        addSubview(detailLabel)

        restoreButton = NSButton(title: "Restore", target: self, action: #selector(restore))
        restoreButton.bezelStyle = .rounded
        addSubview(restoreButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    @objc private func restore() {
        NSApp.activate(ignoringOtherApps: true)
        onRestore?()
    }

    /// Double-click anywhere on the block also restores.
    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 { restore() }
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        // Clean vertical stack from the top: name (large), note (small), Restore button.
        titleLabel.frame = NSRect(x: 12, y: 48, width: w - 24, height: 20)
        detailLabel.frame = NSRect(x: 12, y: 72, width: w - 24, height: 14)
        restoreButton.sizeToFit()
        let bw = max(restoreButton.fittingSize.width + 28, 104)
        restoreButton.frame = NSRect(x: (w - bw) / 2, y: 98, width: bw, height: 28)
    }
}
