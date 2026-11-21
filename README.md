English | [日本語](./README.ja.md)

# swift-app-sessions

See what people do inside your app, one session at a time: which screens they went through and how,
where they tapped, where they tapped again and again or went straight back, how far they scrolled,
when the app stopped answering, and how each session ended. The records stay on the device or go
wherever you send them.

![Swift](https://img.shields.io/badge/Swift-6.2-orange.svg)
![Platforms](https://img.shields.io/badge/Platforms-iOS%2017%20%7C%20macOS%2014-blue.svg)
![License](https://img.shields.io/badge/License-MIT-yellow.svg)

> Developed in a private monorepo and copied here one way. Issues are welcome; pull requests are
> not accepted.

## Features

- **Sessions split the usual way.** A launch starts one; so does coming back after 30 minutes in
  the background. Each has an id (`ses_` and 20 letters)
- **Screens from your analytics.** `screen_viewed` moves to its screen. Going back to the screen
  under the current one is a `pop`, with `back` and, within 2 seconds of entering, `quick_back`
- **Taps without touching your touches.** A recognizer on every window that never recognizes
  anything. Positions are 0–10000 of the window (iPad split windows included). `.sessionTarget("…")`
  names an element
- **Rage taps.** Three or more taps within 1 second and 30 pt of the first
- **Scroll depth.** The main scroll view's deepest point per screen, and named lists with
  `.sessionScroll("…")` and `.sessionRow(_:in:)`
- **How it ended.** `background_timeout`, `crashed` (MetricKit, also when the report comes late),
  `hung` (a watchdog thread; a session killed in a hang still ends as hung), `killed` or `unknown`,
  decided at the next launch
- **Your app's events, kept carefully.** The shared catalog's values are kept; your own events keep
  only the properties you list. Text longer than 48 characters is dropped
- **Survives restarts and no network.** What is not sent yet is kept and sent later with the same
  batch number, so the receiver can drop duplicates
- **No dependencies.** Foundation, Observation, UIKit, MetricKit; SwiftUI only in `SessionsSwiftUI`

The light record keeps no pixels. `.sessionMask()` and `.sessionNoCapture()` place their marks now
for the recording, which is not part of this version.

## Quick Start

```swift
import SessionsCapture
import SessionsCore
import SessionsSwiftUI

let sessions = AppSessions(
    sink: FileSessionSink(),                              // keep on the device
    channel: "appstore",
    configuration: .init(keepProps: ["memo_created": ["view"]])
)
let capture = SessionCapture(sessions: sessions)
capture.start()                                           // once, at launch: starts the session

// Hand your analytics events over (screen_viewed moves the screen)
analytics.onEvent { name, props in sessions.observe(name, props) }

// Mark what you know without an event
sessions.mark(.ticket, ref: ticketID)

// In SwiftUI
SaveButton().sessionTarget("save_button")
NoteBody(note).sessionMask()
CameraView().sessionNoCapture()
```

## Where the records go

`AppSessions` hands each batch to a `SessionSink`:

| Sink | What it does |
|---|---|
| `FileSessionSink` | One JSON line per batch in a file per session, oldest removed past 20 MB. `files()` for a tester screen to share |
| `DebugSessionSink` | The last batches in memory (`batches`) and printed |
| your own | `func send(_ batch: SessionBatch) async throws -> SessionSinkReply`. Throw to keep the batch for later; answer `.disabled` to stop the session |

The batch is the JSON of `SessionBatch` (`schema/sessions/batch.schema.json` in the monorepo).

## Testing

`SessionsTesting` has a clock that moves only when told, an in-memory state store, ids in order and
a recording sink. The rules are plain functions (`SessionRules`) and pass the shared tables in
`Tests/SessionsCoreTests/Cases/sessions`.

## Requirements

- iOS 17+ / macOS 14+ (`.sessionScroll` measures depth from iOS 18)
- Swift 6.2+

## License

MIT
