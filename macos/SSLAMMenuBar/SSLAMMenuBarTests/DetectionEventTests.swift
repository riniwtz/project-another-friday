import XCTest
@testable import SSLAMMenuBar

final class DetectionEventTests: XCTestCase {
    func testDisplayLineJoinsScoresAboveMin() {
        let event = DetectionEvent(
            audioEndSeconds: 5,
            rms: 0.05,
            status: "ok",
            predictions: [
                Prediction(label: "Speech", score: 0.72),
                Prediction(label: "Music", score: 0.10),
            ],
            inferenceMs: 610
        )
        XCTAssertEqual(event.displayLine(minScore: 0.15), "Speech 0.72")
    }

    func testDisplayLineSilence() {
        let event = DetectionEvent(
            audioEndSeconds: 3,
            rms: 0.0012,
            status: "silence",
            predictions: [],
            inferenceMs: 0
        )
        XCTAssertTrue(event.displayLine(minScore: 0.15).contains("Quiet input"))
    }

    func testDecodesPythonJSONLShape() throws {
        let json = """
        {"timestamp_utc":"2026-01-01T00:00:00+00:00","audio_end_seconds":5.0,"rms":0.05,"status":"ok","predictions":[{"label":"Speech","score":0.72}],"inference_ms":610.0}
        """
        let data = Data(json.utf8)
        let event = try JSONDecoder().decode(DetectionEvent.self, from: data)
        XCTAssertEqual(event.audioEndSeconds, 5.0)
        XCTAssertEqual(event.predictions.first?.label, "Speech")
        XCTAssertEqual(event.logLine(minScore: 0.15), "[    5.0s] Speech 0.72  (610 ms)")
    }
}
