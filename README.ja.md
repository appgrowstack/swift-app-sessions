# swift-app-sessions

iOSアプリの中で人が何をしたかを、セッションごとに記録する。画面・タップ・rage tap・すぐ戻った操作・スクロールの深さ・止まった時間・セッションの終わり方を残す。

[English](README.md) | 日本語

## 機能

- **セッションの区切り。** 起動で1つ始まり、バックグラウンドに30分いた後に戻ったときにも始まる。idは`ses_`と20文字
- **画面は計測の出来事から。** `screen_viewed`でその画面へ動く。今の画面の下の画面へ戻るのは`pop`で、`back`と、入ってから2秒以内なら`quick_back`も記録する
- **タッチを止めないタップの記録。** 各ウィンドウに、何も認識しないジェスチャーの認識を足す。位置はウィンドウに対する0〜10000（iPadの分割のウィンドウも）。`.sessionTarget("…")`で要素に名前を付ける
- **rage tap。** 最初のタップから1秒以内・30pt以内に3回以上
- **スクロールの深さ。** 画面ごとに、主なスクロールビューの一番深い所を残す。`.sessionScroll("…")`と`.sessionRow(_:in:)`で名前を付けた一覧も
- **終わり方。** `background_timeout`・`crashed`（MetricKit。レポートが遅れて届いても直す）・`hung`（監視のスレッド）・`killed`・`unknown`を次の起動で決める
- **アプリの出来事は残す物を絞る。** 共通のカタログの出来事は値を残す。アプリ独自の出来事は`keepProps`に書いたプロパティだけを残す。48文字を超える文字列は捨てる
- **再起動やオフラインでも消えない。** 送れていない物は保存し、同じバッチの番号で後から送る。受ける側は重なりを捨てられる
- **マーク。** 一部の出来事（`paywall_shown`・`purchase_completed`・`campaign_shown`など）はマークも作る。`mark(_:ref:side:)`で出来事なしにマークを足せる
- **依存なし。** Foundation・Observation・UIKit・MetricKitだけ。SwiftUIを使うのは`SessionsSwiftUI`だけ

軽い記録は画素を持たない。録画（下）は持つ。`.sessionMask()`と`.sessionNoCapture()`は録画が読むマークを置く。`.sessionNoCapture()`を付けた画面は、見えている間と、その上に別の画面が重なっている間（pushした先・その画面から出したシート）、録画を撮らない。アラートとアクションシートも出ている間は撮らない。今撮ると撮らない理由は`SessionCapture.blankReason(noCaptureScreens:)`で分かる。

### 記録の送り先

`AppSessions`はバッチを1つずつ`SessionSink`に渡す。

| 送り先 | すること |
|---|---|
| `FileSessionSink` | セッションごとのファイルに、バッチを1行のJSONで足す。20MBを超えたら古い物から消す。テスター向けの画面は`files()`を共有できる |
| `DebugSessionSink` | 直近のバッチをメモリに持ち（`batches`）、1つずつ出力もする |
| 自前の物 | `func send(_ batch: SessionBatch) async throws -> SessionSinkReply`。投げるとバッチを残して後で送り直す。`.disabled`を返すとそのセッションを止める |

### テスト

`SessionsTesting`に、言われたときだけ進む時計（`FakeSessionClock`）・メモリに持つ保存先（`InMemorySessionStateStore`）・順番のid（`SequenceSessionIDs`）・受けた物を残す送り先（`RecordingSessionSink`）がある。判定は`SessionRules`のただの関数。

## はじめに

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

### サーバーにつなぐ

このパッケージは単体で使えます。サーバーにつなぐときは、このパッケージで送り先を書く代わりに、コネクターのパッケージ [swift-appgrowstack](https://github.com/appgrowstack/swift-appgrowstack) の対応するtrait（SwiftPMのtraits）を有効にします。

### 画面の録画

`SessionReplayRecorder`と`SessionCapture.startReplay(_:live:configuration:)`は、画面をコマで録る。1秒に1枚まで（新しい画面・タップ・止まったスクロールの後は早めに）、1ptを1pxで描き、JPEGにする。前のコマと同じに見えるコマは画像を持たない。コマがメインスレッドを出る前に黒で塗るのは、アプリが`.sessionMask()`でマークした所と、パスワードの入力欄（いつも・外せない）だけ。ふつうの入力欄・ラベル・画像・Webの画面は見えたまま録る（`mask: .marked`、これだけ）。人に見せたくない文が入る所にマークを付ける。隠す所の位置が取れないコマは捨てる。指が触れている間・一覧が動いている間・Low Power Mode・端末が熱い時・電池が20%未満の時は撮らない。1枚撮るのにメインスレッドを16ミリ秒（p95）より長く止めると2秒に1枚にし、33ミリ秒を超えるとそのセッションの録画を止める（`degraded`・シミュレーターでは止めない）。

コマは塊（`.agsr`）にして端末に溜め（50MB・7日）、セッションのバッチの答えが許す時に`SessionReplaySink`で送る。`record`は全部を送る。`buffer`は直近60秒だけを残し、そのセッションで何かがうまくいかなかった時（rage tap・固まった・買わずに閉じたペイウォールなど）だけ送る。塊はWi-Fiなど従量でない回線で送る。優先のセッションは従量の回線でも1日3MBまで送る。`SessionLiveStream`は、見ている人がいる間、同じコマと出来事をすぐ送る。

```swift
let sessions = AppSessions(sink: sessionSink, channel: "appstore")
let recorder = SessionReplayRecorder(sessions: sessions, sink: replaySink)
let live = SessionLiveStream(sessions: sessions, connector: liveConnector)  // optional
let capture = SessionCapture(sessions: sessions)
capture.start()
capture.startReplay(recorder, live: live, configuration: .init(mask: .marked, noCaptureScreens: ["photo_picker"]))
```

## 入れ方

`Package.swift`に足す。

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

### プロダクト

| プロダクト | 中身 |
|---|---|
| `SessionsCore` | セッションの区切り・判定・記録する`AppSessions`・バッチ・`SessionSink`・`FileSessionSink`・`DebugSessionSink`・録画の`SessionReplayRecorder`と塊・`SessionLiveStream`。FoundationとObservationだけ |
| `SessionsCapture` | UIKit。タップ・アプリのライフサイクル・キーボード・スクロールビュー・止まり・MetricKitのクラッシュ・端末の値・録画のコマ（`startReplay`）。UIKitの無い所では空になる |
| `SessionsSwiftUI` | `.sessionTarget`・`.sessionScroll`・`.sessionRow`・`.sessionMask`・`.sessionNoCapture` |
| `SessionsTesting` | テスト用のフェイク。時計・保存先・id・受けた物を残す送り先 |

## 動く環境

- iOS 17以上・macOS 14以上（`.sessionScroll`が深さを測るのはiOS 18から）
- Swift 6.2以上

## ライセンス

MIT。[LICENSE](LICENSE)を見る。
