# 倉頡星 CangjieX

**以 Swift + Rust 打造的原生 macOS 倉頡輸入法。**

倉頡星保留倉頡與簡易的輸入習慣，以 Swift 負責 macOS 系統整合與原生介面，Rust 負責查表、輸入狀態與候選排序。V2 提供 Apple Silicon 與 Intel 的 Universal 安裝包，支援 macOS 11 或更新版本。

碼表及相容行為源自 Yahoo! KeyKey／OpenVanilla；新版使用獨立的設定與學習記錄，可與舊版並存。

[GitHub Releases](https://github.com/geekstek/CangjieX/releases) · [安裝說明](#下載與安裝) · [開發與建置](#開發與建置) · [協作規範](AGENTS.md)

## 為什麼使用 Swift + Rust？

| 設計 | 帶來的好處 |
| --- | --- |
| **Swift 原生系統整合** | 透過 AppKit 與 InputMethodKit 實作輸入法、候選窗及偏好設定，使用 macOS 原生控制項與淺深色外觀。 |
| **Rust 輸入核心** | 查表、組字、選字、排序與文字轉換集中在核心，便於測試；型別與所有權檢查有助減少記憶體管理錯誤。 |
| **原生編譯、直接呼叫** | Swift 與 Rust 在同一輸入法程序內透過 C 介面呼叫，輸入核心不需要另啟腳本引擎或連接雲端服務。 |
| **介面與核心分工** | 調整 macOS 視窗不必改動查表規則，修改輸入行為也能先在獨立核心驗證，讓維護與升級範圍更清楚。 |
| **可重用的跨平台核心** | Rust 核心不依賴 AppKit／InputMethodKit，為日後其他平台重用引擎打下基礎；目前提供的輸入法產品仍只有 macOS 版。 |

Rust 核心目前不含第三方 crate 依賴。原生編譯與共用字典結構讓執行路徑保持精簡；實際輸入延遲、CPU 與記憶體是否優於舊版，仍需以效能量測確認。

## 功能

| 功能 | 說明 |
| --- | --- |
| **倉頡輸入** | 最多五個字根，支援即時候選、滿碼確認、退格、取消，以及 `?`／`*` 萬用字元查詢。 |
| **簡易輸入** | 最多兩個字根，使用獨立簡易碼表；輸入設定與學習記錄和倉頡分開保存。 |
| **依選字習慣排序** | 依同一編碼的累計選字次數調整候選順序，重新啟用或重啟後保留。 |
| **聯想詞提示** | 選字後提供聯想候選，可用 Shift＋數字鍵或滑鼠選詞。 |
| **繁體轉簡體** | 候選保持繁體顯示，在文字上屏時套用繁轉簡。 |
| **全形英數字與標點** | 提供全形輸出開關及半角標點設定。 |
| **注音文校正** | 對輸入法收到的注音文顯示替換候選，取消時保留原文。 |
| **原生候選窗** | 跟隨系統淺深色外觀，支援鍵盤／滑鼠選字、翻頁及候選字大小設定。 |
| **符號與偏好設定** | 可開啟 macOS 系統符號面板，並在偏好設定調整輸入、輸出、候選及提示音。 |
| **本機處理** | 查表、轉換與排序學習均在本機完成，不需要雲端輸入服務。 |
| **修復及解除安裝（V2.0.1）** | 在「關於倉頡星」開啟解除安裝確認，可選擇清除設定及學習記錄；另附原生註冊與快取修復工具。 |
| **升級啟用核對（V2.0.2）** | 原生安裝器先檢查安全狀態，安裝後重啟並核對執行中版本；無法確認時明確要求重新登入。 |
| **Shift 英文大小寫（V2.0.3）** | 按住 Shift 輸入英文時，Caps Lock 關閉為小寫、開啟為大寫；適用於倉頡、簡易及全形英文，候選窗開啟時亦適用。 |
| **診斷與修復（V2.0.4）** | 保存有大小上限的本機狀態記錄，匯出故障報告，並在安全檢查後刷新註冊與選單；必要時僅重啟一次。 |

### 候選排序怎樣學習？

在「偏好設定 → 輸入」啟用 **依選字習慣調整候選順序**。選字後，該編碼的選字次數會累加，並影響往後的候選排列。

- 按累計次數排序，因此選一次不一定立即排到第一位。
- 關閉後恢復碼表順序，不會刪除已保存的學習記錄；重新開啟後可繼續使用。
- 倉頡與簡易分開保存學習記錄。簡易的原版預設為關閉學習，可在簡易模式的輸入設定開啟；既有明確設定會保留。

排序更新、重新啟動保留、停用及重新啟用的流程，已用隔離資料驗證。

### 常用操作

| 操作 | 按鍵 |
| --- | --- |
| 選擇普通候選 | 數字鍵，或按 Return 選擇高亮項；編號依選字設定顯示。 |
| 空格 | 依設定與候選狀態，確認選字或翻頁。 |
| 選擇聯想詞 | Shift＋1–9，或直接點擊詞條。 |
| 切換全形英數字 | Shift＋Command＋Space |
| 切換繁體轉簡體 | Control＋Command＋G |
| 開啟系統符號面板 | Control＋Command＋`.` |

注音文校正依照原版規則，一次處理收到文字中的第一個可校正字元；它不會掃描已上屏的文件，也不攔截一般剪貼簿貼上。校正候選中按 Escape 會保留原文。

## 下載與安裝

V2.0.2 新增原生安裝器：開啟 `.dmg` 內的「倉頡星安裝器」，先完成組字、切換到 ABC 並結束系統設定，再按「安裝並啟用」。安裝期間保持 ABC；只有實際執行版本、構建識別及輸入源啟用都通過核對，才會顯示完成。設定、詞頻、已安裝的 V1 舊版及其他輸入法會保留。

手動 `.pkg` 僅寫入檔案，會明確要求登出並重新登入；看到磁碟版本更新，不代表正在執行的程序已換新。V2.0.0／V2.0.1 的安裝後流程同樣需要重新登入。

**[倉頡星 V2.0.4 已發布](https://github.com/geekstek/CangjieX/releases/tag/v2.0.4)。** 推薦[下載 Universal 原生安裝器（.dmg）](https://github.com/geekstek/CangjieX/releases/download/v2.0.4/CangjieX-2.0.4-universal.dmg)，適用於 Apple Silicon 與 Intel；亦提供[手動安裝包（.pkg，安裝後須重新登入）](https://github.com/geekstek/CangjieX/releases/download/v2.0.4/CangjieX-2.0.4-universal.pkg)。Release 附有各自的 SHA256 校驗檔及建置資訊，公開下載檔案已核對摘要、版本及構建提交。先前 V2 與 V1.x Release 保留供回退。

1. 開啟 `.dmg` 內的「倉頡星安裝器」。完成組字、切換 ABC，並結束系統設定。
2. 按「安裝並啟用」，安裝期間保持 ABC。只更新目前使用者的 V2，保留設定與詞頻。
3. 看到「已完成安裝並啟用新版」才算完成。若顯示尚未完成，請依提示保存工作後登出並重新登入；手動 `.pkg` 一律需要重新登入。
4. 若重新登入後尚未加入輸入源，開啟「系統設定 → 鍵盤 → 文字輸入 → 編輯 → ＋ → 繁體中文」，加入 **倉頡星**。已加入者不需重複加入。

安裝包未以 Developer ID 簽署，也未經 Apple 公證。若 macOS 阻擋，請確認下載來源及 SHA256，再到「系統設定 → 隱私權與安全性」使用「仍要打開」；不需要停用 Gatekeeper 或 SIP。

### 設定與舊版保護

新版顯示名稱統一為 **倉頡星**。內部保留早期測試版的獨立識別與儲存位置，讓既有設定可繼續使用，並避免覆蓋舊版。

| 內容 | 位置 |
| --- | --- |
| 新版輸入法 | `~/Library/Input Methods/CangjieXPreview.app` |
| 新版設定 | `~/Library/Application Support/CangjieX Preview/settings.json` |
| 倉頡學習記錄 | `~/Library/Application Support/CangjieX Preview/frequency.json` |
| 簡易學習記錄 | `~/Library/Application Support/CangjieX Preview/simplex-frequency.json` |

舊版設定以唯讀方式載入，動態詞頻首次啟用時可唯讀匯入舊記錄；後續修改只寫入新版自己的檔案。V2 安裝包只允許目前使用者目錄，不含安裝腳本，不終止舊版程序，也不替換 `/Library/Input Methods/CangjieX.app`。

舊版與新版可能同時顯示為「倉頡星」，可從「關於倉頡星」確認是否為 V2.x。

### 升級、修復及移除

**V2.0.1 新增以下功能，V2.0.0 安裝包維持原樣。** 升級後請先保存工作、登出再登入，使系統重新載入輸入法名稱。

解除安裝可直接從右上角「倉頡星 → 關於倉頡星 → 解除安裝倉頡星…」開啟。先結束「系統設定」（Command＋Q）。確認視窗預設勾選一併刪除設定與學習記錄；V2.0.4 起亦包含診斷記錄，取消勾選可保留資料。Return、Escape 與「取消」都不會刪除，必須明確按下「解除安裝」。

獨立卸載程序會切換到 ABC、停用輸入源、移除 V2 app 與收據、清理所屬記錄及快取，再以新程序檢查結果。程式自刪後仍會顯示完成或錯誤訊息。若系統仍保留登入階段的目錄，會要求登出再登入，不會提前宣稱快取已全部消失。已安裝的 V1 舊版及其他輸入法會保留。

app 也附帶原生維護工具，不需要另外安裝 Swift／Rust 工具鏈。使用終端機時先完成組字並切換到 ABC，再結束系統設定：

```sh
# 查詢已安裝程式與系統回報的名稱；不修改設定。
"$HOME/Library/Input Methods/CangjieXPreview.app/Contents/MacOS/CangjieXMaintenance" status

# 修復升級後的舊名稱、舊 Preview 註冊及鍵盤設定的空白項目。
"$HOME/Library/Input Methods/CangjieXPreview.app/Contents/MacOS/CangjieXMaintenance" repair

# V2.0.2 起：切換 ABC 並結束系統設定後，重啟並核對實際執行版本。
"$HOME/Library/Input Methods/CangjieXPreview.app/Contents/MacOS/CangjieXMaintenance" activate

# 移除目前使用者的 V2 輸入法及安裝記錄，保留設定與詞頻。
"$HOME/Library/Input Methods/CangjieXPreview.app/Contents/MacOS/CangjieXMaintenance" uninstall

# 完整移除新版設定與學習記錄（無法復原）。
"$HOME/Library/Input Methods/CangjieXPreview.app/Contents/MacOS/CangjieXMaintenance" uninstall --delete-data
```

維護工具會保護尚未完成的輸入、其他輸入源及已安裝的 V1 舊版。修復只清理失效的舊識別記錄，重建鍵盤設定自己的輸入法目錄快取，並刷新右上角選單；不重置整份鍵盤偏好。終端機的 `uninstall` 預設保留本節列出的新版資料，方便重新安裝後繼續使用。

完成後須實際確認三處：已加入清單沒有空白列；「＋ → Chinese, Traditional」可加入清單沒有空白或舊 Preview；右上角名稱為「倉頡星」（卸載後則應消失）。API 查到正確名稱，不能代替畫面驗證；若系統仍保留舊快取，請保存工作後登出並重新登入。

### V2.0.4 診斷與修復

「關於倉頡星 → 診斷與修復…」會開啟獨立工具。輸入法在選單中呈灰色時，可直接從終端機啟動，不需要先選取倉頡星：

```sh
# 開啟診斷視窗；匯出記錄不需要切換輸入源。
"$HOME/Library/Input Methods/CangjieXPreview.app/Contents/MacOS/CangjieXMaintenance" diagnostics-dialog

# 直接匯出診斷，輸出檔案位置。
"$HOME/Library/Input Methods/CangjieXPreview.app/Contents/MacOS/CangjieXMaintenance" diagnose

# 先完成文字、切 ABC、離開密碼欄位並結束系統設定，再修復。
"$HOME/Library/Input Methods/CangjieXPreview.app/Contents/MacOS/CangjieXMaintenance" recover
```

記錄保存在 `~/Library/Logs/io.github.geekstek.inputmethod.CangjieXPreview/`：事件檔最多四段，每段 256 KB；匯出報告放在 `reports/`，僅保留最近三份，需要長期留存請自行複製。目錄及檔案僅限目前使用者存取，不會自動上傳。

記錄內容包括版本／建置識別、PID、啟用與停用、輸入源狀態、喚醒／登入階段、引擎錯誤代碼、慢處理及主執行緒逾時。每分鐘記錄狀態，每五分鐘擷取經過濾的系統連線訊號；報告另包含系統異常報告的時間與類型摘要。**不記錄按鍵、字根、輸入文字、候選、詞頻、剪貼簿、視窗標題或完整系統／當機報告。** 系統端點事件可能無法識別所屬輸入法，會標示為未歸屬，不能直接視為倉頡星故障。

修復前先保存報告，優先刷新註冊與選單；未恢復時，重新檢查安全條件，僅重啟一次並核對版本與系統選用狀態。設定及詞頻保留。系統選用成功後仍須實際試打，才算完成人工驗證。

喚醒或登入階段切回後，若已選 ABC、無待處理組字、未開系統設定且不在安全輸入狀態，會對仍啟用的單一倉頡星來源做一次註冊／選單刷新；十分鐘內最多一次，十五分鐘後過期。不會自動啟用被你停用的來源、切換輸入法或重啟程序。這是針對已觀察到的狀態不同步加上恢復措施，不能據此宣稱已證明所有灰色選項的根因。

Swift／Rust 可回報的錯誤會留下分類及代碼。程序致命崩潰由 macOS 產生異常報告，診斷工具只擷取安全摘要；它不會嘗試在記憶體已損壞的程序中繼續執行。

## 驗證與目前範圍

- 原版 C++、Rust 與 Swift 已比對 **95 個行為場景／441 步快照**。
- 倉頡與簡易資料逐項對照原版 SQLite cooker，保留順序與重複記錄；原始碼及輸出摘要列於資料 manifest。
- 原生測試涵蓋組字替換、Unicode 游標、選字、取消、生命週期、設定保存與兩種模式的學習記錄隔離。
- 安裝包會實際展開，檢查版本、兩種架構、檔案完整性、安裝目標與 app 簽章。

完整跨應用真實鍵盤驗收仍待完成；BIG-5／字型可顯示範圍過濾、舊版自訂符號分類與部分附加模組尚未遷移。Intel 切片已交叉編譯與檢查，本機實機驗證環境為 Apple Silicon。

詳細操作與待驗項目見 [M3 驗收清單](migration/M3-ACCEPTANCE.md)。

## 開發與建置

需要 macOS、Xcode 開發工具、Python 3、Ruby（含 Minitest）及 SQLite CLI。

### 準備 Rust 工具鏈

```sh
make migration-toolchain
```

固定版本來自 [rust-toolchain.toml](migration/rust-toolchain.toml)，安裝至專案的 `.source/migration/`，不修改系統 PATH 或 shell 設定。

### 執行驗證

```sh
make migration-check
make migration-preview-check
make migration-maintenance-check
```

前者驗證資料、原版 C++ 基線、Rust 測試、格式、Clippy 與跨語言重放；後者建置 Swift 輸入法，驗證原生組字、候選窗、偏好設定與學習保存。這兩條命令不會安裝或切換輸入源。

### 產生 Universal 安裝包

```sh
CARGO_HOME="$PWD/.source/migration/cargo" RUSTUP_HOME="$PWD/.source/migration/rustup" \
  .source/migration/cargo/bin/rustup target add aarch64-apple-darwin x86_64-apple-darwin
make migration-package
```

輸出位於 `build/migration/release/`：

- `CangjieX-2.0.4-universal.dmg`：推薦的原生安裝器，檢查、安裝、啟用與執行版本核對。
- `CangjieX-2.0.4-universal.pkg`：手動安裝包，安裝後需要重新登入。
- 各自的 `.sha256`：SHA256 校驗檔。
- `build-info.json`：構建 commit、架構、最低系統版本及簽署狀態。

只做本機開發安裝時可使用 `make migration-preview-install`；先完成組字並切離新版輸入法，結束系統設定。安裝會完整替換 app bundle，防止舊版的語系名稱資源殘留，並呼叫同一套維護工具刷新註冊、重啟及核對實際執行版本；成功後會切回新版輸入法，無法核對則以未完成狀態結束。原生試打工具可用 `make migration-preview-test-host` 建置。

專案內也可使用 `make migration-preview-status`、`make migration-preview-repair`、`make migration-preview-uninstall`；開發腳本會以 Xcode 工具鏈編譯目前原始碼的維護工具，也適用於尚未附帶工具的舊安裝包。`make migration-maintenance-check` 只操作暫存測試資料，不卸載日常輸入法、不寫入日常設定；它也包含在 `migration-preview-check` 中。

### 程式結構

| 目錄 | 職責 |
| --- | --- |
| [migration/preview/](migration/preview/) | Swift／AppKit／InputMethodKit 系統整合、候選窗與偏好設定。 |
| [migration/core/](migration/core/) | Rust 輸入核心與 C ABI 實作。 |
| [migration/bridge/](migration/bridge/) | Swift／Rust 共用的 C 介面與所有權契約。 |
| [migration/swift/](migration/swift/) | Swift 核心橋接與重放工具。 |
| [migration/data/](migration/data/) | 固定來源的碼表、轉換資料、摘要及授權。 |
| [migration/baseline/](migration/baseline/) | 原版 C++ 探針與行為快照。 |
| [migration/tests/](migration/tests/) | 提取、基線與原生 Swift 測試。 |
| [migration/release/](migration/release/) | 安裝說明及 Release 內容。 |

資料可用 `make migration-extract`、`make migration-extract-modules` 及 `make migration-extract-compatibility` 重現提取；相容資料提取需要已校驗的公開發佈包快取。日常檢查不改寫碼表或快照。

### GitHub Release

[Release 工作流程](.github/workflows/release.yml) 會在推送 `v2.*` 標籤時，依序執行 Linux Rust 檢查、macOS 行為與原生測試、Universal 打包與包內檢查，再上傳安裝包、SHA256 及構建資訊。

標籤須與 [Info.plist](migration/preview/Info.plist) 的版本一致。也可手動執行工作流程，輸入相符的 `2.x.y` 版本。公開安裝包目前未接上 Developer ID 簽署與 Apple 公證。

協作時請先閱讀 [AGENTS.md](AGENTS.md)。

## V1.x 舊版建置

<details>
<summary>舊版維護與回退命令</summary>

V1.x 保留兩條路線：重包既有 Yahoo! KeyKey 二進位，以及從固定版本的 C++／Objective-C 原始碼構建 Universal app。它們與 V2 的 Swift／Rust 發佈路線分開。

| 命令 | 用途 |
| --- | --- |
| `make verify`／`make checksum` | 重包並驗證舊版，輸出 `build/CangjieX.pkg`。 |
| `make source-patch-check` | 核對舊版原始碼補丁清單。 |
| `make probe-source` | 檢查固定上游原始碼工程。 |
| `make source-checksum` | 構建並驗證舊版原始碼路線，輸出 `build/source/CangjieX.pkg` 與構建資訊。 |
| `make doctor` | 檢查本機開發工具；make 無法執行時可直接使用 `./tools/doctor.sh`。 |

舊版補丁見 [manifest.tsv](tools/source-patches/manifest.tsv)。既有二進位重包在 Apple Silicon 上依賴 Rosetta，與舊版原始碼構建的 Universal app 不同。

**V1.x 安裝／卸載會操作系統目錄中的舊輸入法，不能用來安裝 V2 或當作 V2 的清理步驟。** `build.sh`、`uninstall.sh` 及相關腳本保留供舊版維護使用。

`make clean` 會清除整個 `build/`，包括 V2 的安裝包與驗證產物。

</details>

## 資料來源與授權

碼表與相容行為參考 [Yahoo! KeyKey／OpenVanilla](https://github.com/YahooArchive/KeyKey)，固定來源、摘要與筆數見：

- [倉頡碼表 manifest](migration/data/manifest.json)
- [簡易與注音文校正 manifest](migration/data/modules-manifest.json)
- [標點、繁簡與聯想詞 manifest](migration/data/compatibility-manifest.json)

Yahoo! KeyKey 原始碼採 BSD 3-Clause 授權；本專案保留原始授權聲明。隨附資料與轉換程式的授權見 [LICENSE.KeyKey.txt](migration/data/LICENSE.KeyKey.txt) 與 [LICENSE.HanConvert.txt](migration/data/LICENSE.HanConvert.txt)。
