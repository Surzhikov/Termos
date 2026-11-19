import AppKit
import UniformTypeIdentifiers

/// Converts dropped items into the text that gets inserted into the terminal.
enum DropPayload {
    static let acceptedTypes: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .png, .tiff, .string]

    static func canRead(_ pb: NSPasteboard) -> Bool {
        pb.availableType(from: acceptedTypes) != nil
    }

    static func text(from pb: NSPasteboard) -> String? {
        // 1. Files and folders from Finder etc. → escaped paths.
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls.map { shellEscape($0.path) }.joined(separator: " ") + " "
        }
        // 2. Raw image data without a file (e.g. dragged from a browser or the screenshot
        //    thumbnail) → save it to a temp file and insert that path.
        if let path = saveImage(from: pb) {
            return shellEscape(path) + " "
        }
        // 3. Web links → URL as is.
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], let u = urls.first {
            return u.absoluteString
        }
        // 4. Plain text.
        return pb.string(forType: .string)
    }

    /// Backslash-escapes shell metacharacters, the way Terminal.app does. Non-ASCII letters stay as is.
    static func shellEscape(_ path: String) -> String {
        let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./,:@+%=~")
        var out = ""
        for ch in path {
            if ch.isASCII && !safe.contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    private static func saveImage(from pb: NSPasteboard) -> String? {
        let data: Data?
        if let png = pb.data(forType: .png) {
            data = png
        } else if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) {
            data = rep.representation(using: .png, properties: [:])
        } else {
            data = nil
        }
        guard let data else { return nil }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Termos/Drops", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = dir.appendingPathComponent("drop-\(f.string(from: Date()))-\(Int.random(in: 100...999)).png")
        do { try data.write(to: url) } catch { return nil }
        return url.path
    }
}
