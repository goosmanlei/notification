import Foundation
import Darwin

/// Bounded, argument-based local commands. A slow tmux server must not hold up a Codex hook.
public enum LocalCommand {
    public static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval = 0.5) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable; process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let handle = pipe.fileHandleForReading
        let descriptor = handle.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        defer { try? handle.close() }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        var oversized = false
        func drain() {
            while true {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                guard count > 0 else { break }
                if output.count + count > 262_144 { oversized = true; break }
                output.append(contentsOf: buffer.prefix(count))
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning {
            drain()
            if oversized || ProcessInfo.processInfo.systemUptime >= deadline {
                process.terminate()
                usleep(20_000)
                if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                return nil
            }
            usleep(5_000)
        }
        process.waitUntilExit(); drain()
        guard !oversized, process.terminationStatus == 0 else { return nil }
        return String(data: output, encoding: .utf8)
    }
}
