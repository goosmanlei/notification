import Foundation

public enum ProjectContext {
    public static func label(for directory: String?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        guard let directory, directory.hasPrefix("/"), !directory.contains("\0") else { return nil }
        let current = URL(fileURLWithPath: directory).standardizedFileURL
        let managed = home.appendingPathComponent("codex-path").standardizedFileURL.pathComponents
        for candidate in [current, current.resolvingSymlinksInPath()] {
            let components = candidate.pathComponents
            if components.starts(with: managed), components.count >= managed.count + 2 {
                return components.dropFirst(managed.count).prefix(2).joined(separator: "/")
            }
        }
        // Outside codex-path, use the nearest repository root when the hook runs in a subdirectory.
        var ancestor = current
        while ancestor.path != "/" {
            if FileManager.default.fileExists(atPath: ancestor.appendingPathComponent(".git").path) {
                return ancestor.lastPathComponent
            }
            ancestor.deleteLastPathComponent()
        }
        return current.lastPathComponent
    }
}
