# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- `AppSessions.now` (`SessionNow`): the current session's id and screen, readable from any thread. For
  tagging an event the app records elsewhere (an analytics event tracked off the main actor) with the
  session it happened in.
- `AppSessions.closePrevious(exit:)`: ends the previous session and starts none; the next `enterForeground()`
  starts the session. Same as kotlin-app-sessions.
- `AppSessions.noteDismissByApp()`: the app closes the current screen itself (a sheet that closes once a long
  press is done); the move back within 1 second is a `back` but not a `quick_back`.
- Dead taps (`dead`): while the screen is recorded, a tap after which, for 1.5 seconds, no screen opened, no app
  event came and the frame's fingerprint stayed the same (`SessionRules.isDead`). The Kotlin SDK made them
  already; `SessionRules.isDead` was never called here.
- `foreground_ms` on `background` (`SessionEvent.background(t:foregroundMs:)`) and `end`
  (`SessionEvent.end(t:reason:foregroundMs:)`): the time the session spent in the front.
  `OpenSessionRecord.foregroundMs` and `foregroundSince`, `ClosedSessionRecord.foregroundMs`.

### Changed

- `SessionCapture.start()` no longer starts a session at launch: it ends the previous one (`closePrevious`), and
  the session starts when the app is in the front (`willEnterForeground`, `didBecomeActive`, or already active).
  A launch in the background (a `BGTaskScheduler` task, a background fetch, a prewarm) records nothing, and the
  person opening the app later starts a session of its own. Before, such a launch started a session with no tap
  that the later visit joined, so the visit was neither split off nor counted.
- A session that stayed in the background for 30 minutes ends as soon as anything is recorded in the background
  after that (an analytics event of a background task), at the time it went to the background. Before, the event
  joined the session and stretched it.
- A screen named while no session is open is the first screen of the next session (`launch`).
- With a sheet, a full screen cover, a popover or an alert presented, a tap takes the name of a
  `.sessionTarget` on it only. Before, a target of the screen under the sheet could name the tap.
- `AppSessions.isCapturing` is read-only: true while the recording's last frame of the session had a picture.
- `start.first` is documented as the first session this SDK records on the install, not the app's first launch.

## [0.4.0] - 2026-11-24

### Added

- `replay_stats` (`SessionEvent.replayStats`, `SessionReplayStats`): before each batch, the frames taken, the
  frames left without a picture and why, the main thread's time a frame took (p50, p95) and why the recording
  stopped. The Kotlin SDK sent it already; without it a stopped recording left no trace on the server.

- `SessionMaskNode` and `SessionRules.partsToHide(root:bounds:limit:)`: the search for the parts of a frame
  to hide, apart from UIKit. A `.sessionMask()` or a password field is painted whole; a part whose place
  cannot be told, or a hierarchy of more than 10,000 views, drops the frame (`masking_failed`).
- `SessionRules.maskRects(scale:imageW:imageH:budgetMs:nowMs:find:)`: the search fails closed. When it
  throws or takes over 16ms (`SessionRules.maskBudgetMs`), the frame is blank (`masking_failed`).

### Changed

- A slow device keeps recording. Over 33ms (p95) a frame is taken every 5 seconds (`SessionReplayFrameCost.Verdict.verySlow`);
  only over 100ms does the session's recording stop (`degraded`). Stopping at 33ms left every App Store
  session of the first app with its first 13 frames only.

- A text field or text view whose `textContentType` is `.password` or `.newPassword` is hidden like a
  secure-entry field, so a password stays hidden while a "show password" button turns secure entry off.
- A part to hide is painted where its view is and where it is drawn (its presentation layer), so a field that
  moves under an animation stays covered.

### Removed

- `SessionMarkerView.maskFrames(in:)`. It found only `.sessionMask()` and missed password fields; the
  recording uses `SessionRules.partsToHide(root:bounds:limit:)`.

## [0.3.1] - 2026-11-23

### Fixed

- The recording stopped for the rest of the session about 15 seconds after launch on the simulator: the frames'
  main-thread time went over 33ms (p95) while the app was still laying out its first screens, and `degraded`
  is kept for the session. The first 3 frames are no longer counted, and on the simulator (which draws on the
  CPU) a slow frame only spaces frames out. On a device, 33ms still stops the session's recording.
- Over 16ms (p95) a frame is taken every 2 seconds instead of every second (sessions.md 3.2), with
  `SessionReplayFrameCost` holding the rule (`SessionReplayCapture.Configuration.cost`).
- The capture no longer walks the views ten times a second while no frames are wanted, and a touch left
  counted when the app went to the back no longer holds frames back after it comes to the front.

## [0.3.0] - 2026-11-23

### Added

- The recording of the screen. `SessionReplayRecorder` puts frames into segments (`.agsr`, `SessionReplaySegment`),
  keeps them on the device (50 MB, 7 days; a session stops at 30 minutes or 20 MB) and sends them with a
  `SessionReplaySink` by the sink's answer: `record` sends everything, `buffer` keeps the last 60 seconds and
  sends them when a priority condition is met (`AppSessions.priorityHit`) or the previous session crashed, hung
  or was killed. Metered networks carry priority sessions only, up to 3 MB a day.
- `SessionCapture.startReplay(_:live:configuration:)` and `SessionReplayCapture`: at most one frame a second
  (sooner after a new screen, a tap or a scroll that stops), the key window drawn at 1pt to 1px, painted black
  where the app marks it with `.sessionMask()` and over secure-entry (password) fields, which are always hidden
  (`SessionMaskMode.marked`, the only mode; ordinary text fields, labels, images and web views are recorded as
  shown), and
  written as JPEG off the main thread. A frame whose parts to hide cannot be placed is blank (`masking_failed`).
  No frames while a finger is down or a scroll view moves, in Low Power Mode, when hot, under 20% of battery,
  or when taking one is slow (p95 over 33 ms).
- `SessionLiveStream` and `SessionLiveConnecting`: the device side of the live view (hello, events at once,
  frames at up to 2 a second, `stop` and `rate`; batches every 5 seconds while connected).
- `SessionRules.maskRects(scale:imageW:imageH:rects:)`, passing the shared `mask_rects` and `segment` tables.
- A tap on a view with an `accessibilityIdentifier` and no `.sessionTarget` takes the identifier as its target.

### Changed

- `SessionSinkReply.accepted` carries `uploadToken` and `live`. `AppSessions` hands them to the recording
  (`onUploadToken`, `onLiveOffer`) and reports `onEvent`, `onSessionStart` and `onPriority`.
- `AppSessions.isCapturing` is true once the recording takes frames.
- A tap target outside `^[a-z][a-z0-9_]{0,47}$` is left out instead of making the server refuse the batch.

## [0.2.0] - 2026-11-23

### Changed

- `.sessionNoCapture()` places a mark in the screen's views instead of counting `onAppear` and
  `onDisappear`. A screen pushed on a marked screen in a NavigationStack, or a sheet presented from
  it, stays blank until the marked screen is popped (the mark used to end when the pushed screen
  appeared). `AppSessions.beginNoCapture()`, `endNoCapture()` and `isCaptureSuppressed` are removed.

### Added

- `SessionCapture.blankReason(noCaptureScreens:)`: why a frame taken now would be blank, from the
  marks on the screens shown and kept under the shown one, an alert or an action sheet that is up
  (its text field cannot carry `.sessionMask()`), the app not being active, and the manifest's
  `no_capture_screens`.
- `SessionRules.captureScene(roots:appActive:screen:)` and `SessionRules.blankReason(_:noCaptureScreens:)`
  with `SessionScreenNode`, `SessionBlankReason` and `SessionMarkerView.Kind.noCapture`.

## [0.1.1] - 2026-11-22

### Fixed

- NaN and infinite property values are dropped. Kept, they stopped every later save of the state and
  every send of a batch.

## [0.1.0] - 2026-11-21

### Added

- `SessionsSDK.name` and `SessionsSDK.version`. The version is sent as `sdk_version`, and a connector
  reports both when it sends batches.
- The light record: `AppSessions` splits sessions (launch, 30 minutes in the background), records
  screens with `via`, `back` and `quick_back`, taps (0–10000 of the window, `.sessionTarget`), rage
  taps, scroll depth, the keyboard, app events with kept props, marks, hangs and the end reason
  decided at the next launch (MetricKit's late crash reports send `end` again).
- `SessionRules`: the rules as pure functions, passing the shared tables `cases/sessions` (split,
  rage, dead, quick back, end, scroll, tap position, sampling, kept props).
- `SessionSink` with `FileSessionSink` and `DebugSessionSink`. Batches not taken are kept with
  their `seq` and sent again.
- `SessionsCapture`: taps on every window, the app's lifecycle, the keyboard, the main scroll view,
  `HangMonitor` and MetricKit.
- `SessionsSwiftUI`: `.sessionTarget`, `.sessionScroll`, `.sessionRow`, `.sessionMask`, `.sessionNoCapture`.
- `SessionsTesting`: a clock, a state store, ids and a recording sink.
