import Foundation

public enum ProjectContext {
    /// Normalize a settings/hook directory without interpreting shell expressions or relative paths.
    public static func directoryURL(_ directory: String?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        guard let directory else { return nil }
        var path = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.contains("\0"), !path.contains("\n"), !path.contains("\r") else { return nil }
        if path == "~" { path = home.path }
        else if path.hasPrefix("~/") { path = home.appendingPathComponent(String(path.dropFirst(2))).path }
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

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
