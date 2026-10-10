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
    <li><a href="#why-local-ai">Why Local AI?</a></li>
    <li><a href="#built-with">Built With</a></li>
    <li><a href="#hackathon-technical-disclosure">Hackathon Technical Disclosure</a></li>
    <li><a href="#hackathon-submission-checklist">Hackathon Submission Checklist</a></li>
    <li><a href="#getting-started">Getting Started</a></li>
    <li><a href="#project-structure">Project Structure</a></li>
    <li><a href="#status-and-goals">Status and Goals</a></li>
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

### LFM2.5-1.2B-Instruct-4bit — Language intelligence

The lightweight language model turns structured detections into natural captions and answers questions about recent event history. Generated captions are checked against detected labels before display.

### SwiftUI — Native macOS experience

SwiftUI and AppKit provide the menu-bar interface, adaptive windows, animated captions, history, settings, native notifications, and audio-device controls.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

---

## Why Local AI?

> **Why does this product benefit from running AI locally?**

Hark processes a continuous stream of highly sensitive ambient audio. Running its core AI directly on the user's Mac keeps that audio private, removes round-trip cloud latency from time-sensitive sound alerts, avoids recurring inference costs, and allows sound awareness to continue when the internet or a remote AI provider is unavailable.

Local execution is fundamental rather than decorative: microphone preprocessing, SSLAM sound classification, confidence filtering, caption generation, and questions about recent event history are designed to run on the device. A cloud-only implementation would require continuously transmitting information about a user's home, conversations, and surroundings while also becoming less dependable during connectivity failures—the moments when awareness may matter most.

### What works without the cloud

- Live microphone capture and audio preprocessing
- SSLAM environmental sound classification
- Confidence and persistence filtering
- Menu-bar captions and the sound timeline
- Selected sound alerts and native macOS notifications
- LFM caption generation and questions about local event history
- Local preferences and event-metadata storage

### What may use the internet

- Initial source-code and Swift package downloads
- Obtaining model weights before first use
- An explicitly requested update check when that feature is connected
- GitHub, issue reporting, and hackathon submission links

No cloud AI API is required for Hark's core runtime inference path.

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
- **LFM2.5-1.2B-Instruct-4bit**

<p align="right">(<a href="#readme-top">back to top</a>)</p>

---

## Hackathon Technical Disclosure

This section consolidates the technical disclosures required by the AppBuildersPH Hackathon 2026 Local AI challenge.

### Models

| Model | Role | Execution |
|---|---|---|
| SSLAM AudioSet-2M fine-tuned checkpoint | Multi-label environmental sound classification | Converted to Core ML and executed on-device |
| LFM2.5-1.2B-Instruct-4bit | Grounded captions and questions about event history | Executed on-device through MLX Swift LM |

Model weights are not committed to this repository. Download the required models from the [shared Google Drive folder](https://drive.google.com/drive/folders/1g0fOM875caRSJTQowbfNsV8dt3ObfLKa?usp=sharing), then select their local folders in Hark's settings. The SSLAM model was converted to Core ML using a Python script, and the export must pass the app's conversion and feature-parity checks.

### Team

**Team name:** Another Friday

**Eligible members:**

- Rintaro Iwata
- Thaeron Conducto
- Qinpei Lu

### Frameworks and major tools

- Swift, SwiftUI, and AppKit
- AVFoundation, Accelerate, Core Audio, and AudioToolbox
- Core ML
- MLX Swift and MLX Swift LM
- Swift Transformers
- Swift Hugging Face
- Xcode and Swift Package Manager

### APIs and cloud services

Hark uses Apple platform APIs for microphone capture, Core ML inference, window management, notifications, and launch-at-login behavior. It does **not** use a remote AI inference API for core functionality. Network access is limited to development/setup downloads and optional external actions such as future manual update checks.

### Existing code and assets

- Open-source model implementations and Swift packages are used under their respective licenses and are resolved through Swift Package Manager.
- The Hark logo in `Hark/logo.png` is a team-provided asset.
- Repository history remains public so judges can inspect the development timeline and distinguish new work from reused foundations.
- Any additional code or asset created before the official build window must be itemized here by the team before final submission.

### AI-assisted development

OpenAI Codex was used as an AI coding assistant for implementation, debugging, documentation, build validation, and Git operations. AI-assisted development is separate from Hark's runtime AI models and is disclosed in accordance with the hackathon rules.

### Reproducibility

The repository contains the complete macOS application source and pinned Swift package resolution. Judges can recreate the application using the steps in [Getting Started](#getting-started). Model weights are external because of their size and licensing; compatible local model files are required to demonstrate native inference.

> [!CAUTION]
> Do not report estimated model speed, detection accuracy, or alert latency as measured results. The targets below remain unverified until recorded with a disclosed Mac model, compute mode, model export, settings, sample set, and methodology.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

---

## Hackathon Submission Checklist

The public repository and technical documentation are prepared for the AppBuildersPH Hackathon 2026 submission. The team must complete the identity and video fields below before submitting once through [Cerebral Valley](https://cerebralvalley.ai/e/appbuildersph-hackathon-2026).

| Required item | Status |
|---|---|
| Project name | Hark |
| Short description | A private, on-device sound-awareness companion that makes environmental sounds visible on macOS. |
| Team name and eligible members | Another Friday — Rintaro Iwata, Thaeron Conducto, Qinpei Lu |
| Public GitHub repository | [riniwtz/project-another-friday](https://github.com/riniwtz/project-another-friday) |
| Working, reproducible product | Source and build instructions included; compatible local model files are required. |
| Explanation of local execution | [Why Local AI?](#why-local-ai) |
| Explanation of internet requirements | [What may use the internet](#what-may-use-the-internet) |
| Models, frameworks, APIs, code/assets, and AI tools | [Hackathon Technical Disclosure](#hackathon-technical-disclosure) |
| Demo video | [Watch the Hark demo](https://drive.google.com/file/d/1c0sWpcUC-Ub8kNhFJTGy_ODfdp_LuuOB/view?usp=sharing) |
| X or LinkedIn video post | **Add the public post URL; tag Devin/Cognition and include `#AppBuildersPH`.** |

> [!IMPORTANT]
> Submit only once, make the repository public, and stop committing by **October 10, 2026 at 10:00 AM Philippine Standard Time (UTC+8)**. The organizers state that there are no extensions or resubmissions.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

---

## Getting Started

### Prerequisites

- macOS 14.0 or later
- A current version of Xcode capable of resolving the included Swift packages
- Microphone access for live sound detection
- Compatible SSLAM and LFM model files from the [Hark models folder](https://drive.google.com/drive/folders/1g0fOM875caRSJTQowbfNsV8dt3ObfLKa?usp=sharing)

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
5. Download the required SSLAM and LFM files from the [Hark models folder](https://drive.google.com/drive/folders/1g0fOM875caRSJTQowbfNsV8dt3ObfLKa?usp=sharing).
6. In **Settings → AI**, select the downloaded local model folders before enabling native AI features.
7. Grant microphone permission when enabling live listening.

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

## Contributing

Issues and focused pull requests are welcome. When reporting detection behavior, include the macOS version, Mac model, selected compute mode, model conversion details, and relevant confidence settings—but do not attach private microphone recordings unless you have intentionally prepared them for public sharing.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

---

<div align="center">
  <strong>Hark. Sound, made visible.</strong>
</div>
