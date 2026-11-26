# swift-app-sessions

iOSアプリの中で人が何をしたかを、セッションごとに記録する。画面・タップ・rage tap・すぐ戻った操作・スクロールの深さ・止まった時間・セッションの終わり方を残す。

[English](README.md) | 日本語

## 機能

- **セッションの区切り。** アプリが前に出たときに1つ始まり、バックグラウンドに30分いた後に戻ったときにも始まる。バックグラウンドでの起動（`BGTaskScheduler`の仕事・バックグラウンドの更新・事前の起動）では始めず、何も記録しない。後で本人がアプリを開くと、別のセッションが始まる。idは`ses_`と20文字。最初のセッションの`start`は`first: true`を持つ。これは「このSDKがこの端末で記録する最初のセッション」で、SDKを入れたバージョンに上げた前からの利用者でもtrueになる。新しい人かどうかは、アプリの初回起動の出来事で見分ける
- **前に出ていた時間。** `background`と`end`は`foreground_ms`（セッションが前に出ていた時間）を持つ。バックグラウンドに置いたままの時間でセッションが長く見えない。アプリがバックグラウンドに行って30分を過ぎてから、バックグラウンドの仕事が記録した物はセッションに入れない
- **画面は計測の出来事から。** `screen_viewed`でその画面へ動く。今の画面の下の画面へ戻るのは`pop`で、`back`と、入ってから2秒以内なら`quick_back`も記録する。アプリが自分で閉じる画面（長押しが終わると閉じるシートなど）は、閉じる直前に`noteDismissByApp()`を呼ぶと`quick_back`にしない
- **タッチを止めないタップの記録。** 各ウィンドウに、何も認識しないジェスチャーの認識を足す。位置はウィンドウに対する0〜10000（iPadの分割のウィンドウも）。`.sessionTarget("…")`で要素に名前を付ける
- **rage tap。** 最初のタップから1秒以内・30pt以内に3回以上
- **dead tap。** 画面を録画している間、タップの後1.5秒、画面が開かず、アプリの出来事も無く、画面の絵も変わらなかったタップ
- **スクロールの深さ。** 画面ごとに、主なスクロールビューの一番深い所を残す。`.sessionScroll("…")`と`.sessionRow(_:in:)`で名前を付けた一覧も
- **終わり方。** `background_timeout`・`crashed`（MetricKit。レポートが遅れて届いても直す）・`hung`（監視のスレッド）・`killed`・`unknown`を次の起動で決める
- **アプリの出来事は残す物を絞る。** 共通のカタログの出来事は値を残す。アプリ独自の出来事は`keepProps`に書いたプロパティだけを残す。48文字を超える文字列は捨てる
- **再起動やオフラインでも消えない。** 送れていない物は保存し、同じバッチの番号で後から送る。受ける側は重なりを捨てられる
- **マーク。** 一部の出来事（`paywall_shown`・`purchase_completed`・`campaign_shown`など）はマークも作る。`mark(_:ref:side:)`で出来事なしにマークを足せる
- **依存なし。** Foundation・Observation・UIKit・MetricKitだけ。SwiftUIを使うのは`SessionsSwiftUI`だけ

軽い記録は画素を持たない。録画（下）は持つ。`.sessionMask()`と`.sessionNoCapture()`は録画が読むマークを置く。`.sessionNoCapture()`を付けた画面は、見えている間と、その上に別の画面が重なっている間（pushした先・その画面から出したシート）、録画を撮らない。アラートとアクションシートも出ている間は撮らない。今撮ると撮らない理由は`SessionCapture.blankReason(noCaptureScreens:)`で分かる。

### タップした物の名前

タップには、指の下にある一番小さい`.sessionTarget("…")`の名前が付く。無ければ、当たった部品のアクセシビリティのidが付く。OSが付けたid（`pencil`などのSF Symbolsの名前・`PopoverDismissRegion`）は使わない。名前は指が触れた時に取る。長押しでシートが開いても、短いタップと同じ名前が付く。シート・全画面のカバー・ポップオーバー・アラートが出ている間は、その上の名前だけを見る。シートのボタンのタップに、下にある行の名前は付かない。SwiftUIのビューの上に重なったUIKitのビュー（タブバー）の下の名前も付かない。

同じビューの中に重ねて表示したレイヤー（`ZStack`や`.overlay`で出すダイアログ・オンボーディング・ピッカー）は、その根に`.sessionLayer()`を付ける。大きさは、そのレイヤーが覆う範囲（暗くした背景も含む）にする。指の下にレイヤーがある間は、その中の名前だけを見る。レイヤーの中で名前の無い所のタップは、下の行の名前でなく、名前なしになる。

```swift
ZStack {
    HabitList()   // rows marked .sessionTarget("habit_row")
    if showTerms {
        ZStack {
            Color.black.opacity(0.3).ignoresSafeArea()
            TermsDialog()   // its button marked .sessionTarget("terms_agree")
        }
        .sessionLayer()
    }
}
```

本人の操作の後に画面が自分で閉じるときは、閉じる直前に`noteDismissByApp()`を呼ぶ。

```swift
Button("Hold to finish") {}
    .onLongPressGesture {
        store.achieve(habit)
        AppSessions.current?.noteDismissByApp()  // the sheet closes itself: not a quick back
        dismiss()
    }
```

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
        capture.start()  // once, at launch; the session starts when the app is in the front
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
| `SessionsSwiftUI` | `.sessionTarget`・`.sessionLayer`・`.sessionScroll`・`.sessionRow`・`.sessionMask`・`.sessionNoCapture` |
| `SessionsTesting` | テスト用のフェイク。時計・保存先・id・受けた物を残す送り先 |

## 動く環境

- iOS 17以上・macOS 14以上（`.sessionScroll`が深さを測るのはiOS 18から）
- Swift 6.2以上

## ライセンス

MIT。[LICENSE](LICENSE)を見る。
