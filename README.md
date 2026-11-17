# CangjieX / 倉頡星

為現代 macOS 而生的開源倉頡輸入法發佈專案，基於 Yahoo! KeyKey 與 OpenVanilla，目標是把經典倉頡輸入體驗重新整理成可維護、可簽署、可發佈的 macOS 安裝包。

## 下載與安裝 V2.0.0

**[下載 macOS 安裝包（Apple Silicon + Intel）](https://github.com/geekstek/CangjieX/releases/download/v2.0.0/CangjieX-2.0.0-universal.pkg)** · [Release 說明與 SHA256](https://github.com/geekstek/CangjieX/releases/tag/v2.0.0)

1. 完成組字並切到 ABC，下載並開啟 `.pkg`。支援 macOS 11 或更新版本。
2. 安裝只更新目前使用者的 `~/Library/Input Methods/CangjieXPreview.app`，保留舊版及其設定／詞頻。
3. 保存工作，在方便時登出並重新登入；到「系統設定 → 鍵盤 → 文字輸入 → 編輯 → ＋ → 繁體中文」加入 **CangjieX Preview／倉頡星 Preview**。已有該項目時直接選取即可。

本版沿用 Preview 身份，是 Swift / Rust 路線的首個可下載版；跨應用實際試打仍待完整驗收。安裝包未以 Developer ID 簽署，也未經 Apple 公證；若 macOS 阻擋，確認下載來源後使用「系統設定 → 隱私權與安全性 → 仍要打開」。不用停用 Gatekeeper 或 SIP。

## 目前狀態

V2.0.0 使用 Swift / AppKit / InputMethodKit 與 Rust 核心，包含倉頡、簡易、注音文校正、聯想詞、繁簡／全形輸出及候選排序學習。使用 `make migration-package` 產生 Universal 安裝包，發佈工作流程會先執行 Rust、原版行為基線及原生 Swift 檢查。

以下兩條 V1.x 建置路線保留供維護與回退：

1. 預設路線會把既有的 Yahoo! KeyKey 輸入法 app 重新整理為 `CangjieX.app`，並輸出 `CangjieX.pkg`。底層二進制仍是舊版 Yahoo! KeyKey，因此 Apple Silicon 會依賴 Rosetta。
2. 源碼路線會從 `YahooArchive/KeyKey` 拉取固定 commit `81e05f070c070af65cac21e8da28ca4ff2d58905` 的 BSD 授權源碼，套用現代 macOS / Xcode 相容補丁，編出 `arm64 + x86_64` universal app，再重新品牌化為 `CangjieX.pkg`。此路線仍保留，但不是 V2.0.0 的發佈產物。

V1.x 打包過程會移除舊版安裝說明 app 與 Yahoo 更新檢查 app，避免正式發佈包攜帶已過時的 Yahoo 安裝流程與更新入口。

V1.x 發佈包會替換舊 Yahoo 圖示與 About 圖，使用 CangjieX / 倉頡星 的深色星空圖標系統；中文系統中輸入法顯示名稱為「倉頡星」，英文系統中顯示為「CangjieX」。

## 主打方向

- 倉頡核心輸入
- 繁簡轉換
- 聯想詞 / 關聯詞
- 現代 macOS 安裝流程
- Apple Silicon 發佈路線
- 開源社群維護

## 建置

### V2.0.0 Swift / Rust 安裝包

```sh
make migration-toolchain
CARGO_HOME="$PWD/.source/migration/cargo" RUSTUP_HOME="$PWD/.source/migration/rustup" \
  .source/migration/cargo/bin/rustup target add aarch64-apple-darwin x86_64-apple-darwin
make migration-package
```

產物位於 `build/migration/release/`，包括 `.pkg`、`.sha256` 與 `build-info.json`。打包使用 macOS `pkgbuild`／`productbuild`，只允許安裝至目前使用者目錄、不含安裝腳本，也不搜尋或替換舊版 app。建置會實際展開安裝包，核對兩種架構、版本、檔案摘要、目的地與 app 簽章。

### Swift / Rust 遷移與驗證（M1 / M2 / M3 Preview）

`migration/` 是獨立的開發驗證路線，提供碼表、原版行為基線、Rust 輸入狀態機、Swift 橋接，以及 M3 的 InputMethodKit Preview 原型。M1 / M2 已通過基線驗證；M3 保留現有輸入設定，Preview 0.5.0 候選介面以美觀及易用為優先重新設計，原生測試通過；跨程序真實鍵盤與各應用相容性仍待人工驗收，不能視為正式替代版本。

首次準備 Rust 工具鏈：

```sh
make migration-toolchain
```

這會從 Rust 官方下載固定版本的工具鏈至 `.source/migration/`，不修改系統 PATH 或 shell 設定。已有對應 Rust 工具鏈時也可直接使用。Xcode、Ruby（含 Minitest）和 SQLite CLI 需可用。

執行全部 M1 / M2 檢查：

```sh
make migration-check
```

此命令會在首次執行時下載並校驗固定版本的 KeyKey 源碼，之後可使用快取。快取和驗證產物分別位於 `.source/migration/`、`build/migration/`；檢查不執行安裝、卸載、服務註冊或舊版打包。既有 `build/CangjieX.pkg`、`build/source/` 和已安裝輸入法均不會被覆蓋。原有 `make clean` 仍會清除整個 `build/`，包括遷移驗證產物。

- `migration/data/manifest.json` 記錄來源 commit、CIN SHA256、輸出 SHA256 及選字鍵 metadata；`keynames.tsv` 保存字根名稱，`cangjie.tsv` 保留 82,873 筆記錄、65,732 組編碼的原始候選順序及重複項。來源說明與授權一併保留。
- `migration/baseline/cases.json` 記錄 23 個場景、94 步快照。檢查會編譯並執行固定版本的原版 C++ 輸入模組與候選面板，比對退格、取消、五碼上限、選字、翻頁、英文與標點等行為。
- `migration/baseline/m2-cases.json` 額外記錄 15 個原版場景、94 步快照，涵蓋候選中退格、循環翻頁、高亮邊界、一次提交候選加標點，以及問號／星號查詢。M1 快照保持不變；同一批 JSON 由原版 C++ 與 Swift → Rust 狀態機各自重放並逐步比對。
- 基線使用原版倉頡預設、停用動態排序、垂直候選面板及接受全部字元的預設編碼服務；候選派送由最小測試程式依原版 loader 流程接線。它不是已安裝輸入法的 UI 錄製，也不代表所有使用者設定。焦點切換、應用相容與視窗定位留待 M3 的 InputMethodKit 驗收。
- `migration/core/` 不含第三方 Rust 依賴。`Session` 實作五字根輸入、確認查表、九鍵選字、翻頁與高亮、退格與取消、英文和標點，以及萬用字元查詢；原有精確查表 API 保留。每個會話獨立，字典共用；事件快照不可變，可在後續按鍵、重置或會話釋放後繼續讀取。
- `migration/bridge/CangjieCore.h` 定義會話、快照和 UTF-8 位元組的所有權。C 介面使用標準化按鍵而非 macOS 硬體 keycode；無效事件不改變狀態。`committed`／`beep` 是該事件的一次性效果，宿主每個事件只應套用一次。
- Command／Control／Option 組合鍵在 M2 回傳「未消費」並保留輸入；M1 尚未記錄組字中快捷鍵的系統行為，因此此項是 M2 的明確策略，留待 M3 應用驗收。`reset` 明確取消未完成輸入，不自動上屏；失焦時應提交或取消的系統接線同樣留待 M3。
- `migration/swift/Probe.swift` 透過 C 介面呼叫 Rust，完整比對全部編碼的候選內容、順序及重複項，並測試擴展漢字、錯誤輸入、索引邊界與結果釋放。編譯產物位於 `build/migration/swift-rust-probe`。
- `migration/swift/SessionProbe.swift` 重放全部 95 個場景、441 步快照，另驗證會話隔離、重置、快捷鍵透傳、錯誤事件、快照生命週期及反覆建立／釋放會話。編譯產物位於 `build/migration/swift-session-probe`。

需要重新提取固定版本碼表時執行 `make migration-extract`；日常檢查只比對，不會改寫已提交的碼表或行為快照。遷移 CI 獨立於既有發佈流程，另在 Linux 執行 Rust 核心與狀態機單元測試；全部 JSON 快照的跨語言重放在 macOS 執行。

#### M3 Preview 建置與試打

```sh
make migration-preview-check
make migration-preview-install
make migration-preview-test-host
```

第一條命令建置並檢查 Preview，不安裝或切換輸入源。目前共有 95 個場景、441 步快照經 `NSEvent → Swift → Rust` 重放；真正的 `NSTextView` 另驗證標記替換、擴展漢字、取消、提交、失焦及關聯詞清理。測試也驗證設定讀取、詞頻匯入／重新啟動、原始資料庫未被寫入，以及候選視窗尺寸、定位與顯示／隱藏。這些測試不等同於跨程序 IMK 驗收。

Preview 每次啟用時先只讀取舊版 `com.yahoo.KeyKey.Generic-cj-cin` 與 `com.yahoo.KeyKey` 設定，套用即時查字、滿碼確認、錯碼保留、空格選字、動態排序、半角標點、繁轉簡及聯想詞。之後套用 Preview 獨立保存的選項覆蓋；按鍵處理只讀取記憶體中的設定，不逐鍵讀寫舊版偏好。M1 / M2 的預設 profile 保持不變；`m3-live-cases.json` 新增目前設定下的 19 個原版場景／104 步，`m3-full-cases.json` 再新增原版聯想詞與繁轉簡流程的 11 個場景／50 步。候選顯示仍是繁體，繁轉簡只在上屏時套用，學習記錄保留原始候選字。

動態詞頻首次啟用時透過 SQLite 的 **READONLY** 模式讀取舊紀錄，往後只寫入 `~/Library/Application Support/CangjieX Preview/frequency.json`，不更新舊資料庫。每次重新啟用會話載入 Preview 已學習的次序。舊版偏好也不會被 Preview 改寫。

Preview 0.3.0 的垂直候選窗採用 macOS 淺深色配色、細框圓角、平面高亮及 17pt 預設字體；舊版明確設定的字體高度與高亮色仍保留，高亮文字依背景選用黑／白以保持對比。序號與提示使用次要層級，聯想詞標題為「聯想詞」，旁邊完整顯示 `⇧ 1–9` 等當頁快捷鍵。翻頁區統一放在底部，單頁隱藏，末頁保留高度以穩定按鈕位置；長詞限制視窗寬度並以省略號及完整工具提示呈現。普通候選與聯想詞都可直接點擊；聯想詞點擊透過與 Shift＋數字鍵相同的 Rust 路徑追加後綴。原有鍵盤操作繼續與各 profile 的原版快照比對，滑鼠選聯想詞是這版新增的體驗改進。

Preview 0.4.0 新增輸入選單：聯想詞、繁轉簡及全形英數字開關，並保留舊版快捷鍵 `⇧⌘Space`、`⌃⌘G`。符號入口使用 macOS 系統符號面板（`⌃⌘.`），不是舊版自訂符號分類。原生偏好視窗分為輸入、輸出、候選與提示三頁，包含輸入選項、候選字大小與提示音；變更只存至 `~/Library/Application Support/CangjieX Preview/settings.json`，不改寫舊版。輸入選項在目前組字結束後套用，避免清掉未完成字根。全形轉換放在 Rust 輸出過濾階段，包含舊版引號與括號規則，原有鍵盤基線不變。Preview 0.5.0 已接上簡易與注音文校正，見下述行為與驗收邊界。

Preview 0.5.0 在選單與偏好中提供「倉頡／簡易」切換及「注音文校正」開關。簡易使用原版 `simplex-ext.cin` 的 63,234 筆記錄／706 組編碼，最多兩個字根；其輸入選項、學習記錄與倉頡分離，讀取舊版簡易設定仍為唯讀，自有學習檔案為 `simplex-frequency.json`。切換輸入方式會等目前組字完成，不會直接丟棄字根；未明確覆寫的簡易選項採用簡易自身的原版預設及舊設定。

注音文校正保留原版 around filter 的規則：處理輸入法流程收到的 Unicode 文字，對第一個可校正字元顯示候選，數字鍵／Return／滑鼠選擇替換；Escape、系統提交或停用保留原文，一次上屏。它不是全文校對，也不攔截剪貼簿貼上或改寫已上屏內容；原版表雖含多字鍵，處理器仍按字元搜尋，這個行為保持不變。文字與游標經 Rust／C／Swift 傳回，以 Unicode scalar 到 UTF-16 的轉換保護擴展字元。原生測試涵蓋未完成組字保護、取消、滑鼠及生命週期；各應用真正的 Unicode 文字交付仍需實際驗收。

`modules-manifest.json` 記錄兩份原始表的固定 commit、SHA256、筆數與輸出摘要；`make migration-extract-modules` 可重現提取。檢查將兩份表逐項對照原版 SQLite cooker，並新增 `simplex-cases.json`、`simplex-full-cases.json`、`correction-cases.json` 共 27 個原版場景／99 步；原有 68 個場景／342 步保持不變。基線使用接受全部 Unicode 的編碼服務，不涵蓋舊版 BIG-5 或字型可顯示範圍過濾。

系統回調與 Return 按鍵分開：按 Return 仍由 Rust 選字；系統 `commitComposition` 依舊版 loader 排除 reading buffer，清除尚未上屏的字根。`deactivateServer` 若先收到系統提交便不再插入內容；若直接收到停用回調，則依舊版自發提交路徑將當時顯示的字根文字交還客戶端，隨後清理狀態。聯想詞提示不屬於未完成組字，提交／停用都只隱藏提示。這部分已按原版 macOS loader 源碼接線並以 NSTextView 驗證，仍需逐應用確認回調先後次序。

半角標點與繁轉簡資料來自固定 commit 的原始碼；聯想詞資料取自既有 Yahoo! KeyKey 發佈包的公開 `KeyKey.db`，不是使用者資料庫。`migration/data/compatibility-manifest.json` 保存來源、SHA256、行數及輸出摘要，授權一併打包。`make migration-extract-compatibility` 可從固定源碼與 `.source/Yahoo! KeyKey.app` 的已校驗資料庫重新提取；一般檢查與 CI 使用已提交、帶摘要的表，不下載二進制發佈包。

安裝只寫入 `~/Library/Input Methods/CangjieXPreview.app`，沿用獨立的 `io.github.geekstek.inputmethod.CangjieXPreview` 標識、連線及程序名稱，不呼叫舊版安裝／卸載腳本。更新時須先切離 Preview，避免遺失未完成組字。原型為本機 ad-hoc 簽署、當前主機架構建置；未公證；V2.0.0 發佈包由上述獨立打包路線產生。

在「系統設定 → 鍵盤 → 文字輸入 → 編輯 → 加入 → 繁體中文」加入 **CangjieX Preview**。測試程式位於 `build/migration/preview/CangjieX Preview Test.app`，使用 macOS 文字與輸入源 API；「使用舊版」與「使用 Preview」都透過系統輸入源切換，不直接呼叫 Rust。

完整的自动检查结果、逐步试打操作、应用矩阵和差异记录模板见 [M3 Preview 验收清单](migration/M3-ACCEPTANCE.md)。请先完成快速检查，再记录焦点切换、光标定位和连续使用；不需要重置旧版词频或重装旧版。

**驗收限制（2026-11-17）：** 使用者已回報能試用 Preview。桌面自動按鍵在新舊輸入源中都產生原始英文字母，因此目前無法用該自動化可靠判定 IMK 路由或取得實際選字回調；先前推斷的註冊快取原因未獲確認。現有證據是原版 C++ 快照對照、原生 NSTextView／候選視窗測試與只讀資料保護；完整系統試打仍待真實鍵盤驗收。這次聚焦倉頡輸入與候選面板，已提供倉頡基本設定；尚未移植完整舊版設定視窗及計算機等附加模組。

### 既有 KeyKey 建置

安裝 Xcode Command Line Tools 後執行：

```sh
./build.sh
```

也可以使用 make：

```sh
make verify
```

若遇到 Xcode、git、pkgbuild 相關錯誤，可以先跑環境體檢：

```sh
make doctor
```

如果 `make` 本身也報 `xcrun` / `libxcrun` 錯誤，請直接執行：

```sh
./tools/doctor.sh
```

需要同時產生校驗檔時：

```sh
make checksum
```

輸出檔案：

```text
build/CangjieX.pkg
```

建置後可以跑發佈前檢查：

```sh
./verify-pkg.sh build/CangjieX.pkg
```

預設會產生未簽署的 pkg，適合本機測試。正式發佈請使用 Developer ID 憑證：

```sh
APP_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
INSTALLER_SIGN_IDENTITY="Developer ID Installer: Your Name (TEAMID)" \
./build.sh
```

公眾下載版本還應提交 Apple notarization 並 stapling：

```sh
xcrun notarytool submit build/CangjieX.pkg --keychain-profile "notarytool-profile" --wait
xcrun stapler staple build/CangjieX.pkg
```

## GitHub Release

推送版本 tag 會自動建置 source-built `CangjieX.pkg` 到 GitHub Releases：

```sh
git tag v1.0.1
git push origin v1.0.1
```

也可以在 GitHub Actions 頁面手動執行 `Release` workflow，輸入版本號即可。版本號必須使用 `x.y.z` 數字格式，例如 `1.0.1`。

目前 CI 發佈的是未簽署 pkg。若要公開給一般使用者下載，建議後續在 Actions 補上 Developer ID 憑證匯入、簽名與 notarization。

## 源碼構建探測

若要檢查上游 Yahoo! KeyKey 源碼工程：

```sh
make probe-source
```

這會在 `/tmp/CangjieX-upstream-source` 拉取固定的 `YahooArchive/KeyKey` 上游 commit，列出 Xcode project 與 target。源碼補丁清單集中在：

```text
tools/source-patches/manifest.tsv
```

清單記錄每個構建補丁的 id、類型、目標檔案與用途；`tools/probe-upstream-source.sh` 會在套用補丁時檢查清單，避免新增補丁但忘記登記。若要臨時測試其他上游版本，可以用 `SOURCE_UPSTREAM_COMMIT=... make probe-source`，正式發佈仍建議先固定 commit 並更新補丁清單。

若只想檢查補丁清單與 source 構建腳本是否同步：

```sh
make source-patch-check
```

若已安裝完整 Xcode，可以進一步嘗試：

```sh
PROBE_BUILD=1 make probe-source
```

若要直接產生 Apple Silicon 原生 source-built pkg：

```sh
make source-checksum
```

這會輸出源碼安裝包：

```text
build/source/CangjieX.pkg
```

同時會輸出 `build/source/source-build-info.txt`，記錄 pkg SHA256、上游 commit、補丁清單 SHA256 與構建環境，方便日後排查不同發佈包的來源。

源碼路線會額外檢查輸入法主程式包含 `arm64`、最低系統版本不高於 macOS 11.0，並確認 `KeyKey.db` 內含倉頡碼表與繁體聯想詞資料。聯想詞會由 `tools/common-associated-phrases.txt` 的倉頡星高頻詞、固定版本 Jieba 繁體大詞典、固定版本 OpenCC 詞組資料與上游開放詞庫重新產生，並在打包時檢查常用候選順序與簡體字混入。由於目前仍有 DotMacKit、SQLite SEE/CEROD 與部分舊安全驗證路徑的 probe-only 替代實作，智慧注音與舊加密使用者資料庫仍不作為發佈重點。

預設穩定包仍輸出到：

```text
build/CangjieX.pkg
```

這樣測試源碼包失敗時，可以重新安裝穩定包恢復輸入法。

## 安裝行為

安裝包會安裝到：

```text
/Library/Input Methods/CangjieX.app
```

安裝前會移除舊的 `/Library/Input Methods/CangjieX.app` 與 `/Library/Input Methods/Yahoo! KeyKey.app`，避免同一套舊輸入法服務被 macOS 重複註冊。這不會刪除使用者詞庫或偏好資料。

安裝：

```sh
sudo installer -pkg CangjieX.pkg -target /
```

安裝成功後請登出再登入。重新登入後，到「系統設定 > 鍵盤 > 文字輸入 > 編輯」，在中文輸入法中加入「倉頡星」；英文系統中可能顯示為「CangjieX」。

如果安裝後列表中仍沒有看到「倉頡星 / CangjieX」，請先確認安裝的是最新 `CangjieX.pkg`，然後再登出登入一次。macOS 輸入法服務常需要重新登入才會刷新。

卸載：

```sh
./uninstall.sh
```

## 授權

Yahoo! KeyKey 原始碼由 Yahoo! Inc. 以 BSD 3-Clause License 釋出。本專案保留原始授權聲明，並以 CangjieX / 倉頡星 名義進行社群維護與發佈。
