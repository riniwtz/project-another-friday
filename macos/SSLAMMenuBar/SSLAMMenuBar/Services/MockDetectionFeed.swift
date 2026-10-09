import Foundation

final class MockDetectionFeed: DetectionFeed, @unchecked Sendable {
    var onEvent: (@Sendable (DetectionEvent) -> Void)?

    private var task: Task<Void, Never>?
    private let lock = NSLock()
    private var audioEndSeconds: Double = 3

    private static let scenarios: [(status: String, predictions: [Prediction], rms: Double, inferenceMs: Double)] = [
        ("ok", [Prediction(label: "Speech", score: 0.72), Prediction(label: "Inside, small room", score: 0.34)], 0.05, 650),
        ("ok", [Prediction(label: "Music", score: 0.51), Prediction(label: "Speech", score: 0.42)], 0.08, 610),
        ("ok", [Prediction(label: "Dog", score: 0.63), Prediction(label: "Bark", score: 0.41)], 0.06, 590),
        ("silence", [], 0.0012, 0),
        ("ok", [Prediction(label: "Keyboard", score: 0.55), Prediction(label: "Computer keyboard", score: 0.38)], 0.04, 720),
    ]

    func start(interval: TimeInterval) {
        stop()
        audioEndSeconds = 3
        let step = max(0.5, interval)
        task = Task { [weak self] in
            var index = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                let scenario = Self.scenarios[index % Self.scenarios.count]
                index += 1
                let end = self.nextEndSeconds(step: step)
                let event = DetectionEvent(
                    timestampUTC: ISO8601DateFormatter().string(from: Date()),
                    audioEndSeconds: end,
                    rms: scenario.rms,
                    status: scenario.status,
                    predictions: scenario.predictions,
                    inferenceMs: scenario.inferenceMs,
                    source: "mock: microphone",
                    model: "ta012/SSLAM_AS2M_Finetuned"
                )
                let handler = self.lock.withLock { self.onEvent }
                handler?(event)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func nextEndSeconds(step: TimeInterval) -> Double {
        lock.lock()
        defer { lock.unlock() }
        audioEndSeconds += step
        return audioEndSeconds
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
