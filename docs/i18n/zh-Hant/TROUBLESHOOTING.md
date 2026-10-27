# 疑難排解

[文件索引（英文）](../../README.md) · [專案概覽](README.md)

🇺🇸 [English](../../TROUBLESHOOTING.md) · 🇨🇳 [简体中文](../zh-CN/TROUBLESHOOTING.md) · 🇭🇰 [繁體中文](TROUBLESHOOTING.md) · 🇯🇵 [日本語](../ja/TROUBLESHOOTING.md) · 🇰🇷 [한국어](../ko/TROUBLESHOOTING.md) · 🇩🇪 [Deutsch](../de/TROUBLESHOOTING.md) · 🇫🇷 [Français](../fr/TROUBLESHOOTING.md) · 🇪🇸 [Español](../es/TROUBLESHOOTING.md) · 🇧🇷 [Português](../pt-BR/TROUBLESHOOTING.md)

> 本文譯自英文版 [TROUBLESHOOTING.md](../../TROUBLESHOOTING.md)，對應提交
> [`68169b9`](https://github.com/noah-qin/Corta/blob/68169b98164d5780f2959377a810eaf1be55e524/docs/TROUBLESHOOTING.md)。
> 此後英文版如有更新，或兩者有出入，以英文版為準。macOS 的提示文字以英文原文為準，中文為對照譯文。

Corta 裝不起來、打不開，或者做了你以前的終端機不會做的事時，該怎麼辦。每一條都說明你會看到什麼、原因是什麼、
如何修復——最後一節說明如果都沒用，如何乾淨地回到你原來的終端機，因為一份「我換回去了，原因是這樣」的報告
是你能提交的最有用的東西之一。

如果這裡的某一條有誤或缺漏，請用 **Installation blocker** 或 **Went back to my old terminal** 範本提交 issue：
<https://github.com/noah-qin/Corta/issues/new/choose>。

---

<a id="installing"></a>

## 安裝

### 「無法打開 Corta，因為 Apple 無法檢查其是否包含惡意軟體」（"Corta can't be opened because Apple cannot check it for malicious software"）

正式版本都經過 Developer ID 簽署和公證，從原始碼建置的版本可能沒有。對於下載的正式版本，
請先驗證其總和檢查碼，並做下面的映像檔和 App 檢查，然後連同版本號回報確切的提示訊息。

### 「Corta 已損毀，無法打開」（"Corta is damaged and can't be opened"）

磁碟映像檔可能不完整、被改動過，或者被 macOS 的簽章驗證拒絕。先用旁邊一同發布的 `.sha256` 檔案驗證它。
把兩個檔案都放在下載資料夾裡，並把 `x.y.z` 換成你下載的版本號：

```sh
shasum -a 256 -c Corta-x.y.z.dmg.sha256
```

不符合就重新下載。每個發布套件在發布前都會與它的檢查碼檔案核對（`corta-release-check`），所以不符合就是停下來重新下載的理由。
如果檢查碼符合，再檢查映像檔和複製出來的 App。在所有命令中把 `x.y.z` 換成下載的版本號，並在下載資料夾中執行：

```sh
spctl -a -t open --context context:primary-signature -v Corta-x.y.z.dmg
xcrun stapler validate Corta-x.y.z.dmg
spctl --assess --type exec /Applications/Corta.app
xcrun stapler validate /Applications/Corta.app
```

回報時請附上版本號、macOS 的錯誤訊息和這些結果。不要為了測試正式版本而繞過 Gatekeeper。
1.1.8 及更早的版本保留原本的 ZIP 檢查碼；請使用那個版本中的檔名。

### Corta 提議把自己移到 /Applications

Corta 是從 `~/Downloads` 或其他資料夾啟動的。它在哪裡都能執行；`/Applications` 是 Sparkle 更新和 Spotlight 期望它所在的位置。
選擇「暫不」後它就不再詢問——也可以在 `~/.config/corta/config` 中設定 `suggest-applications-folder = false`。

直接從磁碟映像檔打開時，macOS 會從一個暫時的唯讀位置執行 Corta，所以它無法移動自己；它會請你把它拖進「應用程式」。
如果那裡已經有較新版本的 Corta，它會提議打開那個版本，而不是用較舊的副本取代它。

### Dock 裡有兩個 Corta 圖像

其中一個是開發版。Finder 稱它為 **Corta Dev**，選單列稱它為 **CortaDev**，它的圖像背景是橘色而不是藍色，
它的 bundle identifier 是 `dev.noahqin.Corta.dev`。它把設定和狀態儲存在 `~/Library/Application Support/Corta Dev/`，
從不使用 `~/.config/corta/config` 或 `~/Library/Application Support/Corta/`，而且它沒有「檢查更新…」選單項目——
所以無論兩者以什麼順序出現，藍色圖像的那個就是已安裝的 Corta。結束或刪除其中一個不會影響另一個。
只有從原始碼建置 Corta 的人才會有開發版（`CONTRIBUTING.md`，「Developing Corta in Corta」）。

### 「此版本的 Corta 需要 macOS 26.0 或以上版本」（"This version of Corta requires macOS 26.0 or later"）

Corta 的部署目標是 macOS 26.0，並使用該版本的 Metal 4 和 Core Text API。沒有面向更早系統的版本，
專案也不打算提供（`DESIGN.md` §6）。

### 「你無法打開應用程式“Corta”，因為此類型的 Mac 不支援此應用程式」（"You can't open the application "Corta" because it is not supported on this type of Mac"）

從 1.1.0 起，Corta 只為 Apple 晶片建置——即配備 M1 或更新晶片的 Mac（`DECISIONS.md` D21）。Intel Mac 無法執行它。
**1.0.1** 是支援 Intel Mac 的最後一個版本，仍可在
[1.0.1 發布頁面](https://github.com/noah-qin/Corta/releases/tag/v1.0.1)下載：下載 `Corta-1.0.1.zip`，
驗證後取代 `/Applications` 中的副本。已經在執行 1.0.x 的 Intel Mac 不會透過 **檢查更新…** 收到 1.1.0，
所以會繼續正常使用；只有手動下載並打開了較新的壓縮檔，才會出現這條提示。

要查看 Mac 用的是哪種晶片，請選擇蘋果選單 ▸ 關於這台 Mac：Apple 晶片的 Mac 會有一行 *晶片*，寫著 Apple 晶片（M1、M2⋯⋯）；
Intel 的 Mac 則有一行 *處理器*，寫著 Intel 的型號。

---

<a id="starting"></a>

## 啟動

### 視窗打開後一片空白，或者打開後又關閉

從 Terminal.app 啟動，看看原因：

```sh
/Applications/Corta.app/Contents/MacOS/Corta
```

無法啟動 shell 的窗格會顯示帶 **重試** 按鈕的失敗畫面，而不是空白畫布；如果你看到的是沒有失敗畫面的空白畫布，
那是算繪錯誤，值得附上主控台輸出回報。

### shell 不是我預期的那個，或者沒有 PATH

Corta 以登入 shell（`-l`）的方式啟動它被啟動時所在環境中的 `$SHELL`（沒有則用 `/bin/zsh`），
所以 `~/.zprofile` 和 `~/.zshrc` 都會執行。`$SHELL` 指向的程式已不存在時，會依序退回到 `/bin/zsh`、`/bin/sh`，
並在窗格中提示用了哪一個。如果在 Terminal.app 中能用的命令在 Corta 中「找不到」，請檢查啟動 *GUI App* 的環境中
`SHELL` 是什麼（`launchctl getenv SHELL`）：那裡設定的值會作用於所有 App，並且在設定它的工作階段結束後依然存在。
執行 `launchctl unsetenv SHELL` 後重新啟動。

**預設集**（Shell ▸ 使用預設集新增窗格）或設定檔中的 `preset.<name>.shell` 可以依窗格覆寫這一設定。

### Corta 還原了昨天的視窗，而我並不想要

在 `~/.config/corta/config` 中設定 `restore-windows = false`，或在 設定 ▸ 一般 中取消勾選。
導致 App 當機的還原不會再次嘗試：儲存的版面會被捨棄，並打開一個新視窗。

### 設定提示無法讀取設定檔

`~/.config/corta/config` 存在，但不是 UTF-8 文字——通常是編輯器以其他編碼儲存了某個位元組——或者你沒有讀取權限。
Corta 會保留已有的設定，並拒絕寫入這個檔案，因為寫入會取代其中的全部內容。請把檔案重新儲存為 UTF-8
（或刪掉有問題的那一行）；Corta 下次讀取時就會生效。Shell 整合對它無法讀取的 rc 檔案也是這樣處理：回報問題，不去動它。

---

<a id="typing-and-rendering"></a>

## 輸入和算繪

### 清除畫面後只剩游標，沒有提示符號

如果 ⌘K 會擦掉正在等待的提示符號，請更新 Corta。有 shell 整合和就緒的提示符號結束標記時，清除畫面現在會保留顯示的提示符號
和尚未送出的輸入，包括編輯游標。它不傳送 Return、Control-L 或任何其他輸入。對於沒有提示符號標記的 shell，請開啟 shell 整合；
標準的本機 zsh 工作階段會隨內建的建議功能自動載入它。如果 shell 設定了 Control-L 重繪，它仍然是另一種選擇。
備用螢幕程式，以及提示符號已捲入歷史的多行編輯器，會被刻意保持原樣。

### 目錄補全在以 `/` 結尾的資料夾之後就停了

只有子目錄才是候選；只包含檔案的目錄沒有下一層目錄補全。輸入子資料夾名稱的一部分，或在候選可見時再按一次 Tab。
Tab 只填入路徑而不執行；Return 才執行 `cd`。隱藏資料夾需要點號前綴。如果某個已知的子資料夾沒有出現，請檢查對該目錄的存取權限，
並在關閉 `directory-completion` 後與 shell 的原生補全比較。如果差異仍然存在，請回報具體的路徑形式和 shell。

### 命令歷史在遠離終端機的地方打開

在目前版本的 Corta 中關閉並重新打開它。它會在呼叫它的視窗上方置中打開，並限制在該顯示器的可用範圍內；
不會放在整個螢幕的中央。關於 Corta 是刻意的例外：它像其他 App 的「關於」視窗一樣，在顯示器中央打開。
已經打開的視窗保持你選擇的位置。

### 在 Claude Code 的斜線命令選單中按 Tab 沒有反應

已在 1.0.0 中修正（B02）；v0.1.1 有這個錯誤。如果在較新的版本上再次出現，請附上 Claude Code 的版本號回報：
修正的關鍵在於選字視窗發出的 `insertTab(_:)` 如何到達子程序，新的選字介面可能會走不同的路徑。

### ⌥ 輸入的是 `é`、`ø`、`–`，而不是充當 Meta

這是 macOS 的預設行為，Corta 保留了它。設定 `option-as-meta = true`，⌥ 就會像 PC 鍵盤的 Alt 一樣送出 `ESC` + 按鍵。
特殊鍵（方向鍵、功能鍵）無論如何都會以 xterm 修飾鍵的形式帶上 ⌥。

### 透過 ssh 時顏色或 `TERM` 看起來不對

Corta 刻意宣告 `TERM=xterm-256color`（`docs/DECISIONS.md` D08）。使用相同的 TERM 值並不代表完全相容 xterm。
用 `printf '%s\n' "$TERM"` 檢查遠端環境，並對比一個最小重現；[Conformance](../../CONFORMANCE.md#42-external-suites)（英文）
記錄了支援的序列和尚存的失敗項目。

### 某個字符比旁邊的字符小

所選字型缺少的字元來自蘋方-簡或 Apple Color Emoji。遞補字符可能會被縮放以保持在其終端機字元格內，
因此看起來的大小可能與相鄰字符不同。在 **設定 ▸ 外觀** 中調整字級並對比預覽。如果某個字符被裁切或沒有對齊，
請回報它的文字、字型、字級、顯示器縮放比例並附上截圖。

### 繪製的字型不是我設定的那個

`font-family` 指定的是字型家族，而不是某個字樣（寫 `JetBrains Mono`，不是 `JetBrainsMono-Regular`）。
只有當它已安裝，且其一般、粗體和斜體字樣在可列印 ASCII 範圍內寬度一致時，Corta 才會使用它；
否則會繪製系統等寬字體，並在 **設定 ▸ 外觀** 中顯示「字型狀態」一列，說明哪項檢查沒有通過。
Corta 執行期間安裝的字型會立即出現在清單中；「重試」會重新檢查設定的字型。

中文、日文或韓文的字型與 **中日韓字型**（`font-family-cjk`）中選擇的不同，表示該字型沒有安裝或沒有中日韓字元；
選單下方的一行會說明這一點，並改用系統語言的字型繪製。所選字型缺少的字元也來自系統語言的字型。
關閉 **缺字時使用其他字型** 時，中日韓字型不會被使用。

### `kitten icat` 的圖片不顯示，或顯示在錯誤的位置

Corta 實作了 Kitty 圖形協定的直接（頻內）傳輸，支援 RGB、RGBA 和 PNG。基於檔案的傳輸（`t=f`、`t=t`、`t=s`）、
動畫影格和 Unicode 預留位置放置都沒有實作，基於檔案的傳輸也不會實作：遠端資料流指定一個要讀取的本機檔案，
正是威脅模型所拒絕的（`SECURITY.md` §1）。試試 `kitten icat --transfer-mode=stream picture.png`，明確要求直接傳輸。
圖片必須在每邊 8192 像素、總計 1600 萬像素的限制之內；無效或過大的圖片會被拒絕。

### 空的 Return 畫出了綠色或紅色的命令標記

空的 Return 不是命令，目前的整合掛鉤不會記錄它。舊版 Corta 安裝的啟動檔案區塊仍可能回報它：
打開 **設定 ▸ 終端機 ▸ Shell 整合**，選擇 **更新**，然後打開一個新 shell。已經打開的 shell 在重新啟動之前會保留舊函式，
已經畫出的標記也會保留。只有啟動檔案中帶標記的 Corta 區塊會被更新。使用自動掛鉤的標準本機 zsh 工作階段
在新 shell 啟動時就會使用內建的版本。

---

<a id="behaviour-that-differs-from-other-terminals"></a>

## 與其他終端機不同的行為

### 一選完就複製了

`copy-on-select` 預設開啟，並會在窗格角落顯示一個標籤確認。設為 `false` 則只用 ⌘C 複製。

### 程式說已經複製到剪貼簿，但什麼也沒複製

OSC 52 *寫入* 預設關閉：否則任何程式輸出都可以往剪貼簿裡放東西，等你之後貼上。`allow-clipboard-write = true`
會開啟它，`tmux` 和遠端 `ssh` 工作階段需要的就是這個。*讀取* 方向在任何設定下都不存在。

### 關閉視窗時問我是否確定

那個視窗裡仍有前景工作。`confirm-close = false` 會在所有地方關閉這個詢問。

### 快捷終端機的熱鍵沒有反應

有三種可能，依序排查。`quick-terminal` 為 `false`（預設）：在你設為 `true` 之前不會佔用任何按鍵。
另一個 App 已經佔用了這個按鍵：設定 ▸ 快捷終端機 會提示，`quick-terminal-key` 可以換成任何其他至少帶一個修飾鍵的組合。
或者這個按鍵是 Corta 無法對應到按鍵位置的（`é`、兩個字元的寫法）：設定檔中的那一行會原樣保留，並使用預設值。
無論如何，檢視 ▸ 快捷終端機 和捷徑中的 *切換快捷終端機* 動作都能打開面板。

### 遠端窗格的標記顯示「遠端：主機未知」，或者本機的 `tmux` 顯示「遠端？」

標記中的主機名稱來自遠端 shell 自己的 `OSC 7` 回報，或者——對於從連線面板打開的連線——來自你在那裡輸入的目標。
它從不從提示符號處輸入的 `ssh` 命令列中讀取主機（別名、`~/.ssh/config` 中的名稱和跳板機鏈都會讀錯），
也不從提示符號文字中讀取。兩者都沒有時，`ssh` 窗格會顯示 *主機未知*，這是實話。要顯示主機，
請把 設定 ▸ 終端機 中的 shell 整合區塊也放進遠端機器的 `~/.zshrc`；它會發出標記讀取的 `OSC 7`。
前景執行 `tmux` 或 `screen` 時顯示 *遠端？*，因為它所連接的工作階段本身可能在另一台機器上，而這裡無從判斷——
這是不確定，不是指控。

### 瀏覽遠端檔案… 提示認證失敗，但窗格裡的 `ssh` 能用

SFTP 連線會在它的視窗上彈出對話框詢問密碼或金鑰密語；對話框被拒絕或取消，就會以這個錯誤結束。
檢查表單中的使用者和連接埠——別名自己的 `User` 和 `Port` 只在這些欄位為空時才生效——以及你選擇的金鑰（如果有）：
選中的金鑰是唯一提供的金鑰。如果沒有出現對話框，表示伺服器拒絕了 ssh 能嘗試的所有方式；
在終端機中用相同的使用者、連接埠和金鑰執行 `ssh -v` 可以看出是哪種。

### 瀏覽遠端檔案… 提示無法驗證主機金鑰

第一次見到的主機會在一個顯示指紋的對話框中請你信任它的金鑰。這個錯誤表示金鑰在你信任之後 *變了*——
伺服器重灌過，或者中間有人。在從 `~/.ssh/known_hosts` 中刪除舊的那一行（`ssh-keygen -R <host>`）之前，ssh 會拒絕連線；
請先詢問伺服器的管理員。

### 命令歷史顯示「（命令文字已不在回捲歷史中）」

命令的文字是從網格中復原的，不單獨儲存：一旦它的提示符號行捲出了 `scrollback-lines`，記錄會保留時間、狀態和目錄，
但文字已經沒了，也不再提供「填入」和「執行」。如果經常這樣，請調大 `scrollback-lines`。

### 無法捲回長時間執行的開頭

`scrollback-lines`（預設 10,000）是每個工作階段的上限，它計算的是 *實體* 列——一個 200 欄的行在 100 欄處換行就算兩列。
超過上限的舊輸出會在新輸出到來時被捨棄；頂部的提示條會顯示畫面回捲了多遠。可以調高上限（最多 1,000,000；
壓縮後的冷歷史佔用多少記憶體取決於文字和負載）。一個儲存的字元格在壓縮前是 16 位元組，這不是常駐記憶體的估算。
量測 100,000 行 120 欄的負載增加了大約 11 MiB 常駐記憶體；見
[Performance](../../PERFORMANCE.md#56-numbers-by-release)（英文）。需要保留超過上限的輸出，請匯出。

### 安全鍵盤輸入已開啟，但我的巨集工具仍然有效

標題列中的鎖頭表示它 *已生效*，而這只在 Corta 的終端機視窗是主視窗、且 Corta 是作用中的 App 時才成立。
在其他 App 中，以及設定視窗是主視窗時，按鍵會正常傳遞——這正是它的用意，也是指示器跟隨生效狀態而不是設定的原因。

### 網路裝載上缺少目錄代理圖像

Corta 在背景檢查回報的本機目錄。如果裝載很慢，或已有兩個檢查在等待，它就不顯示代理圖像，
以便輸出和鍵盤互動能繼續進行。請單獨檢查裝載；裝載恢復後切換目錄會發起新的檢查。

### 窗格在個人專屬資料夾而不是網路目錄中打開

新窗格或啟動時還原的視窗，只有在所請求的目錄能在很短的時限內回應時才會在那裡啟動。
停止回應的網路卷宗會被視為不存在，所以窗格會在個人專屬資料夾中打開，而不是讓 Corta 卡住。
在那裡 ⌘ 點按或游標停留在 `path:line` 參照上也適用同樣的時限：它不會作為連結提供。重新連接該卷宗，然後 `cd` 過去，
或在那裡打開新窗格。

### 遠端編輯在上傳提示後再次詢問

本機檔案在最初的提示所顯示的版本之後又改過了。請明確批准新的編輯。沒有遠端內容摘要的舊受管項目也需要做一次衝突決定。
即使檔案大小和時間戳記沒變，內容比較也能識別出遠端的改動。

### 遠端編輯的上傳等了很久之後再次詢問

連線卡住了。連線建立後，每個遠端編輯操作有 120 秒的時間完成；逾時後 Corta 會關閉連線並再次提供上傳。批准它即可透過新連線重試。
慢速連線上的超大檔案也可能達到這個時限：請改用 SFTP 瀏覽器複製它。

---

<a id="appearance-and-the-status-bar"></a>

## 外觀和狀態列

### 游標不閃爍

閃爍預設關閉：在 設定 ▸ 外觀 ▸ 游標 中打開 **游標閃爍**。窗格處於非作用中、隱藏或回捲狀態時會暫停閃爍。
終端機程式可以用 DECSCUSR 為自己更改形狀或閃爍；重置終端機會恢復設定的樣式。

### 狀態列沒有顯示網路速率，或顯示的不對

速率需要兩次取樣，所以開啟狀態列後請等幾秒鐘。`auto` 量測一個主要介面；當 VPN 或多張網路卡導致選錯介面時，
請在 設定 ▸ 終端機 中輸入介面名稱。明確指定但不存在的介面不會顯示速率。狀態列始終回報本機 Mac，在 SSH 窗格中也是如此；
熱狀態等級是 macOS 的分類，不是溫度。較窄的視窗可能會截斷狀態列；按一下它即可看到所有已選的數值。

### 主題編輯器無法儲存

無效的十六進位顏色會讓「儲存」無法使用。如果在編輯器打開期間，設定檔中的這個自訂主題被修改了，
請先關閉再重新打開編輯器，然後儲存，以免覆蓋那次修改。

### 介面語言不對

Corta 跟隨 macOS 為它選擇的語言（系統設定 ▸ 一般 ▸ 語言與地區 ▸ 應用程式）。修改後請重新啟動 Corta。
數字格式跟隨地區，可能與語言不同。

---

<a id="updating"></a>

## 更新

### 檢查更新… 什麼也沒找到

Corta 比較的是 **建置編號**，而不是版本字串，比較對象是 `main` 分支上的 `appcast.xml`。
已打標籤、已起草但尚未發布的版本不在更新來源中；發布後，發布流程會簽署並驗證更新來源、打開拉取請求、等待 CI，
然後 squash 合併或啟用自動合併。更新來源檢查失敗或受阻可能會延遲送達，所以在版本出現在 GitHub 之後請稍等一會兒。
`update-auto-check = false` 只會停用每天的背景檢查；選單項目始終可用。

---

<a id="going-back-to-your-old-terminal"></a>

## 回到原來的終端機

刪除 Corta 的檔案前請先結束 Corta。刪除 App 資料前，請檢查受管的遠端編輯副本中有沒有未儲存的工作：

1. **Shell 整合**，如果你是從 設定 ▸ 終端機 安裝的：在那裡移除它，或刪除 shell 啟動檔案中
   `# >>> Corta shell integration >>>` 和 `# <<< Corta shell integration <<<` 之間的區塊——
   `~/.zshrc`；bash 為 `~/.bashrc` 和 `~/.bash_profile`（或 `~/.bash_login` / `~/.profile`）；
   或 `~/.config/fish/config.fish`。該檔案中的其他內容都不屬於 Corta。
2. **安全鍵盤輸入** 會在 Corta 結束時自行釋放。如果 Corta 在某個視窗為主視窗時被強制結束，
   之後在其他地方似乎無法輸入，請啟動並結束 Corta 一次；結束時計數會恢復平衡。
3. **設定和狀態**：`~/.config/corta/`（設定檔）和 `~/Library/Application Support/Corta/`
   （視窗版面、目錄歷史和受管的遠端編輯副本）。請先保留你仍需要的本機編輯，再刪除它們。
   算繪器還會在 `~/Library/Caches/dev.noahqin.Corta/` 下保存可丟棄的快取檔案；這些可以刪除。
4. 把 `Corta.app` 移到垃圾桶。

然後，如果你願意，請用 [**Went back to my old terminal**](https://github.com/noah-qin/Corta/issues/new?template=went_back.yml)
表單提交一個 issue，說說是什麼讓你換回去的。它不需要重現步驟。缺少的功能、算繪錯誤、「就是感覺比較慢」，
都是專案可以據此行動的回答。
