import AppKit
import Darwin

enum ProcessInspector {
    /// Process group that owns the shell's terminal (foreground).
    static func foregroundGroup(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let pg = pid_t(info.e_tpgid)
        return pg > 0 ? pg : nil
    }

    /// Process name. Falls back to sysctl so setuid programs (top, sudo…) work too.
    static func name(of pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &buf, UInt32(buf.count)) > 0 { return String(cString: buf) }
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0, size > 0 else { return nil }
        return withUnsafePointer(to: &kp.kp_proc.p_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
        }
    }

    /// Current directory of a process (via proc_pidinfo, no OSC 7 needed).
    static func cwd(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let r = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size)
        guard r == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }
}

/// Wrapper around the system NSColorPanel.
final class ColorPickerBridge: NSObject {
    static let shared = ColorPickerBridge()
    private var handler: ((NSColor) -> Void)?

    func pick(initial: NSColor, handler: @escaping (NSColor) -> Void) {
        self.handler = handler
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.setTarget(nil)
        panel.color = initial
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        panel.isContinuous = true
        panel.orderFront(nil)
    }

    @objc private func changed(_ sender: NSColorPanel) {
        handler?(sender.color.usingColorSpace(.sRGB) ?? sender.color)
    }
}

enum Prompt {
    /// Modal text prompt.
    static func text(title: String, message: String = "", value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        DispatchQueue.main.async { field.selectText(nil) }
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Modal prompt with a tall multi-line text box (for long commands with UUIDs).
    static func multiline(title: String, message: String = "", value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 110))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 440, height: 110))
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.isRichText = false
        field.allowsUndo = true
        field.string = value
        field.isVerticallyResizable = true
        field.isHorizontallyResizable = true
        field.autoresizingMask = [.width]
        field.textContainer?.widthTracksTextView = true
        scroll.documentView = field
        alert.accessoryView = scroll
        alert.window.initialFirstResponder = field
        DispatchQueue.main.async {
            field.selectedRanges = [NSValue(range: NSRange(location: (value as NSString).length, length: 0))]
            scroll.verticalScroller?.floatValue = 1
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Confirmation shown as a sheet on the window, so it can't end up hidden behind it or on another screen.
    /// Return confirms, Esc cancels. While a sheet is already open, the new request is cancelled.
    static func confirmSheet(on window: NSWindow?, _ title: String, message: String, ok: String,
                             completion: @escaping (Bool) -> Void) {
        guard let window, window.attachedSheet == nil else { completion(false); return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: ok).hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        alert.beginSheetModal(for: window) { completion($0 == .alertFirstButtonReturn) }
    }

    static func confirm(_ title: String, message: String = "", ok: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        let okButton = alert.addButton(withTitle: ok)  // Return
        okButton.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")              // Esc
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

/// Tiny diagnostic log: ~/Library/Logs/Termos.log
enum Log {
    static func write(_ msg: String) {
        let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Termos.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
