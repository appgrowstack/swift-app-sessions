# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
