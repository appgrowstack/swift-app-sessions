# swift-app-sessions

Records what people do inside an iOS app, one session at a time: screens, taps, rage taps, quick backs, scroll depth, hangs and how each session ended.

English | [Japanese](README.ja.md)

## Features

- **Sessions split the usual way.** A launch starts one, and so does coming back after 30 minutes in the background. Each has an id (`ses_` and 20 letters)
- **Screens from your analytics events.** `screen_viewed` moves to its screen. Going back to the screen under the current one is a `pop`, recorded with `back` and, within 2 seconds of entering, `quick_back`
- **Taps without touching your touches.** A recognizer on every window that never recognizes anything. Positions are 0–10000 of the window (iPad split windows included). `.sessionTarget("…")` names an element
- **Rage taps.** Three or more taps within 1 second and 30 pt of the first
- **Scroll depth.** The main scroll view's deepest point per screen, and named lists with `.sessionScroll("…")` and `.sessionRow(_:in:)`
- **How it ended.** `background_timeout`, `crashed` (MetricKit, also when the report comes late), `hung` (a watchdog thread), `killed` or `unknown`, decided at the next launch
- **Your app's events, kept carefully.** Events of the shared catalog keep their values; your own events keep only the properties you list in `keepProps`. Text longer than 48 characters is dropped
- **Survives restarts and no network.** What is not sent yet is kept and sent later with the same batch number, so the receiver can drop duplicates
- **Marks.** Some events (`paywall_shown`, `purchase_completed`, `campaign_shown` and others) also make a mark, and `mark(_:ref:side:)` adds one without an event
- **No dependencies.** Foundation, Observation, UIKit and MetricKit; SwiftUI only in `SessionsSwiftUI`

The light record keeps no pixels; the recording (below) does. `.sessionMask()` and `.sessionNoCapture()` place marks it reads. A screen marked `.sessionNoCapture()` keeps the recording blank while it is shown and while it lies under the shown screen (a screen pushed on it, a sheet presented from it); alerts and action sheets keep it blank while they are up. `SessionCapture.blankReason(noCaptureScreens:)` gives the reason a frame taken now would be blank.

### Where the records go

`AppSessions` hands each batch to a `SessionSink`:

| Sink | What it does |
|---|---|
| `FileSessionSink` | One JSON line per batch in a file per session, oldest removed past 20 MB. `files()` for a tester screen to share |
| `DebugSessionSink` | The last batches in memory (`batches`), each also printed |
| your own | `func send(_ batch: SessionBatch) async throws -> SessionSinkReply`. Throw to keep the batch for later; answer `.disabled` to stop the session |

### Testing

`SessionsTesting` has a clock that moves only when told (`FakeSessionClock`), an in-memory state store (`InMemorySessionStateStore`), ids in order (`SequenceSessionIDs`) and a recording sink (`RecordingSessionSink`). The rules are plain functions in `SessionRules`.

## Quick Start

```swift
import SessionsCapture
import SessionsCore
import SessionsSwiftUI
import SwiftUI

@main
struct MyApp: App {
    let sessions: AppSessions
    let capture: SessionCapture

    init() {
        sessions = AppSessions(sink: FileSessionSink(), channel: "appstore")  // keep the records on the device
        capture = SessionCapture(sessions: sessions)
        capture.start()  // once, at launch: starts the session
    }

    var body: some Scene {
        WindowGroup {
            Button("Save") {}
                .sessionTarget("save_button")
                .onAppear { sessions.observe("screen_viewed", ["screen": .string("home")]) }
        }
    }
}
```

### Connecting to a server

The package works on its own. To connect it to a server, enable the matching trait of the connector package [swift-appgrowstack](https://github.com/appgrowstack/swift-appgrowstack) (SwiftPM traits) instead of wiring a server here.

### Recording the screen

`SessionReplayRecorder` and `SessionCapture.startReplay(_:live:configuration:)` record the screen as frames: at most one a second (sooner after a new screen, a tap or a scroll that stops), drawn at 1pt to 1px and written as JPEG. Frames that look the same as the one before carry no image. Text fields, `.sessionMask()` and web views are always painted black before a frame leaves the main thread; with `mask: .textAndImages` (the default) every label, image and SwiftUI text and image layer is too. A frame whose parts to hide cannot be placed is dropped. Nothing is taken while a finger is down or a list is moving, in Low Power Mode, when the device is hot or under 20% of battery.

Frames go into segments (`.agsr`), kept on the device (50 MB, 7 days) and sent with a `SessionReplaySink` when the session's batch answer allows it: `record` sends everything, `buffer` keeps the last 60 seconds and sends them only when something went wrong in the session (a rage tap, a hang, a paywall closed without buying…). Segments go over Wi-Fi or another unmetered network; priority sessions also over a metered one, up to 3 MB a day. `SessionLiveStream` sends the same frames and the events at once while someone watches.

```swift
let sessions = AppSessions(sink: sessionSink, channel: "appstore")
let recorder = SessionReplayRecorder(sessions: sessions, sink: replaySink)
let live = SessionLiveStream(sessions: sessions, connector: liveConnector)  // optional
let capture = SessionCapture(sessions: sessions)
capture.start()
capture.startReplay(recorder, live: live, configuration: .init(mask: .textAndImages, noCaptureScreens: ["photo_picker"]))
```

## Installation

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/appgrowstack/swift-app-sessions.git", .upToNextMinor(from: "0.2.0"))
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "SessionsCore", package: "swift-app-sessions"),
            .product(name: "SessionsCapture", package: "swift-app-sessions"),
            .product(name: "SessionsSwiftUI", package: "swift-app-sessions")
        ]
    )
]
```

### Products

| Product | What it has |
|---|---|
| `SessionsCore` | Splitting sessions, the rules, the recorder `AppSessions`, batches, `SessionSink`, `FileSessionSink` and `DebugSessionSink`, the recording's `SessionReplayRecorder` and segments, and `SessionLiveStream`. Foundation and Observation only |
| `SessionsCapture` | UIKit: taps, the app's lifecycle, the keyboard, scroll views, hangs, MetricKit crashes, the device's values and the recording's frames (`startReplay`). Compiles to nothing outside UIKit |
| `SessionsSwiftUI` | `.sessionTarget`, `.sessionScroll`, `.sessionRow`, `.sessionMask` and `.sessionNoCapture` |
| `SessionsTesting` | Test doubles: a clock, a state store, ids and a recording sink |

## Requirements

- iOS 17+ / macOS 14+ (`.sessionScroll` measures depth from iOS 18)
- Swift 6.2+

## License

MIT. See [LICENSE](LICENSE).
