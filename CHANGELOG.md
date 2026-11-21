# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

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
