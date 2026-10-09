import Foundation

/// Abstraction for live detection events. `MockDetectionFeed` is used in v1;
/// a future `PythonDetectionFeed` can spawn `app.py live --jsonl` and decode the same JSON shape.
protocol DetectionFeed: AnyObject {
    var onEvent: (@Sendable (DetectionEvent) -> Void)? { get set }
    func start(interval: TimeInterval)
    func stop()
}

/// Placeholder for wiring to the Python SSLAM process (not implemented in v1).
final class PythonDetectionFeed: DetectionFeed {
    var onEvent: (@Sendable (DetectionEvent) -> Void)?

    func start(interval: TimeInterval) {
        // Future: Process(.venv/bin/python, ["app.py", "live", "--offline", "--jsonl", path])
    }

    func stop() {}
}
