<div align="center">

<img src="../../brand/corta-pangolin-mascot.png" width="160" alt="C の字に丸まり、しっぽがシアンのカーソルになっている Corta のセンザンコウのマスコット">

# Corta

**速く、集中できるターミナル。Mac のために、Swift で。**

Metal 4 レンダリング · ネイティブな CJK / IME · SSH、SFTP、リモート編集

> ターミナルで暮らす人のために：くっきりした文字、ネイティブな入力、強力なリモートワークフロー、そしてサードパーティ依存**ゼロ**の Swift 製ターミナルコア。激しい出力にも耐える速さと、毎日の作業に寄り添う細やかさ。

[![CI](https://github.com/noah-qin/Corta/actions/workflows/ci.yml/badge.svg)](https://github.com/noah-qin/Corta/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/noah-qin/Corta?style=flat-square)](https://github.com/noah-qin/Corta/releases/latest)
![Platform](https://img.shields.io/badge/macOS_26.0%2B-Apple_silicon-4d4d4d?style=flat-square)
![Swift](https://img.shields.io/badge/Swift-6-f05138?style=flat-square)
[![License](https://img.shields.io/badge/license-Apache--2.0-2f81f7?style=flat-square)](../../../LICENSE)
[![Discord](https://img.shields.io/badge/Discord-join-5865f2?style=flat-square&logo=discord&logoColor=white)](https://discord.gg/QNdWfdwr7j)
[![Sponsor](https://img.shields.io/badge/Sponsor-%E2%9D%A4-db61a2?style=flat-square&logo=githubsponsors&logoColor=white)](https://github.com/sponsors/noah-qin)

**[↓ ダウンロード](https://github.com/noah-qin/Corta/releases/latest)** ·
**[ユーザーガイド](USER-GUIDE.md)** ·
[ドキュメント（英語）](../../README.md) ·
[コントリビュート](../../../CONTRIBUTING.md) ·
[Discord](https://discord.gg/QNdWfdwr7j) ·
[バグを報告](https://github.com/noah-qin/Corta/issues/new?template=bug_report.yml)

🇺🇸 [English](../../../README.md) · 🇨🇳 [简体中文](../zh-CN/README.md) · 🇭🇰 [繁體中文](../zh-Hant/README.md) · 🇯🇵 [日本語](README.md) · 🇰🇷 [한국어](../ko/README.md) · 🇩🇪 [Deutsch](../de/README.md) · 🇫🇷 [Français](../fr/README.md) · 🇪🇸 [Español](../es/README.md) · 🇧🇷 [Português](../pt-BR/README.md)

<img src="../../brand/screenshot.png" width="960" alt="3 つに分割された Corta のペイン：git log と中日韓・絵文字の揃い表、ターミナル内に表示されたセンザンコウの画像、24 ビットカラーのグラデーション">

</div>

> このページは英語版 [README.md](../../../README.md) のコミット
> [`bdcf6da`](https://github.com/noah-qin/Corta/blob/bdcf6daab52425e20f6e953a1b0de152d2dfe2bf/README.md)
> 時点の翻訳です。その後英語版が更新された場合や内容に食い違いがある場合は、英語版が正となります。

## インストール

**macOS 26.0 以降**、**Apple シリコン**（M1 以降）、**Metal 4 対応 GPU** が必要です。
準仮想化 GPU を使う仮想マシンには対応していません。Intel Mac では旧版の
[1.0.1](https://github.com/noah-qin/Corta/releases/tag/v1.0.1) を使えます。

[GitHub Releases](https://github.com/noah-qin/Corta/releases/latest) から `.dmg` と対応する
`.dmg.sha256` ファイルをダウンロードし、両方を同じフォルダに置いて、そこでチェックサムを検証します：

```sh
# x.y.z はダウンロードしたバージョンに置き換えてください。
shasum -a 256 -c Corta-x.y.z.dmg.sha256
```

ディスクイメージを開き、**Corta** を **アプリケーション** にドラッグしてから、イメージを取り出します。
リリース版は Developer ID で署名され、公証済みです。以降のアップデートは **Corta ▸ アップデートを確認…** を使うか、
新しいリリースをダウンロードしてください。インストールの手助けとアンインストール手順は
[トラブルシューティング](TROUBLESHOOTING.md)にあります。

## はじめの一歩

| やりたいこと | 操作 |
| :--- | :--- |
| 右 / 下に分割 | ⌘D / ⇧⌘D |
| ターミナル出力を検索 | ⌘F |
| コマンドパレットを開く | ⇧⌘P |
| 設定を開く | ⌘, |

ディレクトリ候補が有効なとき（デフォルト）、標準のローカル zsh セッションは同梱のシェル統合フックを自動的に読み込みます。
zsh、bash、fish の起動ファイルにインストールするには **設定 ▸ ターミナル ▸ シェル統合** を使います。
シェルの起動ファイルが編集されるのは「インストール」を選んだときだけです。インストール済みの統合が古くなっていたら、
「更新」を選んで新しいシェルを開いてください。詳しくは
[シェル統合ガイド](USER-GUIDE.md#shell-integration)を参照してください。

## Corta を選ぶ理由

| | |
| :--- | :--- |
| **ネイティブな Mac 入力** | CJK 入力と IME の変換、Core Text のフォントフォールバック、VoiceOver、セキュリティキーボード入力、サービス、クイックターミナル、ショートカットのアクション——AppKit を避けるのではなく、AppKit を通して。 |
| **速さを、根拠とともに** | コアのスループットは 1.1 の 2.3 倍、全画面の入力遅延は 1 フレーム短縮、10 万行の履歴は 185 MiB ではなく 11 MiB。すべての数値を、測定方法と限界とともに公開しています（下記）。 |
| **リモート作業を標準で** | システムの OpenSSH と `~/.ssh/config`、ドラッグ＆ドロップできる Finder 風の SFTP ブラウザ、そしてアップロード前に競合を確認するローカルエディタでのリモートファイル編集。 |
| **設定ファイルはひとつ** | ネイティブの設定ウインドウと `~/.config/corta/config` は同じ設定を編集します。ドキュメントに載っているキーとショートカットがコードと一致していることを、自動チェックが保証します。 |
| **小さなコア、確かな安全策** | サードパーティ依存のない Swift 製ターミナルコア、信頼できない出力に対するリソース上限、サンドボックス化された画像デコーダ。アプリが追加するのはアップデート用の [Sparkle](https://sparkle-project.org) だけです。クリップボードの読み取りとタイトルの問い合わせは意図的に実装していません（[セキュリティモデル](../../SECURITY.md)、英語）。 |

ペイン分割、スクロールバック検索、トゥルーカラー、OSC 8 リンク、Kitty キーボードプロトコルとグラフィックスプロトコル、
シェル統合、レイアウトの復元——すべて揃っています。[機能リファレンス](../../FEATURES.md)（英語）には要件と制限つきで全機能が載っており、
内容は `main` ブランチのものです。公開済みのリリースにはまだ含まれていない項目もあります。iTerm2 や Ghostty との比較、
そしてそちらを選ぶべき場面については
[Features → How Corta compares](../../FEATURES.md#how-corta-compares)（英語）にあります。
コーディングエージェントのタスク状態について、開発中のツリーが連携しているのは現在 **Claude Code だけ**です。ほかのツールには
汎用プロトコルへの対応とプロセス検出があるだけで、専用の状態アダプタはありません（[範囲と限界](../../CONFORMANCE.md#cli-signal-compatibility)、英語）。
Claude Code 2.1.310 で開発と受け入れ確認をしています：対話セッションの OSC 7501 の状態と、Claude のメッセージ文のための
明示的なチャネル選択です。tmux、Claude のバックグラウンドセッション、ターミナルタイトルの報告を無効にした場合には、それぞれ別の
制限があります。パーサが対応しているからといって、実際のライフサイクル全体の受け入れ確認が済んでいるわけではありません。
macOS 専用であること、tmux コントロールモード・内蔵 AI・スクリプトエンジンを持たないことは
[確定した決定事項](../../DECISIONS.md)（英語）です。通常の tmux セッションはターミナルプログラムとして Corta の中で動きます。

## 自分好みに

設定は `~/.config/corta/config` に保存されます。ネイティブの設定ウインドウとこのテキストファイルは、同じ設定を編集します。

```ini
theme = midnight
theme.midnight.inherit = solarized
theme.midnight.dark.background = #101018

bind.equalize-panes = ctrl+cmd+e
bind.command-palette = cmd+shift+p
```

**表示 ▸ テーマエディタ…** を開くと、カラーピッカーとライト／ダーク別々のプレビューが使えます。**設定 ▸ 外観 ▸ カーソル**
ではブロック・縦線・下線と、独立した点滅スイッチを選べます。デフォルトは点滅しないブロックです。メインフォントは
システム等幅のみに対応し、サイズは調整でき、足りない文字はシステムのフォールバックで補われます。
**設定 ▸ ターミナル ▸ 下部ステータスバー** でローカルの指標を選んで表示できます（デフォルトはオフ）。
クリックするとホストの詳細が出ます。**表示 ▸ ローカルホストの詳細…** からも開けます。
手順、ネットワークインターフェイスの選び方、熱状態の限界については
[カスタマイズのチュートリアル](USER-GUIDE.md#personalizing-the-terminal)を参照してください。

[設定リファレンス](../../CONFIGURATION.md)（英語）には、すべてのキー、デフォルト値、変更が反映されるタイミングが載っています。
[ユーザーガイド](USER-GUIDE.md)では、すべての機能とその場所を順に紹介しています。

## ソースからビルド

```sh
git clone https://github.com/noah-qin/Corta.git && cd Corta
swift test --package-path CortaTerminal                     # ターミナルコアのみ、アプリなし
xcodebuild -project Corta.xcodeproj -scheme 'Corta (Dev)' build  # インストール済みの Corta と共存する開発版アプリ
```

[コントリビューターガイド](../../../CONTRIBUTING.md)（英語）には、必要な環境（macOS 26、Apple シリコン、
[`.xcode-version`](../../../.xcode-version) に記された Xcode）、ローカルでの署名、リポジトリの地図があります。
[テストガイド](../../TESTING.md)（英語）には、変更の種類ごとに必要なチェックが書かれています。

## 品質を、根拠とともに

Corta は活発に開発中で、既知の問題もあります。以下の測定値はスナップショットであり、すべてのマシンや負荷で
成り立つことを保証するものではありません。各行に、どのリリースで測定したかを記しています。

| チェック | 記録された結果 | 測定したリリース | 根拠 |
| :--- | :--- | :--- | :--- |
| コアのフィードスループット（パーサ、グリッド、スクロールバック。PTY とレンダリングは含まない） | **317.3 MiB/s**（旧 137.2） | 1.2 対 1.1 | [Performance §5.14](../../PERFORMANCE.md#514-scrolling-without-per-line-screen-allocation-281-283) |
| パーサ + グリッドのスループット | **355.9 MiB/s**（旧 158.0） | 1.2 対 1.1 | 同上 |
| スクロールバックのメモリ、10 万行 × 120 桁 | **11.4 MiB**（旧 185） | 1.2 対 1.1 | [Performance §5.6](../../PERFORMANCE.md#56-numbers-by-release) |
| 領域スクロール、1 フレームあたりの CPU、p50 | **0.026 ms**（旧 0.130） | 1.2 対 1.1 | [Performance §5.14](../../PERFORMANCE.md#514-scrolling-without-per-line-screen-allocation-281-283) |
| フレーム CPU、120 × 40 の全再構築、Release | **0.37–0.39 ms** | 1.2 | [Performance §5.17](../../PERFORMANCE.md#517-full-screen-without-the-compositor-285-2026-10-13) |
| キー入力から画面表示まで、全画面、1 ペイン、60 Hz、人による入力 | p50 **49.1–50.8 ms**、p99 82.9–84.2 ms（旧 p50 は 64–68 ms） | 1.2 | [Performance §5.17](../../PERFORMANCE.md#517-full-screen-without-the-compositor-285-2026-10-13) |
| アイドル時の CPU、Release、20 秒 | 0.05% | **1.0.0**（2026-09-18）。1.2 のアイドル時ウェイクアップ改善以降は未測定 | [Performance](../../PERFORMANCE.md) |
| esctest2 | 成功 131、既知のバグ 334、失敗 102。計 567 | **1.1.5**（2026-10-07） | [生の結果](https://github.com/noah-qin/Corta/blob/f632d5918653cc2feee28fe1baa0c0fd01e93c0e/docs/esctest/2026-10-07-results.txt) |

測定は Apple M5 MacBook Air（macOS 27.0.1）で行いました。1.2 の各行は 2026-10-09 から 2026-10-13 にかけて測定し、
前後の比較はそれぞれ同じマシン・同じツールチェーンで行っています。[Performance](../../PERFORMANCE.md)（英語）の
日付つきの節に、条件、すべての実行、そしてその数値が示さないことが書かれています。ときどき引用される esctest2 の
82.0% という数字は成功数に**既知のバグを足したもの**で、成功率ではありません。解釈については
[Conformance](../../CONFORMANCE.md)（英語）を参照してください。

既知の制限として、ウインドウ表示ではキー入力から画面表示までの遅延が 1 フレームの目標を上回ること（全画面・1 ペインが最も近い）、
VT 準拠が不完全であること、同梱のシェル統合が zsh・bash・fish のみであること、Kitty グラフィックスが直接転送のみであることが
挙げられます。詳細は[制限のリファレンス](../../FEATURES.md#known-limits)（英語）にあります。

## 道案内

| やりたいこと | ここから |
| :--- | :--- |
| すべての機能とその場所を知る | [ユーザーガイド](USER-GUIDE.md) |
| Corta を設定する | [Configuration](../../CONFIGURATION.md)（英語） |
| 機能や制限を理解する | [Features](../../FEATURES.md)（英語） |
| 問題を診断する | [トラブルシューティング](TROUBLESHOOTING.md) |
| iTerm2、Ghostty、Terminal.app から乗り換える | [ほかのターミナルから乗り換える](USER-GUIDE.md#coming-from-another-terminal) |
| 予定を見る、提案する | [Open issues](https://github.com/noah-qin/Corta/issues) · [Discussions → Ideas](https://github.com/noah-qin/Corta/discussions/categories/ideas) |
| 取り組めることを探す | [Good first issues](https://github.com/noah-qin/Corta/labels/good%20first%20issue) · [Help wanted](https://github.com/noah-qin/Corta/labels/help%20wanted) |
| 初めてコントリビュートする | [Contributing](../../../CONTRIBUTING.md)（英語） |
| テストを実行・追加する | [Testing](../../TESTING.md)（英語） |
| コードを理解する | [Architecture](../../DESIGN.md) · [Core API](../../../CortaTerminal/Sources/CortaTerminal/CortaTerminal.docc/CortaTerminal.md)（英語） |
| ドキュメント全体を読む | [ドキュメント索引](../../README.md)（英語） |

## コントリビュート

バグの再現、ドキュメント、翻訳、アクセシビリティのテスト、コードのコントリビュートを歓迎します。
[good first issue](https://github.com/noah-qin/Corta/labels/good%20first%20issue) や
[help wanted](https://github.com/noah-qin/Corta/labels/help%20wanted) から始めて、セットアップとレビューの方針は
[CONTRIBUTING.md](../../../CONTRIBUTING.md) を読んでください。コミュニティへの参加は
[行動規範](../../../CODE_OF_CONDUCT.md)に従います。

Corta を試して、元のターミナルに戻りましたか？ それもぜひ聞かせてください：
[Went back フォーム](https://github.com/noah-qin/Corta/issues/new?template=went_back.yml)
は再現手順が不要で、「なんとなくしっくりこなかった」も立派な回答です。

脆弱性は[非公開のセキュリティ窓口](../../../SECURITY.md)から報告してください。
ほかのユーザーやメンテナーと話したいときは [Discord](https://discord.gg/QNdWfdwr7j) へどうぞ。
答えをほかの人も見つけられるようにしたい使い方の質問は [Discussions → Q&A](https://github.com/noah-qin/Corta/discussions/categories/q-a) へ（日本語での質問も歓迎です）。
テーマや環境を共有するなら [Show and tell](https://github.com/noah-qin/Corta/discussions/categories/show-and-tell) へ。
そのほかの問題は [issue を作成](https://github.com/noah-qin/Corta/issues/new/choose)してください。

### スポンサー

Corta は一人の手で、公開の場で作られ、保守されています。毎日の一部になっているなら、スポンサーが開発を前に進めます——金額はいくらでも助けになります。

<a href="https://github.com/sponsors/noah-qin"><img src="https://img.shields.io/badge/Sponsor_noah--qin_on_GitHub-%E2%9D%A4-db61a2?style=for-the-badge&logo=githubsponsors&logoColor=white" alt="GitHub で noah-qin のスポンサーになる"></a>

### コントリビューター

Corta にコントリビュートしてくださったすべての方に感謝します。

<a href="https://github.com/noah-qin"><img src="https://github.com/noah-qin.png?size=96" width="48" height="48" alt="noah-qin" title="noah-qin"></a>
<a href="https://github.com/FrankChen-CLC"><img src="https://github.com/FrankChen-CLC.png?size=96" width="48" height="48" alt="FrankChen-CLC" title="FrankChen-CLC"></a>

## ライセンスとアイデンティティ

ソースコードは [Apache 2.0](../../../LICENSE) でライセンスされています。Corta の名前、センザンコウのマスコット、アプリアイコンには
[NOTICE](../../../NOTICE) に別の条件があります。センザンコウの丸まった体が C の字を作り、シアンのしっぽはターミナルのカーソルです。
[ブランド素材](../../brand/README.md)にはマスコットとソーシャルプレビューが含まれます。
