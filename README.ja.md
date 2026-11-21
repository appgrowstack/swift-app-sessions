[English](./README.md) | 日本語

# swift-app-sessions

アプリの中で人が何をしたかを、セッションごとに見る。どの画面をどう通ったか・どこをタップしたか・
何度もタップした所やすぐ戻った所・どこまでスクロールしたか・アプリが止まった時間・セッションの終わり方。
記録は端末に溜めるか、アプリが決めた送り先へ渡す。

![Swift](https://img.shields.io/badge/Swift-6.2-orange.svg)
![Platforms](https://img.shields.io/badge/Platforms-iOS%2017%20%7C%20macOS%2014-blue.svg)
![License](https://img.shields.io/badge/License-MIT-yellow.svg)

> 非公開のモノリポで開発し、ここへは片方向にコピーしている。Issue は歓迎、プルリクエストは受け付けない。

## できること

- **セッションの区切り。** 起動と、裏に30分いた後に前へ戻った時に始まる。id は `ses_` ＋20文字
- **画面は計測から。** `screen_viewed` の画面へ動く。今の画面の下の画面へ戻るのは `pop` で、`back` と、入って2秒以内なら `quick_back` も出す
- **タッチを止めないタップの記録。** 各窓に何も認識しない認識を足す。位置は窓の幅と高さに対する 0〜10000（iPad の分割の窓も）。`.sessionTarget("…")` で要素に名前を付ける
- **rage tap。** 最初のタップから1秒以内・30pt 以内に3回以上
- **スクロールの深さ。** 画面ごとの主なスクロールの一番深い所。`.sessionScroll("…")`・`.sessionRow(_:in:)` で名前の付いた一覧も
- **終わり方。** `background_timeout`・`crashed`（MetricKit。遅れて届いても直す）・`hung`（監視のスレッド。止まったまま落ちても hung）・`killed`・`unknown` を次の起動で決める
- **アプリの出来事は残す物を絞る。** 共通のカタログの値は残し、アプリの出来事は書いた props だけ。48文字を超える文字は捨てる
- **落ちても・つながらなくても。** 送れていない物は溜めて、同じバッチの番号で後から送る（受ける側が重なりを捨てられる）
- **依存なし。** Foundation・Observation・UIKit・MetricKit。SwiftUI は `SessionsSwiftUI` だけ

軽い記録は画素を持たない。`.sessionMask()`・`.sessionNoCapture()` は録画のために今からマークを置く（録画はこのバージョンに入っていない）。

## 使い方

```swift
import SessionsCapture
import SessionsCore
import SessionsSwiftUI

let sessions = AppSessions(
    sink: FileSessionSink(),                              // 端末に溜める
    channel: "appstore",
    configuration: .init(keepProps: ["memo_created": ["view"]])
)
let capture = SessionCapture(sessions: sessions)
capture.start()                                           // 起動の最初に1回。セッションも始まる

// 計測の出来事を渡す（screen_viewed で画面が動く）
analytics.onEvent { name, props in sessions.observe(name, props) }

// 出来事の無いマーク
sessions.mark(.ticket, ref: ticketID)

// SwiftUI
SaveButton().sessionTarget("save_button")
NoteBody(note).sessionMask()
CameraView().sessionNoCapture()
```

## 送り先

`AppSessions` はバッチを `SessionSink` に渡す。

| 送り先 | すること |
|---|---|
| `FileSessionSink` | セッションごとのファイルにバッチを1行の JSON で足す。20MB を超えたら古い物から消す。テスター画面は `files()` を共有できる |
| `DebugSessionSink` | 直近のバッチをメモリに持ち（`batches`）、文字で出す |
| 自前の物 | `func send(_ batch: SessionBatch) async throws -> SessionSinkReply`。投げると後で送り直す。`.disabled` を返すとそのセッションを止める |

バッチは `SessionBatch` の JSON（モノリポの `schema/sessions/batch.schema.json`）。

## テスト

`SessionsTesting` に、言われた時だけ進む時計・メモリの保存・順番の id・受けた物を残す送り先がある。
判定はただの関数（`SessionRules`）で、`Tests/SessionsCoreTests/Cases/sessions` の共通の表を通す。

## 動く環境

- iOS 17 以上・macOS 14 以上（`.sessionScroll` の深さは iOS 18 から）
- Swift 6.2 以上

## ライセンス

MIT
