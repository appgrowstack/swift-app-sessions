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

軽い記録は画素を持たない。`.sessionMask()`と`.sessionNoCapture()`はマークを置くだけ。

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

## 入れ方

`Package.swift`に足す。

```swift
dependencies: [
    .package(url: "https://github.com/appgrowstack/swift-app-sessions.git", .upToNextMinor(from: "0.1.0"))
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
| `SessionsCore` | セッションの区切り・判定・記録する`AppSessions`・バッチ・`SessionSink`・`FileSessionSink`・`DebugSessionSink`。FoundationとObservationだけ |
| `SessionsCapture` | UIKit。タップ・アプリのライフサイクル・キーボード・スクロールビュー・止まり・MetricKitのクラッシュ・端末の値。UIKitの無い所では空になる |
| `SessionsSwiftUI` | `.sessionTarget`・`.sessionScroll`・`.sessionRow`・`.sessionMask`・`.sessionNoCapture` |
| `SessionsTesting` | テスト用のフェイク。時計・保存先・id・受けた物を残す送り先 |

## 動く環境

- iOS 17以上・macOS 14以上（`.sessionScroll`が深さを測るのはiOS 18から）
- Swift 6.2以上

## ライセンス

MIT。[LICENSE](LICENSE)を見る。
