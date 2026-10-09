# SSLAM Menu Bar (macOS)

Local SwiftUI **menu bar** companion for SSLAM audio event detection. v1 uses a **mock event feed** (no Python, microphone, or model). The UI matches the planned layout: logo plus live summary in the menu bar, dropdown actions, and swipe-up ticker updates.

## Requirements

- macOS **14.0+** (Apple Silicon recommended)
- **Xcode 15+** (full Xcode app, not Command Line Tools only)

## Run

1. Open [`SSLAMMenuBar.xcodeproj`](SSLAMMenuBar.xcodeproj) in Xcode.
2. Select the **SSLAMMenuBar** scheme and destination **My Mac**.
3. Press **Run** (⌘R).

The app is an agent (`LSUIElement`): it appears in the menu bar only, not the Dock.

## Using the app

| Menu item | Action |
|-----------|--------|
| **Start** | Begins mock detections every ~2 s (configurable in Settings). |
| **Stop** | Stops updates; last line stays on the label. |
| **Settings…** | Minimum score filter and mock interval. |
| **About…** | SSLAM attribution and links. |
| **Log…** | Full history window with optional auto-scroll. |
| **Quit** | Exit the app. |

The menu bar label shows the **icon** and a **single-line summary** (e.g. `Speech 0.72 | Inside, small room 0.34`). Each new event **swipes up** with a short animation.

## Wiring to Python (future)

The mock feed implements [`DetectionFeed`](SSLAMMenuBar/Services/DetectionFeed.swift). A future backend can spawn the repo’s Python live pipeline and decode JSONL lines into [`DetectionEvent`](SSLAMMenuBar/Models/DetectionEvent.swift) (same shape as [`live_audio.py`](../../live_audio.py)):

```bash
.venv/bin/python app.py live --offline --jsonl /path/to/events.jsonl
```

`PythonDetectionFeed` is a stub placeholder in the Services folder.

## Project layout

- `SSLAMMenuBarApp.swift` — `MenuBarExtra` + auxiliary windows
- `Views/MenuBarLabelView.swift` — icon + swipe ticker
- `Services/MockDetectionFeed.swift` — timed mock events
- `ViewModels/AppState.swift` — shared state and menu actions
