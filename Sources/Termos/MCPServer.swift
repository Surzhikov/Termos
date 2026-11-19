import AppKit
import Darwin

/// `Termos --mcp`: a stdio MCP server (newline-delimited JSON-RPC 2.0) for Claude Code.
/// Each tool call is forwarded to the running Termos app over the control socket;
/// the app is launched if it isn't running.
enum MCPServer {
    static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    static func run() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty,
                  let data = line.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let id = msg["id"]
            let method = msg["method"] as? String ?? ""
            let params = msg["params"] as? [String: Any] ?? [:]
            guard id != nil else { continue }  // notifications (e.g. notifications/initialized) need no reply

            switch method {
            case "initialize":
                let requested = params["protocolVersion"] as? String ?? supportedVersions[0]
                respond(id, [
                    "protocolVersion": supportedVersions.contains(requested) ? requested : supportedVersions[0],
                    "capabilities": ["tools": [:] as [String: Any]],
                    "serverInfo": ["name": "termos", "version": "0.1"],
                    "instructions": "Controls the Termos terminal app: workspaces (groups of terminals in a split layout) and the terminals in them. Call termos_list first to get ids.",
                ])
            case "ping":
                respond(id, [:])
            case "tools/list":
                respond(id, ["tools": tools])
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let args = params["arguments"] as? [String: Any] ?? [:]
                respond(id, callTool(name, args))
            default:
                respondError(id, code: -32601, message: "Method not found: \(method)")
            }
        }
        exit(0)
    }

    // MARK: - Tools

    private static let themeIds = TerminalTheme.all.map(\.id)
    private static let labelIds = BorderLabel.allCases.map(\.rawValue)

    private static var terminalSpec: [String: Any] {
        [
            "type": "object",
            "properties": [
                "name": ["type": "string", "description": "Title shown in the terminal header and sidebar"],
                "cwd": ["type": "string", "description": "Working directory (~ allowed)"],
                "command": ["type": "string", "description": "Command typed into the shell after it starts, e.g. `ssh host` or `npm run dev`. Saved as the terminal's startup command."],
                "theme": ["type": "string", "enum": themeIds, "description": "Color scheme"],
                "background": ["type": "string", "description": "Custom background color as hex, e.g. 1e3a5f"],
                "label": ["type": "string", "enum": labelIds, "description": "Colored border label"],
            ],
            "additionalProperties": false,
        ]
    }

    private static func obj(_ props: [String: Any], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": props, "required": required, "additionalProperties": false]
    }

    private static var tools: [[String: Any]] {
        [
            [
                "name": "termos_list",
                "description": "List all workspaces and their terminals (ids, names, titles, working directories, running programs, colors).",
                "inputSchema": obj([:]),
                "annotations": ["readOnlyHint": true],
            ],
            [
                "name": "termos_create_workspace",
                "description": "Create a workspace with terminals laid out in a grid of `columns` × `rows` (filled left to right, top to bottom; the last row may be shorter). For more terminals than fit, call it again for another workspace.",
                "inputSchema": obj([
                    "name": ["type": "string"],
                    "color": ["type": "string", "description": "Sidebar color: red, orange, yellow, green, blue, purple, pink or hex"],
                    "columns": ["type": "integer", "minimum": 1, "maximum": 8],
                    "rows": ["type": "integer", "minimum": 1, "maximum": 6],
                    "cwd": ["type": "string", "description": "Default working directory for terminals without their own"],
                    "theme": ["type": "string", "enum": themeIds, "description": "Default color scheme"],
                    "terminals": ["type": "array", "items": terminalSpec, "description": "One entry per terminal"],
                ]),
            ],
            [
                "name": "termos_add_terminal",
                "description": "Add a terminal to a workspace. Without next_to/direction it goes wherever there is most room (the largest terminal is split along its longer side).",
                "inputSchema": obj([
                    "workspace": ["type": "string", "description": "Workspace id or name (default: current)"],
                    "next_to": ["type": "string", "description": "Terminal id or name to split"],
                    "direction": ["type": "string", "enum": ["right", "down", "left", "up"]],
                    "name": ["type": "string"], "cwd": ["type": "string"], "command": ["type": "string"],
                    "theme": ["type": "string", "enum": themeIds],
                    "background": ["type": "string"],
                    "label": ["type": "string", "enum": labelIds],
                ]),
            ],
            [
                "name": "termos_run",
                "description": "Type a command into a terminal and press Enter (set enter=false to only type it).",
                "inputSchema": obj([
                    "terminal": ["type": "string", "description": "Terminal id or name"],
                    "command": ["type": "string"],
                    "enter": ["type": "boolean"],
                ], required: ["terminal", "command"]),
            ],
            [
                "name": "termos_read",
                "description": "Read the last lines of a terminal's screen and scrollback.",
                "inputSchema": obj([
                    "terminal": ["type": "string"],
                    "lines": ["type": "integer", "minimum": 1, "maximum": 2000],
                ], required: ["terminal"]),
                "annotations": ["readOnlyHint": true],
            ],
            [
                "name": "termos_update_terminal",
                "description": "Rename a terminal or change its colors, border label or startup command.",
                "inputSchema": obj([
                    "terminal": ["type": "string"],
                    "name": ["type": "string", "description": "Empty string clears the custom name"],
                    "theme": ["type": "string", "enum": themeIds],
                    "background": ["type": "string"],
                    "label": ["type": "string", "enum": labelIds],
                    "startup_command": ["type": "string", "description": "Empty string clears it"],
                ], required: ["terminal"]),
            ],
            [
                "name": "termos_update_workspace",
                "description": "Rename a workspace or change its color.",
                "inputSchema": obj([
                    "workspace": ["type": "string"], "name": ["type": "string"], "color": ["type": "string"],
                ], required: ["workspace"]),
            ],
            [
                "name": "termos_focus",
                "description": "Show a workspace or focus a terminal. With terminal + restore=true, a frozen terminal is also restored (its startup command is run).",
                "inputSchema": obj(["workspace": ["type": "string"], "terminal": ["type": "string"],
                                    "restore": ["type": "boolean", "description": "Restore the terminal first if it is frozen"]]),
            ],
            [
                "name": "termos_freeze_terminal",
                "description": "Freeze a terminal: stop its shell and running programs to free memory, keeping the name, startup command and layout place. A snapshot placeholder is shown until restored.",
                "inputSchema": obj(["terminal": ["type": "string"]], required: ["terminal"]),
                "annotations": ["destructiveHint": true],
            ],
            [
                "name": "termos_restore_terminal",
                "description": "Restore a frozen terminal: starts the shell again and runs its startup command.",
                "inputSchema": obj(["terminal": ["type": "string"]], required: ["terminal"]),
            ],
            [
                "name": "termos_open_session",
                "description": "Open a .termos file as the project of this Termos window: replaces the current workspaces and keeps the file updated with every change.",
                "inputSchema": obj(["path": ["type": "string"]], required: ["path"]),
            ],
            [
                "name": "termos_new_project",
                "description": "Create a new Termos project file and start working in it (clears the current workspaces).",
                "inputSchema": obj(["path": ["type": "string"]], required: ["path"]),
            ],
            [
                "name": "termos_close_terminal",
                "description": "Close a terminal. Refuses if a program is running in it unless force=true.",
                "inputSchema": obj(["terminal": ["type": "string"], "force": ["type": "boolean"]], required: ["terminal"]),
                "annotations": ["destructiveHint": true],
            ],
            [
                "name": "termos_close_workspace",
                "description": "Close a workspace with all its terminals. Refuses if programs are running unless force=true.",
                "inputSchema": obj(["workspace": ["type": "string"], "force": ["type": "boolean"]], required: ["workspace"]),
                "annotations": ["destructiveHint": true],
            ],
            [
                "name": "termos_save_layout",
                "description": "Save all workspaces (or one) to a .termos layout file.",
                "inputSchema": obj(["path": ["type": "string"], "workspace": ["type": "string"]], required: ["path"]),
            ],
            [
                "name": "termos_open_layout",
                "description": "Open a .termos layout file, adding its workspaces.",
                "inputSchema": obj(["path": ["type": "string"]], required: ["path"]),
            ],
        ]
    }

    private static func callTool(_ name: String, _ args: [String: Any]) -> [String: Any] {
        let cmd = name.hasPrefix("termos_") ? String(name.dropFirst("termos_".count)) : name
        do {
            let result = try send(cmd, args)
            let text: String
            if let s = result as? String {
                text = s
            } else {
                let d = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                text = String(data: d, encoding: .utf8) ?? ""
            }
            return ["content": [["type": "text", "text": text]]]
        } catch {
            let msg = (error as? ControlError)?.message ?? "\(error)"
            return ["content": [["type": "text", "text": msg]], "isError": true]
        }
    }

    // MARK: - Talking to the app

    /// Running Termos instances found in the per-user instance registry.
    private static func listInstances() -> [[String: Any]] {
        let dir = ControlSocket.instancesDir
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        var out: [[String: Any]] = []
        for f in files where f.hasSuffix(".sock") {
            let id = (f as NSString).deletingPathExtension
            let sock = ControlSocket.instanceSocket(id)
            guard ControlSocket.isAlive(sock) else { continue }
            var info: [String: Any] = ["id": id]
            if let data = try? Data(contentsOf: URL(fileURLWithPath: ControlSocket.instanceInfo(id))),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for (k, v) in obj { info[k] = v }
            }
            out.append(info)
        }
        return out
    }

    private static func send(_ cmd: String, _ args: [String: Any]) throws -> Any {
        let fd = try connect()
        defer { close(fd) }
        var data = try JSONSerialization.data(withJSONObject: ["cmd": cmd, "args": args])
        data.append(10)
        ControlSocket.writeAll(fd, data)
        guard let line = ControlSocket.readLine(fd),
              let reply = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw ControlError("no reply from Termos")
        }
        if reply["ok"] as? Bool == true { return reply["result"] ?? NSNull() }
        throw ControlError(reply["error"] as? String ?? "Termos returned an error")
    }

    private static func connect() throws -> Int32 {
        // 1. TERMOS_INSTANCE: set in every terminal Termos starts, so an MCP client
        //    (Claude Code) running inside a pane always talks to its own Termos window.
        if let want = ProcessInfo.processInfo.environment["TERMOS_INSTANCE"], !want.isEmpty {
            let sock = ControlSocket.instanceSocket(want)
            if let fd = tryConnect(sock) { return fd }
            throw ControlError("the Termos instance this terminal belonged to (id \(want)) is no longer running")
        }

        // 2. Explicit choice for the whole Claude Code session.
        if let want = ProcessInfo.processInfo.environment["TERMOS_INSTANCE_ID"], !want.isEmpty {
            if let fd = tryConnect(ControlSocket.instanceSocket(want)) { return fd }
            throw ControlError("no running Termos instance with id \(want) (set in TERMOS_INSTANCE_ID)")
        }

        // 3. Exactly one instance running: use it (this includes the legacy default socket
        //    for old clients and single-socket test instances).
        let instances = listInstances()
        if instances.count == 1, let fd = tryConnect(ControlSocket.instanceSocket(instances[0]["id"] as! String)) {
            return fd
        }
        if instances.isEmpty {
            // No registry entries: single-socket mode or the app isn't running yet.
            if let fd = tryConnect(ControlSocket.path) { return fd }
            launchApp()
            for _ in 0..<50 {
                usleep(200_000)
                if let fd = tryConnect(ControlSocket.path) { return fd }
                if let fd = tryConnect(ControlSocket.instanceSocket((listInstances().first?["id"] as? String) ?? "")) { return fd }
            }
            throw ControlError("Termos is not running and could not be started")
        }

        // 4. Several instances and no context — let the user pick.
        let lines = instances.map { i -> String in
            let id = i["id"] as? String ?? "?"
            let pid = i["pid"] as? Int32 ?? 0
            let names = (i["workspaces"] as? [String])?.joined(separator: ", ") ?? "no workspaces"
            return "  - \(id) (pid \(pid)): \(names)"
        }
        throw ControlError("""
            \(instances.count) Termos instances are running; I don't know which one to control.
            \(lines.joined(separator: "\n"))
            Start Claude Code inside a Termos terminal (it picks its own instance automatically), \
            or set TERMOS_INSTANCE_ID to one of the ids above.
            """)
    }

    private static func tryConnect(_ path: String) -> Int32? {
        guard var addr = ControlSocket.makeAddress(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        if ok { return fd }
        close(fd)
        return nil
    }

    /// Opens the Termos.app bundle this binary lives in.
    private static func launchApp() {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let bundle = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard bundle.pathExtension == "app" else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-g", bundle.path]
        try? p.run()
        p.waitUntilExit()
    }

    // MARK: - JSON-RPC output

    private static func respond(_ id: Any?, _ result: [String: Any]) {
        write(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    private static func respondError(_ id: Any?, code: Int, message: String) {
        write(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]])
    }

    private static func write(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]),
              let s = String(data: d, encoding: .utf8) else { return }
        print(s)
    }
}
