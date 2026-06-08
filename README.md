# smabo-app

ESP32ロボット用スマートフォンアプリ（Flutter製）。

スマートフォンがロボットの「顔」になりつつ、走行コントローラ・アームコントローラ・センサパブリッシャ・音声インタフェースを兼ねます。

---

## 機能概要

| 機能 | 説明 |
|------|------|
| **顔表示** | カスタマイズ可能な2Dアニメーション顔（表情・色・形・まぶた・回転） |
| **走行コントロール** | 仮想ジョイスティックで`/cmd_vel`送信 |
| **アームコントロール** | サーボ角度指令`/servo/command`送信 |
| **センサ送信** | IMU・GPS・カメラ映像をbrainデバイスへ送信 |
| **音声インタフェース** | ウェイクワード「smabo」でSTT起動、TTSでロボットが発話 |
| **表情切替** | `/expression`トピック（Int32）でリモート切替可能 |

---

## アーキテクチャ

```
スマートフォン (smabo-app)
│
├── UI層
│   ├── 顔ページ      — 表情アニメーション、カスタマイズ設定
│   ├── 走行ページ    — 仮想ジョイスティック
│   └── アームページ  — サーボ操作UI
│
├── State層
│   └── AppState (Provider)
│
└── Core層
    ├── wire/ws_client.dart     — ROS非依存WebSocketクライアント
    ├── wire/ros_compat.dart    — rosbridgeフォーマット互換レイヤ（ここだけ）
    └── models/                 — FaceConfig, FaceExpression など
```

### 通信プロトコル

WebSocketで通信。

**接続先（設定画面で変更可）:**

| エンドポイント | デフォルト | 用途 |
|---------------|-----------|------|
| ESP32 | `ws://<ip>:9090` | 走行・サーボ・設定同期 |
| brainデバイス | `ws://<ip>:9090` | 顔追従・音声・カメラ |

**ESP32が処理するトピック:**

- パブリッシュ: `/cmd_vel`, `/servo/command`, `set_mode`, `set_config`, `get_config`
- サブスクライブ: `/odom`, `/joint_states`

**brainデバイスが処理するトピック:**

- パブリッシュ: `/speech/recognized`, `/imu/data`, `/gps/fix`, カメラ映像
- サブスクライブ: `/look_at`, `/speech/say`, `/expression`

---

## 開発環境

- Flutter 3.44.1（`~/development/flutter`）
- Dart SDK `>=3.2.0 <4.0.0`
- 対象プラットフォーム: Android / iOS

```bash
# バージョン確認
~/development/flutter/bin/flutter --version

# 依存関係インストール
~/development/flutter/bin/flutter pub get

# 実行（デバイス接続後）
~/development/flutter/bin/flutter run
```

---

## 主要な依存パッケージ

| パッケージ | 用途 |
|-----------|------|
| `provider` | 状態管理 |
| `web_socket_channel` | WebSocket通信 |
| `shared_preferences` | 設定の永続化 |
| `speech_to_text` | 音声認識（STT） |
| `flutter_tts` | テキスト読み上げ（TTS） |
| `camera` | カメラ映像取得 |
| `sensors_plus` | IMUセンサ |
| `geolocator` | GPS |
| `permission_handler` | カメラ・マイク・位置情報パーミッション |
| `vector_math` | クォータニオン計算（IMU/Pose） |
| `flutter_colorpicker` | 顔カスタマイズ用カラーピッカー |
| `image_picker` | 顔カスタマイズ用画像選択 |

---

