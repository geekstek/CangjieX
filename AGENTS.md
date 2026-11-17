# 倉頡星專案協作規範

## 產品與目前架構

本專案是 macOS 輸入法「倉頡星」（CangjieX）。V2 使用 Swift 系統介面與 Rust 輸入核心，另保留 V1.x 的 Yahoo! KeyKey／OpenVanilla 建置路線。

- 使用者可見名稱統一為「倉頡星」，不再使用「CangjieX Preview／倉頡星 Preview」。
- `CangjieXPreview.app`、`io.github.geekstek.inputmethod.CangjieXPreview`、連線名與 `CangjieX Preview` 資料目錄為相容性保留的內部名稱。不能因改名就更換它們；變更須同時處理輸入源、既有設定與學習記錄的遷移。
- 以繁體中文撰寫介面、主要文件與使用說明。舊版名稱在歷史記錄、來源說明及授權中可保留。
- 跨平台重用的是 Rust 核心；目前沒有可發布的 Windows／Linux 輸入法介面。

## 程式分工

| 位置 | 責任 |
| --- | --- |
| `migration/core/` | Rust 狀態機、查表、候選排序、聯想詞、文字轉換與 C ABI；保持平台獨立。 |
| `migration/bridge/CangjieCore.h` | 共用按鍵、選項、快照與 UTF-8 所有權契約。 |
| `migration/swift/` | Swift 核心橋接與跨語言重放。 |
| `migration/preview/` | AppKit／InputMethodKit 接線、客戶端組字、候選窗、偏好及本機資料保存。 |
| `migration/data/` | 固定來源的字典、轉換表、manifest 及授權；不包含使用者詞頻。 |
| `migration/baseline/`、`migration/tests/` | 原版行為參考、快照與測試。 |
| `migration/release/` | 安裝說明及公開 Release 內容。 |
| `tools/*migration*`、`tools/verify-migration-package.py` | V2 工具鏈、驗證、建置、安裝與包內檢查。 |

輸入規則留在 Rust，macOS 視窗及系統生命週期留在 Swift。沿用現有結構與原生控制項，不為小功能新增套件或額外架構。

## 舊版與使用者資料保護

V2 開發、測試與發布均須保留舊版：

- 不覆寫、移除或終止 `/Library/Input Methods/CangjieX.app`、`/Library/Input Methods/Yahoo! KeyKey.app` 及其程序。
- `~/Library/Preferences/com.yahoo.KeyKey*.plist` 與 `~/Library/Application Support/Yahoo! KeyKey/` 僅作唯讀來源。SQLite 匯入使用 `SQLITE_OPEN_READONLY`。
- 新版設定與學習資料只寫入 `~/Library/Application Support/CangjieX Preview/`。倉頡、簡易的輸入選項及學習記錄必須隔離。
- 測試使用暫存 home、暫存 SQLite 及合成記錄，不以日常使用者資料做選字、重置、寫入或排序實驗。
- 不在日誌輸出使用者輸入、候選內容、學習記錄或憑證。
- V2 工作不呼叫舊版 `build.sh`／`uninstall.sh` 作安裝或清理。它們有替換系統輸入法的行為，只適用於明確的 V1.x 維護工作。
- 開發安裝使用現有 `tools/install-migration-preview.sh` 保護，先完成組字並切離新版。單純建置或驗證不應更改使用者輸入源。
- 註冊、修復及 V2 卸載使用 `InputSourceMaintenance.swift`／`tools/maintain-migration-input-source.sh`。維護前切離新版並結束系統設定；卸載預設保留設定與詞頻。只有已確認 app 不存在、TIS 也無來源的舊識別碼才可從系統輸入源清單移除，不改寫舊版 app 或偏好。
- 關於視窗的 GUI 卸載由 `UninstallUI.swift` 啟動簽章已驗證的獨立暫存工具。刪除資料必須經可見確認；Return／Escape 只能取消。GUI 預設勾選完整移除，CLI 則須明確傳入 `uninstall --delete-data`；不可將此旗標套用到開發更新或修復。
- 卸載 GUI 先完成組字、確認環境及切換 ABC，再移除 app；以新程序驗證殘留並顯示結果。日常安裝不得作自刪測試，使用隔離資料與不連接真實卸載的介面驗證程式。
- 名稱與空白項目須分別驗證「已加入清單」、「繁體中文可加入清單」與右上角選單。三處有獨立快取；只驗證 API 名稱或重新打開視窗不足以宣稱修復。維護工具只刷新鍵盤面板的目錄快取與相關背景程序，不重置全域 Launch Services 資料庫或整份鍵盤設定。
- 升級完成須核對執行中程序的編譯識別碼及 PID／路徑，不以磁碟 Info.plist 版本代替。原生安裝器先確認切離輸入法，再停止舊程序、寫入套件、重新啟動並核對；無法驗證或啟用時必須標示尚未完成並提示重新登入。

## 行為與橋接契約

- 以固定上游 C++ 實作及已錄製快照作相容性參考。不要修改既有快照來迎合錯誤實作；刻意改變行為時，記錄與原版的差異並加入適當測試。
- `committed`、提示音及學習事件是單次效果，不能因重繪、系統回調或重複提交再執行。
- C ABI 的 UTF-8 長度按位元組計算。明確區分借用字串、擁有的快照及釋放時機；Rust `unsafe` 邊界須保留驗證與 safety 說明。
- 校正游標按 Unicode scalar 計算，Swift 交給文字客戶端前轉成 UTF-16，不用 Swift grapheme 數量直接代替。
- 系統 `commitComposition`、停用與 Return 按鍵各有不同語義；不能為了清理介面而丟字、重複上屏或把原框內容寫入新框。
- 注音文校正取消時保留原文；該功能不是文件掃描或剪貼簿攔截。
- 變更設定不能直接清掉尚未完成的組字。候選窗不能取得客戶端鍵盤焦點。

## 資料與產物

保留上游 commit、SHA256、原始順序、重複項及授權。資料變更須使用提取流程，並核對相應 manifest。

```sh
make migration-extract
make migration-extract-modules
make migration-extract-compatibility
```

相容資料提取需要已校驗的公開發佈包快取；日常檢查直接使用已提交資料，不應改寫它們。

`.source/`、`build/`、`.codegraph/`、編譯快取與個人資料不提交到 Git。`make clean` 會刪除所有 `build/` 產物，使用前確認沒有需要保留的安裝包或驗證證據。

## 調查與驗證

陌生程式調查、跨檔案呼叫或影響範圍分析使用全域 `codegraph-workflow` skill。本倉庫維護獨立索引；依 skill 準備與同步索引，使用 shell CLI，不呼叫 CodeGraph MCP。版本、命令與修復流程以全域 skill 為準，不在本文件重複維護。

按變更範圍執行必要檢查：

| 變更 | 檢查 |
| --- | --- |
| Rust、碼表、原版行為或 C ABI | `make migration-check`；涉及 Swift 契約時亦執行 `make migration-preview-check`。 |
| Swift 輸入接線、設定或候選介面 | `make migration-preview-check`；介面變更另查看原生渲染或實際視窗。 |
| 安裝包、架構、版本與發布 | `make migration-package`，檢查 Universal 切片、版本、包內路徑、摘要與簽章。 |
| 維護工具與卸載保護 | `make migration-maintenance-check`（隔離資料）；它亦包含在 `make migration-preview-check`。不得以日常安裝或詞頻做卸載測試。 |
| 文件 | 核對檔案連結、命令與實作，不必重跑無關的程式測試。 |

Rust 工具鏈版本以 `migration/rust-toolchain.toml` 為準。首次執行 `make migration-toolchain`，工具安裝在專案快取，不改系統 PATH。

原生模擬測試不能代替真實鍵盤、輸入法選單或跨應用 IMK 驗收。人工狀態記錄於 `migration/M3-ACCEPTANCE.md`，未執行的項目保持待驗收。

## V2 發布

- 發布版本以 `migration/preview/Info.plist` 為準；app、安裝包版本與 `v2.*` tag 必須一致。
- Universal 安裝包須含 `arm64` 與 `x86_64`。V2 包僅允許目前使用者目錄、不含安裝腳本、不搜尋或替換舊版 app。
- 推薦的 .dmg 提供獨立原生安裝器，內附同一份已校驗的 .pkg；安裝器及輸入法的 runtime build ID 必須一致。手動 .pkg 必須宣告 `RequireLogout`，完成畫面不得只寫「升級完成」。
- `.github/workflows/release.yml` 驗證後才發布 `.pkg`、`.sha256` 與 `build-info.json`。V1.x Release 留作回退，不把舊路線產物當成 V2。
- 發布說明如實列出簽署、公證、實機架構與尚未完成的驗收。沒有量測資料時，不宣稱比舊版更快或更省記憶體。
- 到 GitHub 核對 tag、Release 與實際附件後，才宣稱發布成功；同步更新 README 的發布狀態。推送／上傳失敗須如實回報，不移動已發布標籤或默默覆蓋公開附件。
