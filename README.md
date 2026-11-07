# smabo-app

ESP32ロボット用スマートフォンアプリ（Flutter製）。

スマートフォンがロボットの「顔」になりつつ、センサ（IMU・GPS・カメラ）の送信と音声インタフェースを担います。
接続先は smabo-brain（または smabo-brain-ros）のみです。走行・サーボの操作や ESP32 の設定は smabo-web で行います。

---

## 機能概要

| 機能 | 説明 |
|------|------|
| **顔表示** | カスタマイズ可能な2Dアニメーション顔（表情・色・形・まぶた・回転）。`/expression`（Int32）で表情、`/look_at`（PoseStamped）で視線を切替 |
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

- 送信: `/imu/data`, `/gps/fix`, `/speech/audio`, `/webrtc/offer`, `/webrtc/app_ice`
- 受信: `/look_at`, `/expression`, `/speech/say`, `/webrtc/answer`
- `subscribe` op は `/look_at`・`/expression` について送信します

カメラ映像は WebSocket ではなく WebRTC で brain に送ります。

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
| `image_picker` | 顔カスタマイズ用画像選択 |

---

