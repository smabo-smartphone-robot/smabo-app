# smabo-app

ESP32ロボット用スマートフォンアプリ（Flutter製）。

スマートフォンがロボットの「顔」になりつつ、センサ（IMU・GPS・カメラ）の送信と音声インタフェースを担います。
接続先は smabo-brain（または smabo-brain-ros）のみです。走行・サーボの操作や ESP32 の設定は smabo-web で行います。

---

## 機能概要

| 機能 | 説明 |
|------|------|
| **顔表示** | カスタマイズ可能な2Dアニメーション顔（表情・色・形・まぶた・回転）。`/expression`（String、表情の名前）で表情、`/look_at`（PoseStamped）で視線を切替 |
| **センサ送信** | IMU（`/imu/data`）・GPS（`/gps/fix`）を brain へ送信 |
| **カメラ映像** | WebRTC で brain へ映像を送信（シグナリングは `/webrtc/offer`・`/webrtc/app_ice`・`/webrtc/answer`） |
| **音声入力** | ウェイクワード「smabo」（または画面タップ）で発話を録音し、WAV を `/speech/audio` で brain へ送信。音声認識（STT）は brain 側で実行 |
| **発話** | `/speech/say`（String）を受信して TTS で読み上げ、吹き出しを表示 |

---

## アーキテクチャ

```
スマートフォン (smabo-app)
│
├── UI層
│   ├── 顔画面        — 表情アニメーション（全画面）
│   ├── ステータスバー — brain 接続状態・音声状態
│   ├── センサ切替    — Voice / Camera / IMU / GPS の ON/OFF
│   ├── 顔の設定      — 目の形・色・表情の編集
│   └── 設定画面      — 接続先・カメラ・IMU・音声・表示
│
├── State層
│   └── AppState (Provider)
│
├── Services
│   ├── sensor_service.dart  — IMU / GPS
│   ├── webrtc_service.dart  — カメラ映像（WebRTC）
│   ├── speech_service.dart  — ウェイクワード検出・録音
│   └── tts_service.dart     — 読み上げ
│
└── Core層
    ├── connection/connection_manager.dart — brain への接続
    ├── wire/ws_client.dart     — ROS非依存WebSocketクライアント
    ├── wire/ros_compat.dart    — rosbridgeフォーマット互換レイヤ（ここだけ）
    └── models/                 — FaceConfig, FaceExpression など
```

### 通信プロトコル

WebSocket（rosbridge v2.0 互換 JSON）で brain に接続します。

**接続先（設定画面で変更可）:**

| エンドポイント | デフォルト | 用途 |
|---------------|-----------|------|
| brain | `ws://smabo-brain.local:9090` | 顔・音声・センサ・カメラのシグナリング |

送信するトピックには送信元 prefix `/app` が付きます（brain が剥がして再配信）。

- 送信: `/imu/data`, `/gps/fix`, `/speech/audio`, `/webrtc/offer`, `/webrtc/app_ice`, `/phone/config`, `/phone/config_url`
- 受信: `/look_at`, `/expression`, `/speech/say`, `/webrtc/answer`
- 接続のたびに、送信トピックを `advertise`、受信トピックを `subscribe` します（smabo-brain / smabo-brain-ros のどちらでも同じ。表は `lib/core/wire/ros_compat.dart` の `RosProtocol`）

カメラ映像は WebSocket ではなく WebRTC で brain に送ります。

### 設定の REST API（ポート 8081）

ESP32 と同じく、設定は REST で読み書きできます。smabo-web の Config タブ（Phone 欄）はこれを使います。smabo-sim のスマホも同じ API を持つので、実機とシミュレータを同じ画面で設定できます。

| | |
|---|---|
| `GET /config` | 設定全体（JSON） |
| `POST /config` | 一部だけの JSON を送ると、その項目だけ変える。返事は `{"ok": true, "ignored": [...]}`（知らない項目・読み取り専用の項目・型の違う値は無視して返す） |
| `/app/phone/config_url` | `http://<スマホのIP>:8081`。接続時と 5 秒ごと |
| `/app/phone/config` | 設定全体（JSON 文字列）。接続時と、変わるたび（アプリの設定画面で変えても、REST で変えても） |

```json
{
  "brain":   {"host": "smabo-brain.local", "port": 9090},
  "http":    {"port": 8081},
  "sensors": {"imu": {"enabled": false, "rate_hz": 20}, "gps": {"enabled": false},
              "camera": {"enabled": false, "front": true}},
  "voice":   {"enabled": true, "wake_word": "smabo", "stt_locale": "ja_JP"},
  "speech":  {"tts": true, "tts_language": "ja-JP", "bubble": true, "ignore_repeated": true},
  "face":    {"auto_hide": true, "auto_hide_seconds": 5, "expression": "Normal",
              "expressions": ["Normal", "Sleepy", "Angry", "..."]},
  "app":     {"name": "smabo-app", "version": "0.1.3+4", "schema": 1}
}
```

`brain`・`http`・`app` と表情の一覧は読み取り専用です（brain の接続先はアプリの設定画面で変えます）。中身は `lib/core/models/phone_config.dart`、サーバーは `lib/services/config_server.dart`。

#### 表情は名前で選ぶ

表情は**名前**で指定します（`/expression` の `std_msgs/String`、設定の `face.expression`）。名前は大文字小文字と前後の空白を区別せずに照らし合わせ、同じ名前は付けられません（追加・複製では「Angry (copy) 2」のように番号が付きます）。知らない名前が届いたときは表示を変えず、ログに残します。番号（id）はアプリの中だけで使い、画面には出さず変更もできません（下の `/face/expressions/<id>` の URL でだけ使います）。表情の名前を変えたら、その名前で呼んでいる brain のスクリプトなども合わせて直してください。

#### 表情（`/face/...`）

表情も同じポートで編集できます。smabo-web の「Edit expressions」は `GET /face/schema` の内容（項目・型・範囲・どの目の形で使うか）から画面を組み立てるので、アプリに項目を足せば web は変えなくても表示されます。

| | |
|---|---|
| `GET /face/schema` | 編集できる項目の一覧（`test/face_schema.json` と同じ。smabo-sim のテストもこれと比べる） |
| `GET /face/expressions` | `{"active": id, "expressions": [...]}`。色は `"#RRGGBB"`、目の形は名前（`round` など） |
| `POST /face/expressions/<id>` | 一部だけ変える。`{"ok": true, "ignored": [...]}` |
| `POST /face/expressions` | 追加（`{"copy_of": id}` で複製）。`{"ok": true, "id": 新しい id}` |
| `DELETE /face/expressions/<id>` | 削除（最後の 1 つは消せない） |
| `GET /face/preview.png?id=<id>&w=<px>&h=<px>` | その表情をアプリの描画で PNG にしたもの（目は正面・開いた状態。辺は最大 1024px）。smabo-web のプレビュー用 |

アプリの編集画面と同じく、左右共通（`per_eye: false`）のときは右目は左目のコピーになり、`per_eye` をオンにすると左目のコピーから始まります。スキーマを変えたら `UPDATE_FACE_SCHEMA=1 flutter test test/face_schema_test.dart` で `test/face_schema.json` を作り直します。

---

## セットアップ

### 前提条件

| 項目 | バージョン |
|------|------------|
| Flutter SDK | 3.44.1（`~/development/flutter`） |
| Dart SDK | `>=3.2.0 <4.0.0` |
| 対象プラットフォーム | Android / iOS |

> Homebrew の Flutter は古い場合があります。`~/development/flutter/bin/flutter` を使ってください。

### 1. 環境確認

```bash
~/development/flutter/bin/flutter doctor
```

Android・iOS の欄に問題がないことを確認します。

### 2. 依存パッケージのインストール

```bash
~/development/flutter/bin/flutter pub get
```

### 3. デバイスの準備

**Android**

1. 開発者オプションを有効化（設定 → ビルド番号を 7 回タップ）
2. USB デバッグを ON
3. USB でPCに接続

**iOS**

1. Xcode をインストール済みであること
2. iPhone の「開発者モード」を ON（設定 → プライバシーとセキュリティ）
3. `open ios/Runner.xcworkspace` → Signing & Capabilities で Bundle ID・チームを設定
4. USB でPCに接続

### 4. 実行

```bash
# 接続済みデバイスの確認
~/development/flutter/bin/flutter devices

# 実行（デバイスが1台の場合はそのまま、複数台は -d <device-id>）
~/development/flutter/bin/flutter run
```

### 5. リリースビルド

```bash
# Android APK
~/development/flutter/bin/flutter build apk --release

# iOS（Xcode でのアーカイブ・署名が別途必要）
~/development/flutter/bin/flutter build ios --release
```

---

## 主要な依存パッケージ

| パッケージ | 用途 |
|-----------|------|
| `provider` | 状態管理 |
| `web_socket_channel` | WebSocket通信 |
| `shared_preferences` | 設定の永続化 |
| `speech_to_text` | ウェイクワード検出 |
| `flutter_tts` | テキスト読み上げ（TTS） |
| `flutter_webrtc` | カメラ映像の送信（WebRTC） |
| `record` | 発話の録音 |
| `sensors_plus` | IMUセンサ |
| `geolocator` | GPS |
| `permission_handler` | カメラ・マイク・位置情報パーミッション |
| `vector_math` | クォータニオン計算（IMU/Pose） |
| `flutter_colorpicker` | 顔カスタマイズ用カラーピッカー |

---

## バージョンと互換性

ほかの smabo リポジトリとは、同じ minor 番号（`0.2.x` など）どうしで組み合わせます。対応表は
[smabo-brain の README](https://github.com/smabo-smartphone-robot/smabo-brain#バージョンと互換性) にあります。
