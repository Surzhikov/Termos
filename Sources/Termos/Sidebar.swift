import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension UTType {
    static let termosPane = UTType(exportedAs: "local.termos.pane")
}

struct SidebarView: View {
    @ObservedObject var app: AppController
    @State private var newTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(app.workspaces.enumerated()), id: \.element.id) { idx, ws in
                        WorkspaceRow(ws: ws, app: app, index: idx)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.top, 10)
                .padding(.bottom, 8)
            }
            Divider().opacity(0.5)
            HStack(spacing: 6) {
                Button { app.newWorkspace(nil) } label: {
                    Label("New Workspace", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("New workspace (⌘T)")
                .onDrop(of: [.termosPane], isTargeted: $newTargeted) { _ in app.dropDraggedPane(on: nil) }
                .background(RoundedRectangle(cornerRadius: 6).fill(newTargeted ? Color.accentColor.opacity(0.25) : .clear).padding(-4))
                Spacer()
                Button { app.dimInactive.toggle() } label: {
                    Image(systemName: app.dimInactive ? "circle.lefthalf.filled" : "circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Dim inactive terminals")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(minWidth: 190)
    }
}

private struct WorkspaceRow: View {
    @ObservedObject var ws: Workspace
    @ObservedObject var app: AppController
    let index: Int
    @State private var expanded = true
    @State private var hover = false
    @State private var dropTargeted = false

    private var selected: Bool { app.selectedId == ws.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 10)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } }
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color(nsColor: ws.color))
                    .frame(width: 10, height: 10)
                Text(ws.name)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if index < 9 && hover {
                    Text("⌘\(index + 1)")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
                Text("\(ws.panes.count)")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color(nsColor: ws.color).opacity(0.22)
                          : (hover ? Color.primary.opacity(0.06) : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(selected ? Color(nsColor: ws.color).opacity(0.55) : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture(count: 2) { app.rename(ws) }
            .onTapGesture { app.select(ws) }
            .background(WorkspaceMenuSurface(ws: ws, app: app))

            if expanded {
                ForEach(ws.panes, id: \.id) { pane in
                    PaneRow(pane: pane, ws: ws, app: app, revision: ws.revision)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: ws.color), lineWidth: 2)
                .opacity(dropTargeted ? 1 : 0)
        )
        // Drop a terminal (dragged by its header) here to move it into this workspace.
        .onDrop(of: [.termosPane], isTargeted: $dropTargeted) { _ in app.dropDraggedPane(on: ws) }
        .padding(.bottom, 4)
    }

}

/// AppKit menus for the sidebar, built at click time so a row re-render
/// (running programs change titles constantly) can't dismiss them.
enum SidebarMenus {
    static func workspace(for ws: Workspace, app: AppController) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        m.addItem(item("New Terminal") { app.addTerminal(to: ws) })
        m.addItem(.separator())
        m.addItem(item("Rename…") { app.rename(ws) })
        let colors = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        let cm = NSMenu()
        for l in BorderLabel.allCases where l != .none {
            let i = item(l.title) { app.setColor(l.color!, for: ws) }
            i.image = PaneView.swatch(l.color!, border: l.color!)
            i.state = ws.color.isClose(to: l.color!) ? .on : .off
            cm.addItem(i)
        }
        colors.submenu = cm
        m.addItem(colors)
        m.addItem(.separator())
        let up = item("Move Up") { app.move(ws, by: -1) }
        up.isEnabled = app.workspaces.first !== ws
        let down = item("Move Down") { app.move(ws, by: 1) }
        down.isEnabled = app.workspaces.last !== ws
        m.addItem(up)
        m.addItem(down)
        m.addItem(.separator())
        m.addItem(item("Close Workspace") { app.closeWorkspace(ws) })
        return m
    }

    static func pane(for pane: PaneView, app: AppController) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        if pane.isHeld {
            m.addItem(item("Restore Terminal") { pane.restore() })
        } else {
            m.addItem(item("Freeze Terminal…") { app.paneWantsFreeze(pane) })
        }
        m.addItem(.separator())
        m.addItem(item("Rename…") { pane.menuRename() })
        let colors = NSMenuItem(title: "Color Scheme", action: nil, keyEquivalent: "")
        colors.submenu = PaneView.themeMenu(target: pane, action: #selector(PaneView.menuTheme(_:)),
                                            current: pane.customBackground == nil ? pane.theme.id : nil)
        m.addItem(colors)
        let labels = NSMenuItem(title: "Border Label", action: nil, keyEquivalent: "")
        labels.submenu = PaneView.labelMenu(target: pane, action: #selector(PaneView.menuLabel(_:)),
                                            current: pane.borderLabel)
        m.addItem(labels)
        m.addItem(.separator())
        m.addItem(item("Close Terminal") { app.paneWantsClose(pane) })
        return m
    }

    private static func item(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
        ClosureMenuItem(title: title, handler: run)
    }
}

extension NSColor {
    /// Same color already applied (color pickers give slightly different components).
    func isClose(to other: NSColor) -> Bool {
        let a = usingColorSpace(.sRGB) ?? self
        let b = other.usingColorSpace(.sRGB) ?? other
        return abs(a.redComponent - b.redComponent) < 0.02
            && abs(a.greenComponent - b.greenComponent) < 0.02
            && abs(a.blueComponent - b.blueComponent) < 0.02
    }
}

/// SwiftUI wrapper for a real AppKit context menu. SwiftUI's .contextMenu rebuilds the
/// menu on every row re-render (running programs change titles constantly), which
/// dismisses open submenus; NSMenu is built once at click time and lives its own life.
/// Clicks pass through to SwiftUI except the right-click that opens the menu.
struct MenuHandlingView: NSViewRepresentable {
    var makeMenu: () -> NSMenu

    func makeNSView(context: Context) -> NSView {
        let v = MenuSurfaceView()
        v.menuProvider = makeMenu
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? MenuSurfaceView)?.menuProvider = makeMenu
    }

    final class MenuSurfaceView: NSView {
        var menuProvider: (() -> NSMenu)?

        override func rightMouseDown(with event: NSEvent) {
            guard let m = menuProvider?() else { return }
            NSMenu.popUpContextMenu(m, with: event, for: self)
        }

        // Let everything else through to SwiftUI underneath.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Convenience wrappers for rows.
struct WorkspaceMenuSurface: View {
    let ws: Workspace
    let app: AppController
    var pane: PaneView?

    var body: some View {
        MenuHandlingView {
            if let pane {
                SidebarMenus.pane(for: pane, app: app)
            } else {
                SidebarMenus.workspace(for: ws, app: app)
            }
        }
        .allowsHitTesting(true)
    }
}

private struct PaneRow: View {
    let pane: PaneView
    @ObservedObject var ws: Workspace
    @ObservedObject var app: AppController
    let revision: Int
    @State private var hover = false

    private var isFocused: Bool { ws.focusedPane === pane && app.selectedId == ws.id }

    var body: some View {
        let t = pane.effectiveTheme
        HStack(spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color(nsColor: t.background))
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Color(nsColor: pane.borderLabel.color ?? t.foreground.withAlphaComponent(0.35)),
                                  lineWidth: pane.borderLabel == .none ? 0.8 : 1.5)
                Text(">")
                    .font(.system(size: 7, weight: .heavy, design: .monospaced))
                    .foregroundStyle(Color(nsColor: t.foreground))
            }
            .frame(width: 14, height: 11)
            Text(pane.displayTitle)
                .font(.system(size: 12, weight: isFocused ? .medium : .regular))
                .foregroundStyle(isFocused ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if pane.isHeld {
                Image(systemName: "snowflake")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .help("Frozen — Restore to start it again")
            } else if ws.zoomedPane === pane {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 30)
        .padding(.trailing, 6)
        .padding(.vertical, 3.5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isFocused ? Color.primary.opacity(0.09) : (hover ? Color.primary.opacity(0.05) : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { app.focus(pane) }
        .background(WorkspaceMenuSurface(ws: ws, app: app, pane: pane))
    }
}

/// Placeholder shown when no project is open: pick or create one, like VS Code's welcome screen.
struct EmptyStateView: View {
    @ObservedObject var app: AppController

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No project open")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("A project is a file with your workspaces and terminals.\nIt is saved automatically as you work.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            VStack(spacing: 8) {
                Button { app.cmdNewProject(nil) } label: {
                    Label("New Project…", systemImage: "plus").frame(minWidth: 210)
                }
                Button { app.cmdOpenProject(nil) } label: {
                    Label("Open Project…", systemImage: "folder").frame(minWidth: 210)
                }
            }
            .controlSize(.large)
            Text("⇧⌘N new project · ⌘O open project")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: NSColor(hex: "121316")!))
    }
}
