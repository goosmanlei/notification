import Foundation
import Darwin
import CSQLite
import NotificationCore

final class NotificationCoreTests {
    private func payload(title: String = "Test", body: String = "hello", response: Int = 0) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: [
            "app": "com.example.test", "date": 123.0, "resp": ["act": response],
            "req": ["titl": title, "subt": "subtitle", "body": body, "iden": "n-1"]
        ], format: .binary, options: 0)
    }

    func testPayloadChangesAndDismissalDeduplication() throws {
        let a = try unwrap(PayloadParser.parse(payload(), recordID: 1))
        let dismissed = try unwrap(PayloadParser.parse(payload(response: 1), recordID: 1))
        let updated = try unwrap(PayloadParser.parse(payload(body: "updated"), recordID: 1))
        checkEqual(a.title, "Test"); checkEqual(a.body, "subtitle\nhello")
        checkEqual(a.id, dismissed.id)
        checkNotEqual(a.id, updated.id)
        checkNil(PayloadParser.parse(Data("invalid".utf8), recordID: 1))
    }

    func testDatabaseSkipsHistoryButReceivesInsertsAndUpdates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("db")
        var writer: OpaquePointer?
        checkEqual(sqlite3_open(path.path, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        checkEqual(sqlite3_exec(writer, "CREATE TABLE record (rec_id INTEGER PRIMARY KEY, data BLOB)", nil, nil, nil), SQLITE_OK)
        func put(_ id: Int64, _ data: Data) {
            var statement: OpaquePointer?
            checkEqual(sqlite3_prepare_v2(writer, "INSERT OR REPLACE INTO record VALUES (?, ?)", -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, id)
            _ = data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            checkEqual(sqlite3_step(statement), SQLITE_DONE)
        }
        put(1, try payload())
        let reader = NotificationDatabase(path: path)
        checkEqual(try reader.poll().count, 0)
        put(2, try payload(title: "new"))
        checkEqual(try reader.poll().map(\.title), ["new"])
        checkEqual(try reader.poll().count, 0)
        put(2, try payload(title: "new", response: 2))
        checkEqual(try reader.poll().count, 0)
        put(2, try payload(title: "changed"))
        checkEqual(try reader.poll().map(\.title), ["changed"])
    }

    func testMissingDatabaseIsNotCreated() {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        checkThrows(try NotificationDatabase(path: path).poll())
        checkFalse(FileManager.default.fileExists(atPath: path.path))
    }

    private func hook(_ event: String, tool: String = "Bash", input: [String: Any] = [:]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["hook_event_name": event, "session_id": "session-test",
            "turn_id": "turn-test", "tool_name": tool, "cwd": "/example/project", "tool_input": input])
    }

    func testApprovalLifecycleDoesNotStoreCommand() throws {
        let input = ["command": "echo secret-value"]
        let show = try unwrap(CodexHook.parse(hook("PermissionRequest", input: input)))
        let resolve = try unwrap(CodexHook.parse(hook("PostToolUse", input: input)))
        checkEqual(show.action, .show); checkEqual(show.notice?.kind, .approval)
        checkEqual(show.key, resolve.key); checkEqual(resolve.action, .resolve)
        checkEqual(show.notice?.context, "project")
        checkFalse(String(decoding: try JSONEncoder().encode(show), as: UTF8.self).contains("secret-value"))
        checkNil(CodexHook.parse(try hook("PreToolUse", tool: "Bash")))
        checkEqual(CodexHook.parse(try hook("Stop"))?.action, .clearSession)
    }

    func testInputAndAsyncInputLifecycle() throws {
        let input: [String: Any] = ["questions": [["question": "Choose a target"]]]
        let show = try unwrap(CodexHook.parse(hook("PreToolUse", tool: "request_user_input", input: input)))
        checkEqual(show.notice?.body, "Choose a target")
        checkEqual(show.notice?.kind, .input)
        checkEqual(CodexHook.parse(try hook("PostToolUse", tool: "request_user_input", input: input))?.key, show.key)
        checkNil(CodexHook.parse(try hook("PostToolUse", tool: "request_user_input_async", input: input)))
    }

    func testInboxDiscardsExpiredEventsAndConsumesOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        let fresh = try unwrap(CodexHook.parse(hook("PermissionRequest"), now: now))
        let stale = try unwrap(CodexHook.parse(hook("PermissionRequest"), now: now.addingTimeInterval(-180)))
        try EventInbox.write(fresh, to: directory); try EventInbox.write(stale, to: directory)
        let events = EventInbox.drain(from: directory, now: now)
        checkEqual(events.count, 1); checkEqual(events.first?.createdAt, fresh.createdAt)
        checkTrue(EventInbox.drain(from: directory, now: now).isEmpty)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        checkEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testProjectLabelsRespectManagedBoundaryAndRepositoryRoots() throws {
        let home = URL(fileURLWithPath: "/Users/example")
        checkEqual(ProjectContext.label(for: "/Users/example/codex-path/tool/notification", home: home), "tool/notification")
        checkEqual(ProjectContext.label(for: "/Users/example/codex-path/tool/notification/Sources/Core", home: home), "tool/notification")
        checkEqual(ProjectContext.label(for: "/Users/example/codex-path-other/tool/notification", home: home), "notification")
        checkEqual(ProjectContext.label(for: "/Users/example/codex-path/tool", home: home), "tool")
        checkEqual(ProjectContext.label(for: "/work/My Project", home: home), "My Project")
        checkNil(ProjectContext.label(for: nil, home: home))
        checkNil(ProjectContext.label(for: "relative/path", home: home))
        let repository = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: repository) }
        try FileManager.default.createDirectory(at: repository.appendingPathComponent(".git"), withIntermediateDirectories: true)
        checkEqual(ProjectContext.label(for: repository.appendingPathComponent("nested/source").path, home: home), repository.lastPathComponent)
    }

    func testCompactHookContentAndBackwardCompatibility() throws {
        let approval = try unwrap(CodexHook.parse(hook("PermissionRequest", input: ["justification": "运行构建检查", "command": "secret"])))
        checkEqual(approval.notice?.title, "待审批")
        checkEqual(approval.notice?.body, "运行构建检查")
        let generic = try unwrap(CodexHook.parse(hook("PermissionRequest", tool: "functions.exec_command")))
        checkEqual(generic.notice?.body, "exec_command")
        let question = try unwrap(CodexHook.parse(hook("PreToolUse", tool: "request_user_input_async", input: ["questions": [["title": "选择环境"], ["title": "选择区域"]]])))
        checkEqual(question.notice?.body, "选择环境\n选择区域")
        var legacy = try unwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(approval.notice)) as? [String: Any])
        legacy.removeValue(forKey: "tmux")
        let decoded = try JSONDecoder().decode(Notice.self, from: JSONSerialization.data(withJSONObject: legacy))
        checkNil(decoded.tmux)
        checkEqual(decoded.context, "project")
    }

    func testCommandTimeoutAndLiteralArguments() {
        let before = ProcessInfo.processInfo.systemUptime
        checkNil(LocalCommand.run(URL(fileURLWithPath: "/bin/sleep"), ["2"], timeout: 0.05))
        checkTrue(ProcessInfo.processInfo.systemUptime - before < 1)
        checkEqual(LocalCommand.run(URL(fileURLWithPath: "/usr/bin/printf"), ["%s", "literal; $(printf injected)"]), "literal; $(printf injected)")
    }

    func testSourceMonitorWakesOnWALCommitsWithoutWaitingForFallback() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("db")
        var writer: OpaquePointer?
        checkEqual(sqlite3_open(path.path, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        checkEqual(sqlite3_exec(writer, "PRAGMA journal_mode=WAL; CREATE TABLE record(rec_id INTEGER PRIMARY KEY, data BLOB)", nil, nil, nil), SQLITE_OK)
        let data = try payload()
        func insert(_ id: Int) {
            var statement: OpaquePointer?
            checkEqual(sqlite3_prepare_v2(writer, "INSERT INTO record VALUES (?, ?)", -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(id))
            _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            checkEqual(sqlite3_step(statement), SQLITE_DONE)
        }
        insert(1)
        let ready = DispatchSemaphore(value: 0), received = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "test.notification.wal")
        let reader = NotificationDatabase(path: path)
        var reasons: [SourceMonitor.Reason] = [], failuresToRead = 0
        let monitor = SourceMonitor(paths: [path, URL(fileURLWithPath: path.path + "-wal"), directory],
                                    queue: queue, fallbackInterval: 60) { reason in
            do {
                for _ in try reader.poll() { reasons.append(reason); received.signal() }
            } catch { failuresToRead += 1 }
            if reason == .initial { ready.signal() }
        }
        monitor.start()
        defer { monitor.stop(); queue.sync {} }
        checkEqual(ready.wait(timeout: .now() + 2), .success)
        var samples: [Double] = []
        for id in 2...9 {
            let start = ProcessInfo.processInfo.systemUptime
            insert(id)
            checkEqual(received.wait(timeout: .now() + 2), .success)
            samples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        queue.sync {
            checkEqual(failuresToRead, 0); checkEqual(reasons.count, 8)
            checkTrue(reasons.allSatisfy { $0 == .fileChange })
        }
        let sorted = samples.sorted()
        let median = (sorted[(sorted.count - 1) / 2] + sorted[sorted.count / 2]) / 2
        print(String(format: "WAL commit-to-read: n=%d, median=%.1f ms, max=%.1f ms (60 s fallback not used)", sorted.count, median, sorted.last!))
    }

    func testSourceMonitorHandlesLateFilesReplacementAndFallback() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("events")
        let ready = DispatchSemaphore(value: 0), received = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "test.notification.files")
        var latest = ""
        let monitor = SourceMonitor(paths: [path, directory], queue: queue, fallbackInterval: 60) { reason in
            if let text = try? String(contentsOf: path), text != latest { latest = text; received.signal() }
            if reason == .initial { ready.signal() }
        }
        monitor.start()
        checkEqual(ready.wait(timeout: .now() + 2), .success)
        // The watched file does not exist at startup, then is atomically replaced twice.
        for text in ["first", "replacement"] {
            try text.write(to: path, atomically: true, encoding: .utf8)
            checkEqual(received.wait(timeout: .now() + 2), .success)
        }
        let handle = try FileHandle(forWritingTo: path)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("-append".utf8)); try handle.close()
        checkEqual(received.wait(timeout: .now() + 2), .success)
        queue.sync { checkEqual(latest, "replacement-append") }
        monitor.stop(); queue.sync {}

        // Missing vnode coverage must still poll on every healthy fallback tick.
        let fallback = SourceMonitor(paths: [], queue: queue, fallbackInterval: 0.1) { reason in
            if reason == .initial { ready.signal() }
            if reason == .fallback { received.signal() }
        }
        fallback.start()
        defer { fallback.stop(); queue.sync {} }
        checkEqual(ready.wait(timeout: .now() + 2), .success)
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<3 { checkEqual(received.wait(timeout: .now() + 1), .success) }
        checkTrue(ProcessInfo.processInfo.systemUptime - start < 0.6)
    }

    func testTmuxCaptureNavigationAndStaleTargetsOnIsolatedServer() throws {
        guard let bridge = TmuxBridge.installed() else { print("SKIP isolated tmux integration: tmux unavailable"); return }
        let directory = URL(fileURLWithPath: "/tmp/notification tests,'\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let socket = directory.appendingPathComponent("socket").path
        defer {
            _ = LocalCommand.run(bridge.executable, ["-S", socket, "kill-server"])
            try? FileManager.default.removeItem(at: directory)
        }
        func run(_ arguments: [String]) throws -> String {
            guard let output = LocalCommand.run(bridge.executable, ["-S", socket] + arguments, timeout: 1) else {
                throw NSError(domain: "CoreChecks", code: 2, userInfo: [NSLocalizedDescriptionKey: "tmux failed: \(arguments)"])
            }
            return output
        }
        _ = try run(["-f", "/dev/null", "new-session", "-d", "-s", "unit-session", "-n", "work 'quoted'; literal", "/bin/sleep 60"])
        let identity = try run(["display-message", "-p", "#{pid}\n#{session_id}\n#{pane_id}"]).split(separator: "\n").map(String.init)
        checkEqual(identity.count, 3)
        let environment = ["TMUX": "\(socket),\(identity[0]),\(identity[1].dropFirst())", "TMUX_PANE": identity[2]]
        let panePID = try unwrap(Int32(try run(["display-message", "-p", "-t", identity[2], "#{pane_pid}"]).trimmingCharacters(in: .whitespacesAndNewlines)))
        let original = try unwrap(bridge.capture(environment: environment, processID: panePID))
        checkEqual(original.sessionName, "unit-session")
        checkEqual(original.windowName, "work 'quoted'; literal")
        checkEqual(original.label, "unit-session/work 'quoted'; literal/pane-0")
        checkEqual(original.socketPath, socket)
        checkEqual(try JSONDecoder().decode(TmuxContext.self, from: JSONEncoder().encode(original)), original)
        checkNil(bridge.capture(environment: [:]))
        // A daemon outside the pane must never inherit a false origin from TMUX_PANE.
        checkNil(bridge.capture(environment: environment, processID: 1))
        _ = try run(["rename-window", "-t", original.windowID, "renamed"])
        let other = try run(["split-window", "-d", "-t", original.paneID, "-P", "-F", "#{pane_id}", "/bin/sleep 60"]).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try run(["select-pane", "-t", other])
        _ = try run(["new-window", "-t", original.sessionID, "-n", "other-window", "/bin/sleep 60"])
        let selected = try bridge.select(original)
        checkEqual(selected.windowName, "renamed")
        checkEqual(try run(["display-message", "-p", "-t", original.sessionID, "#{pane_id}"]).trimmingCharacters(in: .whitespacesAndNewlines), original.paneID)
        checkTrue(bridge.attachedClients(for: selected).isEmpty)
        let command = try unwrap(bridge.attachCommand(for: selected))
        checkFalse(command.contains(original.windowName))
        checkEqual(LocalCommand.run(URL(fileURLWithPath: "/bin/sh"), ["-n", "-c", command]), "")
        // Attach a real client on an isolated pseudo-terminal, then switch only that client.
        _ = try run(["new-session", "-d", "-s", "other-session", "/bin/sleep 60"])
        var master: Int32 = -1; var slave: Int32 = -1
        var terminalSize = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        checkEqual(openpty(&master, &slave, nil, nil, &terminalSize), 0)
        let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        let clientProcess = Process()
        clientProcess.executableURL = bridge.executable
        clientProcess.arguments = ["-S", socket, "attach-session", "-t", "other-session"]
        var clientEnvironment = ProcessInfo.processInfo.environment
        clientEnvironment.removeValue(forKey: "TMUX"); clientEnvironment.removeValue(forKey: "TMUX_PANE")
        clientEnvironment["TERM"] = "xterm-256color"
        clientProcess.environment = clientEnvironment
        clientProcess.standardInput = terminal; clientProcess.standardOutput = terminal; clientProcess.standardError = terminal
        try clientProcess.run()
        defer {
            if clientProcess.isRunning { _ = Darwin.kill(clientProcess.processIdentifier, SIGKILL) }
            clientProcess.waitUntilExit()
            Darwin.close(master); Darwin.close(slave)
        }
        var client: TmuxAttachedClient?
        for _ in 0..<25 {
            client = bridge.attachedClients(for: selected).first { $0.pid == clientProcess.processIdentifier }
            if client != nil { break }
            usleep(20_000)
        }
        let attached = try unwrap(client)
        checkNotEqual(attached.sessionID, selected.sessionID)
        try bridge.switchClient(attached, to: selected)
        checkEqual(bridge.attachedClients(for: selected).first { $0.pid == attached.pid }?.sessionID, selected.sessionID)
        var invalid = original; invalid.paneID = "%0; display-message injected"
        checkNil(bridge.attachCommand(for: invalid))
        var stale = original; stale.serverPID += 1
        checkNil(bridge.refreshed(stale))
        checkThrows(try bridge.select(stale))

        // A second CLI connected to a shared server has its own current session in the pane title.
        let fakeCLI = directory.appendingPathComponent("codex")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: fakeCLI)
        _ = try unwrap(LocalCommand.run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--force", "--sign", "-", fakeCLI.path], timeout: 2))
        let remote = try run(["new-window", "-d", "-t", original.sessionID, "-n", "remote", "-P", "-F", "#{pane_id}", "\(TmuxBridge.shellQuote(fakeCLI.path)) 60"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let thread = "12345678-1234-5678-90ab-cdef12345678"
        _ = try run(["select-pane", "-t", remote, "-T", "project | Test | \(thread.prefix(26))... | Context 77% left"])
        let remoteContext = try unwrap(bridge.capture(sessionID: thread, environment: environment, processID: 1))
        checkEqual(remoteContext.paneID, remote)
        checkNotEqual(remoteContext.paneID, original.paneID)
        checkNil(bridge.capture(sessionID: UUID().uuidString, environment: environment, processID: 1))
        _ = try run(["select-pane", "-t", remote, "-T", "project | \(thread.prefix(8))..."])
        checkNil(bridge.capture(sessionID: thread, environment: environment, processID: 1))
        _ = try run(["select-pane", "-t", remote, "-T", "project | \(thread)"])
        checkEqual(bridge.capture(sessionID: thread, environment: environment, processID: 1)?.paneID, remote)
        let duplicate = try run(["new-window", "-d", "-t", original.sessionID, "-n", "duplicate", "-P", "-F", "#{pane_id}", "\(TmuxBridge.shellQuote(fakeCLI.path)) 60"]).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try run(["select-pane", "-t", duplicate, "-T", "project | \(thread)"])
        checkNil(bridge.capture(sessionID: thread, environment: environment, processID: 1))
        _ = try run(["kill-pane", "-t", original.paneID])
        checkNil(bridge.refreshed(original))
        checkThrows(try bridge.select(original))
    }
}


private var failures = 0
private func fail(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
    failures += 1
    print("FAIL \(file):\(line): \(message)")
}
private func checkEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) {
    if a != b { fail("Expected \(a) == \(b)", file: file, line: line) }
}
private func checkNotEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) {
    if a == b { fail("Expected different values", file: file, line: line) }
}
private func checkTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
    if !value { fail("Expected true", file: file, line: line) }
}
private func checkFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
    checkTrue(!value, file: file, line: line)
}
private func checkNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) {
    checkTrue(value == nil, file: file, line: line)
}
private func checkThrows<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try expression(); fail("Expected error", file: file, line: line) } catch { }
}
private func unwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value else { throw NSError(domain: "CoreChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing value at \(file):\(line)"]) }
    return value
}

@main struct RunChecks {
    static func main() {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--locate-tmux" {
            print(TmuxBridge.installed()?.capture(sessionID: CommandLine.arguments[2])?.label ?? "unresolved")
            return
        }
        let suite = NotificationCoreTests()
        let tests: [(String, () throws -> Void)] = [
            ("payload parsing and dismissal deduplication", suite.testPayloadChangesAndDismissalDeduplication),
            ("live database inserts, updates, startup baseline", suite.testDatabaseSkipsHistoryButReceivesInsertsAndUpdates),
            ("missing database does not create a file", suite.testMissingDatabaseIsNotCreated),
            ("approval lifecycle and payload minimization", suite.testApprovalLifecycleDoesNotStoreCommand),
            ("sync and async input lifecycle", suite.testInputAndAsyncInputLifecycle),
            ("inbox expiry, permissions, consume once", suite.testInboxDiscardsExpiredEventsAndConsumesOnce),
            ("project labels and managed path boundaries", suite.testProjectLabelsRespectManagedBoundaryAndRepositoryRoots),
            ("compact content and legacy event decoding", suite.testCompactHookContentAndBackwardCompatibility),
            ("local command timeout and literal arguments", suite.testCommandTimeoutAndLiteralArguments),
            ("WAL writes wake source reads without fallback", suite.testSourceMonitorWakesOnWALCommitsWithoutWaitingForFallback),
            ("source monitor late creation, replacement and fallback", suite.testSourceMonitorHandlesLateFilesReplacementAndFallback),
            ("isolated tmux capture, navigation, rename and stale pane", suite.testTmuxCaptureNavigationAndStaleTargetsOnIsolatedServer)
        ]
        for (name, test) in tests {
            let before = failures
            do { try test() } catch { fail("\(name): \(error)") }
            if failures == before { print("PASS \(name)") }
        }
        print("\(tests.count) checks; \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
