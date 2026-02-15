import Foundation

/// Protocol for receiving log messages from the sync engine.
/// Implement this to forward logs to your framework's event system (Flutter EventSink, RN EventEmitter, etc.)
public protocol OWHLogHandler: AnyObject {
    func didLog(_ message: String)
}
