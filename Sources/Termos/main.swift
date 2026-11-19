import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AppController()

    private var started = false
    private var pendingURLs: [URL] = []
    /// Keeps the Workspaces menu in sync with the real workspace names (rebuilt on every open).
    private var workspacesFiller: WorkspacesMenuFiller?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()
        controller.start()
        started = true
        pendingURLs.forEach(controller.openProject(from:))
        pendingURLs = []
        // TERMOS_BACKGROUND: test instances open behind other windows and don't take focus.
        if ProcessInfo.processInfo.environment["TERMOS_BACKGROUND"] == nil { NSApp.activate(ignoringOtherApps: true) }
    }

    /// Double-clicking a .termos file in Finder opens it as the project.
    func application(_ application: NSApplication, open urls: [URL]) {
        if started { urls.forEach(controller.openProject(from:)) } else { pendingURLs += urls }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Log.write("applicationShouldTerminate")
        controller.confirmQuit { ok in NSApp.reply(toApplicationShouldTerminate: ok) }
        return .terminateLater
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let c = controller
        let main = NSMenu()
        _ = workspacesFiller  // built in the Workspaces submenu below; kept alive here

        func sub(_ title: String, _ build: (NSMenu) -> Void) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title)
            build(m)
            item.submenu = m
            main.addItem(item)
        }
        func add(_ m: NSMenu, _ title: String, _ sel: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target ?? c
            m.addItem(i)
        }
        let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        let right = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        let up = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        let down = String(UnicodeScalar(NSDownArrowFunctionKey)!)

        sub("Termos") { m in
            m.addItem(withTitle: "About Termos", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
            m.addItem(.separator())
            m.addItem(withTitle: "Hide Termos", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
            let others = m.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            others.keyEquivalentModifierMask = [.command, .option]
            m.addItem(.separator())
            m.addItem(withTitle: "Quit Termos", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        }

        sub("File") { m in
            add(m, "New Project…", #selector(AppController.cmdNewProject(_:)), "n", [.command, .shift])
            add(m, "Open Project…", #selector(AppController.cmdOpenProject(_:)), "o")
            m.addItem(.separator())
            add(m, "New Window", #selector(AppController.cmdNewWindow(_:)), "n")
            add(m, "New Workspace", #selector(AppController.cmdNewWorkspace(_:)), "t")
            add(m, "Rename Workspace…", #selector(AppController.cmdRenameWorkspace(_:)), "r", [.command, .shift])
        }

        sub("Edit") { m in
            m.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
            m.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
            m.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
            m.addItem(.separator())
            let find = m.addItem(withTitle: "Find…", action: #selector(NSResponder.performTextFinderAction(_:)), keyEquivalent: "f")
            find.tag = NSTextFinder.Action.showFindInterface.rawValue
        }

        sub("Terminal") { m in
            add(m, "Split Right", #selector(AppController.cmdSplitRight(_:)), "d")
            add(m, "Split Down", #selector(AppController.cmdSplitDown(_:)), "d", [.command, .shift])
            add(m, "Zoom Terminal to Workspace", #selector(AppController.cmdZoom(_:)), "\r", [.command, .shift])
            add(m, "Freeze Terminal", #selector(AppController.cmdFreezePane(_:)), "f", [.command, .shift])
            add(m, "Equalize Sizes", #selector(AppController.cmdEqualize(_:)), "=", [.command, .control])
            m.addItem(.separator())
            add(m, "Focus Left", #selector(AppController.cmdFocusLeft(_:)), left, [.command, .option])
            add(m, "Focus Right", #selector(AppController.cmdFocusRight(_:)), right, [.command, .option])
            add(m, "Focus Up", #selector(AppController.cmdFocusUp(_:)), up, [.command, .option])
            add(m, "Focus Down", #selector(AppController.cmdFocusDown(_:)), down, [.command, .option])
            add(m, "Swap Left", #selector(AppController.cmdSwapLeft(_:)), left, [.command, .control])
            add(m, "Swap Right", #selector(AppController.cmdSwapRight(_:)), right, [.command, .control])
            add(m, "Swap Up", #selector(AppController.cmdSwapUp(_:)), up, [.command, .control])
            add(m, "Swap Down", #selector(AppController.cmdSwapDown(_:)), down, [.command, .control])
            add(m, "Next Terminal", #selector(AppController.cmdNextPane(_:)), "]")
            add(m, "Previous Terminal", #selector(AppController.cmdPrevPane(_:)), "[")
            m.addItem(.separator())

            let themes = NSMenuItem(title: "Color Scheme", action: nil, keyEquivalent: "")
            themes.submenu = PaneView.themeMenu(target: c, action: #selector(AppController.cmdTheme(_:)), current: nil)
            m.addItem(themes)
            let themesAll = NSMenuItem(title: "Color Scheme for Workspace", action: nil, keyEquivalent: "")
            themesAll.submenu = PaneView.themeMenu(target: c, action: #selector(AppController.cmdThemeAll(_:)), current: nil)
            m.addItem(themesAll)
            add(m, "Custom Background…", #selector(AppController.cmdCustomBackground(_:)), "k", [.command, .shift])
            let labels = NSMenuItem(title: "Border Label", action: nil, keyEquivalent: "")
            labels.submenu = PaneView.labelMenu(target: c, action: #selector(AppController.cmdLabel(_:)), current: .none)
            m.addItem(labels)
            add(m, "Rename Terminal…", #selector(AppController.cmdRenamePane(_:)), "r", [.command, .option])
            add(m, "Startup Command…", #selector(AppController.cmdStartupCommand(_:)), "")
        }

        sub("View") { m in
            add(m, "Toggle Sidebar", #selector(AppController.cmdToggleSidebar(_:)), "s", [.command, .control])
            add(m, "Dim Inactive Terminals", #selector(AppController.cmdToggleDim(_:)), "")
            m.addItem(.separator())
            add(m, "Bigger", #selector(AppController.cmdFontBigger(_:)), "=")
            add(m, "Smaller", #selector(AppController.cmdFontSmaller(_:)), "-")
            add(m, "Actual Size", #selector(AppController.cmdFontReset(_:)), "0")
            m.addItem(.separator())
            let fs = m.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            fs.keyEquivalentModifierMask = [.command, .control]
        }

        sub("Workspaces") { m in
            add(m, "Next Workspace", #selector(AppController.cmdNextWorkspace(_:)), "]", [.command, .shift])
            add(m, "Previous Workspace", #selector(AppController.cmdPrevWorkspace(_:)), "[", [.command, .shift])
            m.addItem(.separator())
            // The real workspace list is filled in by WorkspacesMenuFiller on every open.
            let filler = WorkspacesMenuFiller(controller: c)
            workspacesFiller = filler
            m.delegate = filler
        }

        sub("Window") { m in
            m.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
            m.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
            NSApp.windowsMenu = m
        }
        return main
    }
}

if CommandLine.arguments.contains("--mcp") {
    MCPServer.run()  // stdio MCP server for Claude Code; never returns
}

/// Fills the Workspaces menu with the actual workspaces: their real names,
/// ⌘1…⌘9 shortcuts for the first nine, a checkmark on the selected one.
final class WorkspacesMenuFiller: NSObject, NSMenuDelegate {
    weak var controller: AppController?

    init(controller: AppController) {
        self.controller = controller
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Keep the two navigation items and the separator that follows them.
        var cutoff = menu.items.count
        var separators = 0
        for (i, item) in menu.items.enumerated() where item.isSeparatorItem {
            separators += 1
            if separators == 1 { cutoff = i + 1; break }
        }
        while menu.items.count > cutoff { menu.removeItem(at: cutoff) }
        guard let c = controller else { return }

        for (i, ws) in c.workspaces.enumerated() {
            let item = NSMenuItem(title: ws.name, action: #selector(AppController.cmdSelectWorkspace(_:)), keyEquivalent: "")
            item.tag = i
            item.target = c
            item.state = ws.id == c.selectedId ? .on : .off
            if i < 9 { item.keyEquivalent = "\(i + 1)" }
            menu.addItem(item)
        }
        if c.workspaces.isEmpty {
            let item = NSMenuItem(title: "No Workspaces", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
