import XCTest

/// Spins the main run loop until `condition` is true or the timeout elapses.
///
/// The client republishes all of its Combine subjects on the main queue, and XCTest runs test
/// methods on the main thread, so pumping the main run loop is what makes those values visible.
@discardableResult
func waitUntil(_ timeout: TimeInterval = 5,
               file: StaticString = #filePath,
               line: UInt = #line,
               _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    return condition()
}

func assertEventually(_ message: String = "condition never became true",
                      timeout: TimeInterval = 5,
                      file: StaticString = #filePath,
                      line: UInt = #line,
                      _ condition: () -> Bool) {
    XCTAssertTrue(waitUntil(timeout, file: file, line: line, condition),
                  message, file: file, line: line)
}

/// A tiny lock-protected box so values written on one queue can be read from another in tests.
final class Locked<Value> {

    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storage = newValue
        }
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&storage)
    }
}
