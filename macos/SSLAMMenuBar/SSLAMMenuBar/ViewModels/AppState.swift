import AppKit
import Combine
import Foundation
import SwiftUI

struct LogEntry: Identifiable, Equatable {
    let id: UUID
    let recordedAt: Date
    let text: String

    init(id: UUID = UUID(), recordedAt: Date = Date(), text: String) {
        self.id = id
        self.recordedAt = recordedAt
        self.text = text
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var tickerEvent: DetectionEvent?
    @Published private(set) var tickerRevision = 0
    @Published private(set) var logEntries: [LogEntry] = []
    @Published var statusMessage = "Idle"

    @AppStorage("minScore") var minScore: Double = 0.15
    @AppStorage("mockInterval") var mockInterval: Double = 2.0
    @AppStorage("autoScrollLog") var autoScrollLog = true

    private let feed: DetectionFeed = MockDetectionFeed()

    init() {
        feed.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handle(event: event)
            }
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        statusMessage = "Listening (mock)"
        feed.start(interval: mockInterval)
    }

    func stop() {
        guard isRunning else { return }
        feed.stop()
        isRunning = false
        statusMessage = "Stopped"
    }

    func quit() {
        stop()
        NSApplication.shared.terminate(nil)
    }

    var tickerDisplayText: String {
        guard let event = tickerEvent else { return statusMessage }
        return event.displayLine(minScore: minScore)
    }

    private func handle(event: DetectionEvent) {
        withAnimation(.easeInOut(duration: 0.25)) {
            tickerEvent = event
            tickerRevision += 1
        }
        let entry = LogEntry(text: event.logLine(minScore: minScore))
        logEntries.append(entry)
    }
}
