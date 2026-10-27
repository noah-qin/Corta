<div align="center">

<img src="../../brand/corta-pangolin-mascot.png" width="160" alt="Corta 的穿山甲吉祥物，身體蜷成字母 C，尾巴是一個青色游標">

# Corta

**快速、專注的終端機。為 Mac 而生，以 Swift 打造。**

Metal 4 算繪 · 原生中日韓輸入法 · SSH、SFTP 與遠端編輯

> 獻給長時間待在終端機裡的人：清晰的文字、原生的輸入、強大的遠端工作流程，以及**零**第三方依賴的 Swift 終端機核心。快到足以應付高強度輸出，細緻到適合每天的工作。

[![CI](https://github.com/noah-qin/Corta/actions/workflows/ci.yml/badge.svg)](https://github.com/noah-qin/Corta/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/noah-qin/Corta?style=flat-square)](https://github.com/noah-qin/Corta/releases/latest)
![Platform](https://img.shields.io/badge/macOS_26.0%2B-Apple_silicon-4d4d4d?style=flat-square)
![Swift](https://img.shields.io/badge/Swift-6-f05138?style=flat-square)
[![License](https://img.shields.io/badge/license-Apache--2.0-2f81f7?style=flat-square)](../../../LICENSE)
[![Discord](https://img.shields.io/badge/Discord-join-5865f2?style=flat-square&logo=discord&logoColor=white)](https://discord.gg/QNdWfdwr7j)
[![Sponsor](https://img.shields.io/badge/Sponsor-%E2%9D%A4-db61a2?style=flat-square&logo=githubsponsors&logoColor=white)](https://github.com/sponsors/noah-qin)

**[↓ 下載](https://github.com/noah-qin/Corta/releases/latest)** ·
**[使用者指南](USER-GUIDE.md)** ·
[文件（英文）](../../README.md) ·
[參與貢獻](../../../CONTRIBUTING.md) ·
[Discord](https://discord.gg/QNdWfdwr7j) ·
[回報問題](https://github.com/noah-qin/Corta/issues/new?template=bug_report.yml)

🇺🇸 [English](../../../README.md) · 🇨🇳 [简体中文](../zh-CN/README.md) · 🇭🇰 [繁體中文](README.md) · 🇯🇵 [日本語](../ja/README.md) · 🇰🇷 [한국어](../ko/README.md) · 🇩🇪 [Deutsch](../de/README.md) · 🇫🇷 [Français](../fr/README.md) · 🇪🇸 [Español](../es/README.md) · 🇧🇷 [Português](../pt-BR/README.md)

<img src="../../brand/screenshot.png" width="960" alt="Corta 的三個分割窗格：git log 與中日韓及 emoji 對齊表、在終端機中顯示的穿山甲圖片、24 位元色彩漸層">

</div>

> 本文譯自英文版 [README.md](../../../README.md)，對應提交
> [`bdcf6da`](https://github.com/noah-qin/Corta/blob/bdcf6daab52425e20f6e953a1b0de152d2dfe2bf/README.md)。
> 此後英文版如有更新，或兩者有出入，以英文版為準。

## 安裝

需要 **macOS 26.0 或更新版本**、**Apple 晶片**（M1 或更新）以及**支援 Metal 4 的 GPU**。
不支援使用半虛擬化 GPU 的虛擬機器。Intel Mac 可以使用舊版
[1.0.1](https://github.com/noah-qin/Corta/releases/tag/v1.0.1)。

從 [GitHub Releases](https://github.com/noah-qin/Corta/releases/latest) 下載 `.dmg`
和對應的 `.dmg.sha256` 檔案，兩者放在同一個資料夾裡，並在那裡驗證：

```sh
# 把 x.y.z 換成你下載的版本號。
shasum -a 256 -c Corta-x.y.z.dmg.sha256
```

打開磁碟映像檔，把 **Corta** 拖進「應用程式」，然後退出映像檔。正式版本均經過 Developer ID
簽署和 Apple 公證。之後的更新可以用 **Corta ▸ 檢查更新…**，或者下載新版本。
安裝問題和解除安裝方法見[疑難排解](TROUBLESHOOTING.md)。

## 上手

| 想要… | 操作 |
| :--- | :--- |
| 向右 / 向下分割 | ⌘D / ⇧⌘D |
| 搜尋終端機輸出 | ⌘F |
| 打開命令面板 | ⇧⌘P |
| 打開設定 | ⌘, |

開啟「目錄補全」（預設開啟）時，標準的本機 zsh 工作階段會自動載入內建的 shell 整合掛鉤。
要在 zsh、bash 或 fish 的啟動檔案中安裝，請使用 **設定 ▸ 終端機 ▸ Shell 整合**；
只有你按下「安裝」，才會修改 shell 的啟動檔案。已安裝的整合過時了，就按「更新」，再打開一個新 shell。
詳見 [Shell 整合指南](USER-GUIDE.md#shell-integration)。

## 為什麼選 Corta

| | |
| :--- | :--- |
| **原生 Mac 輸入** | 中日韓輸入法與組字、Core Text 字型遞補、VoiceOver、安全鍵盤輸入、服務、快捷終端機和捷徑動作——透過 AppKit 實作，而不是繞開它。 |
| **快，而且有證據** | 核心吞吐量是 1.1 的 2.3 倍，全螢幕輸入延遲少一格畫面，10 萬行歷史只佔 11 MiB（原本是 185 MiB）。每個數字都公開了量測方法和侷限（見下文）。 |
| **內建遠端工作流程** | 使用系統 OpenSSH 和你的 `~/.ssh/config`；類似 Finder 的 SFTP 瀏覽器，支援拖放；遠端檔案可以在本機編輯器中打開，上傳前會檢查衝突。 |
| **一個設定檔** | 原生設定視窗和 `~/.config/corta/config` 編輯的是同一份設定；自動化檢查確保文件中的設定項目和快速鍵與程式碼一致。 |
| **小核心，嚴防護** | Swift 終端機核心沒有任何第三方依賴，對不可信的輸出設有資源上限，圖片解碼在沙箱中進行；App 只額外使用 [Sparkle](https://sparkle-project.org) 做更新。讀取剪貼簿和查詢標題是刻意不支援的（[安全模型](../../SECURITY.md)，英文）。 |

分割窗格、捲動記錄搜尋、全彩、OSC 8 連結、Kitty 鍵盤協定與圖形協定、shell 整合和版面還原都已具備；
[功能參考](../../FEATURES.md)（英文）列出了全部功能及其需求和限制，描述的是 `main` 分支——
已發布的版本不一定包含其中每一項。Corta 與 iTerm2、Ghostty 的比較，以及什麼時候該選它們，見
[Features → How Corta compares](../../FEATURES.md#how-corta-compares)（英文）。
在程式碼代理的工作狀態方面，開發樹目前**只整合了 Claude Code**；其他工具只有通用協定支援和程序偵測，沒有專門的狀態轉接
（[範圍與限制](../../CONFORMANCE.md#cli-signal-compatibility)，英文）。它基於 Claude Code 2.1.310 開發和驗收：互動式 OSC 7501 狀態，
並可明確選擇通道來顯示 Claude 的訊息文字。tmux、Claude 背景工作階段和關閉終端機標題回報各有單獨的限制；剖析器涵蓋了某個協定，
並不代表完整的即時生命週期都經過了驗收。
Corta 只做 macOS，不支援 tmux 控制模式、內建 AI 和指令碼引擎，這些都是
[已定的決策](../../DECISIONS.md)（英文）；一般的 tmux 工作階段作為終端機程式在 Corta 裡照常執行。

## 照你的方式來

設定儲存在 `~/.config/corta/config`。原生設定視窗和這個文字檔編輯的是同一份設定。

```ini
theme = midnight
theme.midnight.inherit = solarized
theme.midnight.dark.background = #101018

bind.equalize-panes = ctrl+cmd+e
bind.command-palette = cmd+shift+p
```

**檢視 ▸ 主題編輯器…** 提供顏色挑選器以及分開的淺色／深色預覽。**設定 ▸ 外觀 ▸ 游標**
可以選擇方塊、直線或底線，並單獨開關閃爍；預設是不閃爍的方塊。主字型只支援系統等寬字體，
字級可調，缺少的字元由系統字型補上。**設定 ▸ 終端機 ▸ 底部狀態列** 可以開啟本機各項指標
（預設關閉）；按一下狀態列可查看主機詳情，也可以用 **檢視 ▸ 本機詳情…**。
具體步驟、網路介面的選擇和熱狀態的侷限，見[個人化教學](USER-GUIDE.md#personalizing-the-terminal)。

[設定參考](../../CONFIGURATION.md)（英文）列出了每個設定項目、預設值以及修改何時生效。
[使用者指南](USER-GUIDE.md)逐一介紹每個功能以及在哪裡找到它。

## 從原始碼建置

```sh
git clone https://github.com/noah-qin/Corta.git && cd Corta
swift test --package-path CortaTerminal                     # 只測終端機核心，不建置 App
xcodebuild -project Corta.xcodeproj -scheme 'Corta (Dev)' build  # 與已安裝的 Corta 並存的開發版 App
```

[貢獻指南](../../../CONTRIBUTING.md)（英文）寫明了環境需求（macOS 26、Apple 晶片、
[`.xcode-version`](../../../.xcode-version) 中指定的 Xcode）、本機簽署和儲存庫結構；
[測試指南](../../TESTING.md)（英文）說明每類改動需要哪些檢查。

## 品質，有證據

Corta 仍在積極開發中，也有已知問題。下面的量測是快照，不保證在每台機器、每種負載下都成立。
每一列都註明了是在哪個版本上量測的。

| 檢查項目 | 記錄結果 | 量測版本 | 依據 |
| :--- | :--- | :--- | :--- |
| 核心吞吐量（解析器、網格和捲動記錄；不含 PTY 和算繪） | **317.3 MiB/s**，原為 137.2 | 1.2 對比 1.1 | [Performance §5.14](../../PERFORMANCE.md#514-scrolling-without-per-line-screen-allocation-281-283) |
| 解析器 + 網格吞吐量 | **355.9 MiB/s**，原為 158.0 | 1.2 對比 1.1 | 同上 |
| 捲動記錄記憶體，10 萬行 × 120 欄 | **11.4 MiB**，原為 185 | 1.2 對比 1.1 | [Performance §5.6](../../PERFORMANCE.md#56-numbers-by-release) |
| 區域捲動，每格畫面 CPU，p50 | **0.026 ms**，原為 0.130 | 1.2 對比 1.1 | [Performance §5.14](../../PERFORMANCE.md#514-scrolling-without-per-line-screen-allocation-281-283) |
| 畫面 CPU，120 × 40 完整重建，Release | **0.37–0.39 ms** | 1.2 | [Performance §5.17](../../PERFORMANCE.md#517-full-screen-without-the-compositor-285-2026-10-13) |
| 按鍵到上螢幕，全螢幕、單一窗格、60 Hz、真人打字 | p50 **49.1–50.8 ms**，p99 82.9–84.2 ms（原 p50 為 64–68 ms） | 1.2 | [Performance §5.17](../../PERFORMANCE.md#517-full-screen-without-the-compositor-285-2026-10-13) |
| 閒置 CPU，Release，20 秒 | 0.05% | **1.0.0**（2026-09-18）；1.2 的閒置喚醒最佳化之後未重測 | [Performance](../../PERFORMANCE.md) |
| esctest2 | 通過 131，已知問題 334，失敗 102；共 567 | **1.1.5**（2026-10-07） | [原始結果](https://github.com/noah-qin/Corta/blob/f632d5918653cc2feee28fe1baa0c0fd01e93c0e/docs/esctest/2026-10-07-results.txt) |

量測機器為 Apple M5 MacBook Air（macOS 27.0.1）；1.2 的各列測於 2026-10-09 至 2026-10-13，
每組前後對比都在同一台機器、同一套工具鏈上完成。[Performance](../../PERFORMANCE.md)（英文）
中標有日期的章節記錄了量測條件、每一次執行，以及一個數字不能說明什麼。有時被引用的 esctest2
82.0% 把通過數**加上已知問題**一起算了，並不是通過率；如何解讀見
[Conformance](../../CONFORMANCE.md)（英文）。

已知的侷限包括：視窗模式下按鍵到上螢幕的延遲高於一格畫面的目標（全螢幕單一窗格最接近）、VT 相容性尚不完整、
內建 shell 整合只支援 zsh、bash 和 fish，以及 Kitty 圖形協定只支援直接傳輸。
詳見[侷限說明](../../FEATURES.md#known-limits)（英文）。

## 從哪裡開始

| 我想… | 從這裡開始 |
| :--- | :--- |
| 了解每個功能以及它在哪裡 | [使用者指南](USER-GUIDE.md) |
| 設定 Corta | [Configuration](../../CONFIGURATION.md)（英文） |
| 弄清楚某個功能或侷限 | [Features](../../FEATURES.md)（英文） |
| 排查問題 | [疑難排解](TROUBLESHOOTING.md) |
| 從 iTerm2、Ghostty 或 Terminal.app 轉換過來 | [從其他終端機轉換](USER-GUIDE.md#coming-from-another-terminal) |
| 看看有什麼計畫，或者提個建議 | [Open issues](https://github.com/noah-qin/Corta/issues) · [Discussions → Ideas](https://github.com/noah-qin/Corta/discussions/categories/ideas) |
| 找點事情做 | [Good first issues](https://github.com/noah-qin/Corta/labels/good%20first%20issue) · [Help wanted](https://github.com/noah-qin/Corta/labels/help%20wanted) |
| 第一次貢獻 | [Contributing](../../../CONTRIBUTING.md)（英文） |
| 執行或新增測試 | [Testing](../../TESTING.md)（英文） |
| 讀懂程式碼 | [Architecture](../../DESIGN.md) · [Core API](../../../CortaTerminal/Sources/CortaTerminal/CortaTerminal.docc/CortaTerminal.md)（英文） |
| 閱讀完整文件 | [文件索引](../../README.md)（英文） |

## 參與

歡迎提交錯誤重現步驟、文件、翻譯、無障礙測試和程式碼。可以從
[good first issue](https://github.com/noah-qin/Corta/labels/good%20first%20issue)
或 [help wanted](https://github.com/noah-qin/Corta/labels/help%20wanted) 開始，
環境建置和審查要求見 [CONTRIBUTING.md](../../../CONTRIBUTING.md)。社群參與遵循
[行為準則](../../../CODE_OF_CONDUCT.md)。

試用後換回了原來的終端機？這也很值得聽：
[Went back 表單](https://github.com/noah-qin/Corta/issues/new?template=went_back.yml)
不需要重現步驟，「就是感覺不對」也是可以接受的回答。

安全漏洞請透過[私密安全管道](../../../SECURITY.md)回報。
想和其他使用者及維護者聊天，歡迎加入 [Discord](https://discord.gg/QNdWfdwr7j)。
希望答案能被別人搜尋到的使用問題，請發到 [Discussions → Q&A](https://github.com/noah-qin/Corta/discussions/categories/q-a)，中文提問同樣歡迎；
想分享主題或設定，請發到 [Show and tell](https://github.com/noah-qin/Corta/discussions/categories/show-and-tell)。
其他問題請[提交 issue](https://github.com/noah-qin/Corta/issues/new/choose)。

### 贊助

Corta 由一個人公開開發和維護。如果它已經成為你日常的一部分，贊助能讓它繼續前進——多少都有幫助。

<a href="https://github.com/sponsors/noah-qin"><img src="https://img.shields.io/badge/Sponsor_noah--qin_on_GitHub-%E2%9D%A4-db61a2?style=for-the-badge&logo=githubsponsors&logoColor=white" alt="在 GitHub 上贊助 noah-qin"></a>

### 貢獻者

感謝每一位為 Corta 做出貢獻的人。

<a href="https://github.com/noah-qin"><img src="https://github.com/noah-qin.png?size=96" width="48" height="48" alt="noah-qin" title="noah-qin"></a>
<a href="https://github.com/FrankChen-CLC"><img src="https://github.com/FrankChen-CLC.png?size=96" width="48" height="48" alt="FrankChen-CLC" title="FrankChen-CLC"></a>

## 授權與識別

原始碼採用 [Apache 2.0](../../../LICENSE) 授權。Corta 名稱、穿山甲吉祥物和 App 圖像另有條款，見
[NOTICE](../../../NOTICE)。穿山甲蜷起的身體組成字母 C，青色的尾巴是終端機游標。
[品牌素材](../../brand/README.md)包括吉祥物和社群預覽圖。
