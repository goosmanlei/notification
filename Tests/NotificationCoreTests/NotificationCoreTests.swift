import Foundation
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
private func unwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw NSError(domain: "CoreChecks", code: 1) }
    return value
}

@main struct RunChecks {
    static func main() {
        let suite = NotificationCoreTests()
        let tests: [(String, () throws -> Void)] = [
            ("payload parsing and dismissal deduplication", suite.testPayloadChangesAndDismissalDeduplication),
            ("live database inserts, updates, startup baseline", suite.testDatabaseSkipsHistoryButReceivesInsertsAndUpdates),
            ("missing database does not create a file", suite.testMissingDatabaseIsNotCreated),
            ("approval lifecycle and payload minimization", suite.testApprovalLifecycleDoesNotStoreCommand),
            ("sync and async input lifecycle", suite.testInputAndAsyncInputLifecycle),
            ("inbox expiry, permissions, consume once", suite.testInboxDiscardsExpiredEventsAndConsumesOnce)
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
