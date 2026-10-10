<a id="readme-top"></a>

<br />

<div align="center">
  <a href="https://github.com/riniwtz/project-another-friday">
    <img src="Hark/logo.png" alt="Hark logo" width="96" height="96">
  </a>

  <h3 align="center">Hark</h3>

  <p align="center">
    <strong>Sound, made visible.</strong>
    <br />
    A private, on-device sound-awareness companion for macOS.
    <br />
    <br />
    <a href="#about-the-project"><strong>Explore Hark »</strong></a>
    <br />
    <br />
    <a href="https://github.com/riniwtz/project-another-friday/issues">Report Bug</a>
    &middot;
    <a href="https://github.com/riniwtz/project-another-friday/issues">Request Feature</a>
  </p>
</div>

---

## Table of Contents

<details>
  <summary>Expand</summary>

  <ol>
    <li><a href="#about-the-project">About The Project</a></li>
    <li><a href="#the-experience">The Experience</a></li>
    <li><a href="#features">Features</a></li>
    <li><a href="#privacy-and-accessibility">Privacy and Accessibility</a></li>
    <li><a href="#how-it-works">How It Works</a></li>
    <li><a href="#built-with">Built With</a></li>
    <li><a href="#getting-started">Getting Started</a></li>
    <li><a href="#project-structure">Project Structure</a></li>
    <li><a href="#status-and-goals">Status and Goals</a></li>
    <li><a href="#version-1-boundaries">Version 1 Boundaries</a></li>
    <li><a href="#contributing">Contributing</a></li>
  </ol>

</details>

---

## About The Project

The world is full of sounds that carry important information: a knock at the door, a kettle beginning to whistle, a dog barking outside, or an alarm sounding in another room.

For people who are Deaf or hard of hearing, these everyday sounds can be difficult or impossible to notice. **Hark transforms nearby sounds into meaningful visual awareness.** It identifies environmental events, presents concise captions and recognizable icons, and can deliver calm, configurable notifications when selected sounds occur.

Hark lives in the macOS menu bar and is designed to remain useful without an account, a cloud service, or a continuous internet connection.

> [!IMPORTANT]
> Hark is an awareness tool. It is not a certified emergency, fire, security, or life-safety system.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

---

## The Experience

### Always there, never in the way

Hark stays visible in the menu bar without occupying valuable screen space. As the surrounding soundscape changes, its caption updates with short descriptions such as:

- 🔔 Doorbell ringing
- 🐕 Dog barking
- 👏 Speech and clapping

Repeated information remains stable until the detected scene meaningfully changes. The app avoids stealing keyboard focus or interrupting normal work.

### Intelligent scene understanding

Instead of treating every sound as an isolated label, Hark is designed to combine simultaneous detections into a grounded observation—for example, “A cat is meowing while someone is talking.” Language generation runs only when useful changes occur, reducing unnecessary processing.

### Ask Hark

Hark can answer natural-language questions about locally stored event history, including:

- “What happened while I was away?”
- “Did someone knock in the last ten minutes?”
- “What sounds have been happening recently?”

Answers are grounded in available detection history rather than imagined events or continuous audio recordings.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

---

## Features

- **Menu-bar awareness** — Live, glanceable descriptions of the current sound scene.
- **Multi-label sound detection** — Recognizes overlapping environmental events with confidence scores.
- **Visual-first alerts** — Select notifications for doorbells, knocking, alarms, crying, barking, glass breaking, and other useful sounds.
- **Adjustable sensitivity** — Configure microphone input, input gain, and listening threshold.
- **Sound timeline** — Review timestamps, durations, labels, and captions without saving raw microphone audio by default.
- **Local questions and summaries** — Ask about recent surroundings using event metadata.
- **Native macOS experience** — SwiftUI interface, adaptive appearances, system notifications, and launch-at-login support.
- **Offline-first operation** — Core sound-awareness functionality is designed to run locally.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

---

## Privacy and Accessibility

Hark is designed for Deaf and hard-of-hearing users while remaining useful to anyone who wants greater environmental awareness.

- Audio processing runs on the Mac.
- Microphone audio does not need to be uploaded.
- Raw microphone recordings are not stored by default.
- Optional history contains event metadata, timestamps, labels, and captions.
- No mandatory account or cloud subscription is required.
- Icons, motion, shape, and visual hierarchy complement text and color.
- Native notification permission is optional and requested only when needed.

Manual update checks may use the internet when explicitly requested; they are separate from core sound detection.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

---

## How It Works

Hark separates continuous audio understanding from event-driven language generation:

```text
Microphone audio
      ↓
On-device preprocessing
      ↓
SSLAM multi-label classification
      ↓
Confidence and persistence filtering
      ↓
Visual caption · Sound timeline · Selected alerts
      ↓
LFM natural-language captioning and history Q&A
```

### SSLAM — Sound understanding

SSLAM identifies multiple overlapping AudioSet events and produces confidence-scored classifications. Live inference uses a converted and parity-validated Core ML model.

### LFM2.5-350M — Language intelligence

The lightweight language model turns structured detections into natural captions and answers questions about recent event history. Generated captions are checked against detected labels before display.

### SwiftUI — Native macOS experience

SwiftUI and AppKit provide the menu-bar interface, adaptive windows, animated captions, history, settings, native notifications, and audio-device controls.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

---

## Built With

- **Swift** and **SwiftUI**
- **AppKit**
- **AVFoundation** and **Accelerate**
- **Core ML**
- **MLX Swift / MLX Swift LM**
- **Swift Transformers**
- **Swift Hugging Face**
- **SSLAM**
- **LFM2.5-350M**

<p align="right">(<a href="#readme-top">back to top</a>)</p>

---

## Getting Started

### Prerequisites

- macOS 14.0 or later
- A current version of Xcode capable of resolving the included Swift packages
- Microphone access for live sound detection
- Locally available, compatible model files for native SSLAM and LFM features

### Clone

```sh
git clone https://github.com/riniwtz/project-another-friday.git
cd project-another-friday
```

### Build

1. Open `Hark.xcodeproj` in Xcode.
2. Allow Xcode to resolve the Swift package dependencies.
3. Select the **Hark** scheme and **My Mac** destination.
4. Build and run the project.
5. Grant microphone permission when enabling live listening.
6. In **Settings → AI**, select compatible local model folders before enabling native AI features.

> [!NOTE]
> Hark is currently a functional prototype. Native model exports must match the contracts validated by the app; selecting an arbitrary model folder is not sufficient.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

---

## Project Structure

```text
project-another-friday/
├── Hark.xcodeproj/
├── Hark/
│   ├── AppController.swift
│   ├── AudioDevices.swift
│   ├── HarkStore.swift
│   ├── NativeAudioPipeline.swift
│   ├── NotificationManager.swift
│   ├── StartupManager.swift
│   ├── ModelManager.swift
│   ├── Views.swift
│   ├── Info.plist
│   └── logo.png
└── README.md
```

<p align="right">(<a href="#readme-top">back to top</a>)</p>

---

## Status and Goals

**Current status:** Working title · Functional UI prototype · AI integration in development

| Goal | Target |
|---|---|
| Speed | Relevant alerts within two seconds of event onset |
| Simplicity | First useful alert within 30 seconds of launch |
| Accessibility | Important alerts understandable through icons and motion |
| Privacy | No cloud dependency, account, or microphone-audio upload |
| Performance | Practical resource use on modest and older Mac hardware |
| Continuity | Useful offline and unobtrusive in the background |

These are product and performance targets to validate through real-world testing, not claims of already achieved results.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

---

## Version 1 Boundaries

Version 1 focuses on everyday environmental sound awareness. Speech transcription, cloud synchronization, user accounts, and replacement of certified alarm systems are outside the initial scope.

The goal is to make a focused set of capabilities reliable, understandable, private, and delightful to use.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

---

## Contributing

Issues and focused pull requests are welcome. When reporting detection behavior, include the macOS version, Mac model, selected compute mode, model conversion details, and relevant confidence settings—but do not attach private microphone recordings unless you have intentionally prepared them for public sharing.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

---

<div align="center">
  <strong>Hark. Sound, made visible.</strong>
</div>
