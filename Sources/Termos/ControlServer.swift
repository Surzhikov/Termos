import AppKit
import Darwin

/// Local control channel: a Unix socket that only the current user can open.
/// One JSON object per line in each direction: {"cmd": "...", "args": {...}} → {"ok": true, "result": ...}
/// The `Termos --mcp` process (the MCP server Claude Code starts) talks to the app through it.
enum ControlSocket {
    /// Explicit single-socket override (test instances). When set, the instance registry is not used.
    static var overridePath: String? { ProcessInfo.processInfo.environment["TERMOS_SOCKET"] }

    static var path: String {
        // Per-user temp dir (/var/folders/…/T/) is private to the user and short enough for sun_path.
        overridePath ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("termos-control.sock")
    }

    /// One socket per running app instance, so several Termos instances can be controlled at once.
    static var instancesDir: String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("termos-instances")
    }

    static func instanceSocket(_ id: String) -> String {
        (instancesDir as NSString).appendingPathComponent("\(id).sock")
    }

    static func instanceInfo(_ id: String) -> String {
        (instancesDir as NSString).appendingPathComponent("\(id).json")
    }

    /// Whether some process is listening on this socket.
    static func isAlive(_ path: String) -> Bool {
        guard var addr = makeAddress(path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }

    static func makeAddress(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
            buf[bytes.count] = 0
        }
        return addr
    }

    /// Reads one newline-terminated line from a socket.
    static func readLine(_ fd: Int32) -> Data? {
        var data = Data()
        var byte: UInt8 = 0
        while true {
            let n = read(fd, &byte, 1)
            if n <= 0 { return data.isEmpty ? nil : data }
            if byte == 10 { return data }
            data.append(byte)
        }
    }

    static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { return }
                off += n
            }
        }
    }
}

final class ControlServer {
    /// Id of this app instance (set in `start`, when not in single-socket mode).
    /// Terminals export it as TERMOS_INSTANCE so MCP clients started inside them
    /// (e.g. Claude Code) automatically talk to this instance.
    static private(set) var currentInstanceId: String?

    private let handler: (String, [String: Any]) throws -> Any
    private var listenFDs: [Int32] = []
    private var ownsDefaultSocket = false
    /// Supplies extra fields (workspace names) for the instance info file used by MCP discovery.
    var infoProvider: (() -> [String: Any])?

    init(handler: @escaping (String, [String: Any]) throws -> Any) {
        self.handler = handler
    }

    func start() {
        if ControlSocket.overridePath != nil {
            // Single-socket mode (test instances): one fixed socket, no registry.
            _ = bindListen(ControlSocket.path)
            return
        }
        let fm = FileManager.default
        let dir = ControlSocket.instancesDir
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        cleanStaleInstances(in: dir)

        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let sock = ControlSocket.instanceSocket(id)
        unlink(sock)
        if bindListen(sock) != nil {
            ControlServer.currentInstanceId = id
            writeInfo()
        }

        // Also claim the legacy default socket for old clients — but only if it is free,
        // so a second instance never steals control from the first.
        if !ControlSocket.isAlive(ControlSocket.path) {
            unlink(ControlSocket.path)
            if bindListen(ControlSocket.path) != nil { ownsDefaultSocket = true }
        }
    }

    /// Rewrites the info file (instance id, pid, workspace names) used by MCP discovery.
    func writeInfo() {
        guard let id = ControlServer.currentInstanceId else { return }
        var info: [String: Any] = ["id": id, "pid": ProcessInfo.processInfo.processIdentifier]
        if let more = infoProvider?() { for (k, v) in more { info[k] = v } }
        if let d = try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]) {
            try? d.write(to: URL(fileURLWithPath: ControlSocket.instanceInfo(id)), options: .atomic)
        }
    }

    private func bindListen(_ path: String) -> Int32? {
        guard var addr = ControlSocket.makeAddress(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard ok, listen(fd, 8) == 0 else { close(fd); return nil }
        chmod(path, 0o600)
        listenFDs.append(fd)
        Thread.detachNewThread { [weak self] in self?.acceptLoop(fd) }
        return fd
    }

    private func cleanStaleInstances(in dir: String) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return }
        for f in files where f.hasSuffix(".sock") {
            let p = (dir as NSString).appendingPathComponent(f)
            if !ControlSocket.isAlive(p) {
                unlink(p)
                try? fm.removeItem(atPath: (p as NSString).deletingPathExtension + ".json")
            }
        }
    }

    func stop() {
        let fds = listenFDs
        listenFDs = []
        fds.forEach { close($0) }
        if let id = ControlServer.currentInstanceId {
            unlink(ControlSocket.instanceSocket(id))
            try? FileManager.default.removeItem(atPath: ControlSocket.instanceInfo(id))
            ControlServer.currentInstanceId = nil
        }
        if ownsDefaultSocket { unlink(ControlSocket.path) }
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { return }
            Thread.detachNewThread { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        while let line = ControlSocket.readLine(fd) {
            var reply: [String: Any]
            do {
                guard let obj = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let cmd = obj["cmd"] as? String else { throw ControlError("bad request") }
                let args = obj["args"] as? [String: Any] ?? [:]
                var result: Result<Any, Error> = .failure(ControlError("not run"))
                DispatchQueue.main.sync {
                    result = Result { try self.handler(cmd, args) }
                }
                reply = ["ok": true, "result": try result.get()]
            } catch {
                reply = ["ok": false, "error": (error as? ControlError)?.message ?? "\(error)"]
            }
            var data = (try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])) ?? Data()
            data.append(10)
            ControlSocket.writeAll(fd, data)
        }
    }
}

struct ControlError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
