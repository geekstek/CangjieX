# CangjieX / 倉頡星

為現代 macOS 而生的開源倉頡輸入法發佈專案，基於 Yahoo! KeyKey 與 OpenVanilla，目標是把經典倉頡輸入體驗重新整理成可維護、可簽署、可發佈的 macOS 安裝包。

## 目前狀態

這個倉庫目前提供兩條建置路線：

1. 預設路線會把既有的 Yahoo! KeyKey 輸入法 app 重新整理為 `CangjieX.app`，並輸出 `CangjieX.pkg`。底層二進制仍是舊版 Yahoo! KeyKey，因此 Apple Silicon 會依賴 Rosetta。
2. 源碼路線會從 `YahooArchive/KeyKey` 拉取固定 commit `81e05f070c070af65cac21e8da28ca4ff2d58905` 的 BSD 授權源碼，套用現代 macOS / Xcode 相容補丁，編出 `arm64 + x86_64` universal app，再重新品牌化為 `CangjieX.pkg`。這是目前建議的發佈路線。

打包過程會移除舊版安裝說明 app 與 Yahoo 更新檢查 app，避免正式發佈包攜帶已過時的 Yahoo 安裝流程與更新入口。

## 主打方向

- 倉頡核心輸入
- 繁簡轉換
- 聯想詞 / 關聯詞
- 現代 macOS 安裝流程
- Apple Silicon 發佈路線
- 開源社群維護

## 建置

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

源碼路線會額外檢查輸入法主程式包含 `arm64`、最低系統版本不高於 macOS 11.0，並確認 `KeyKey.db` 內含倉頡碼表與繁體聯想詞資料。聯想詞會由上游開放詞庫與 `tools/common-associated-phrases.txt` 重新產生，並在打包時檢查常用候選順序與簡體字混入。由於目前仍有 DotMacKit、SQLite SEE/CEROD 與部分舊安全驗證路徑的 probe-only 替代實作，智慧注音與舊加密使用者資料庫仍不作為發佈重點。

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

安裝後請登出再登入，然後到「系統設定 > 鍵盤 > 輸入方式」啟用 CangjieX。

卸載：

```sh
./uninstall.sh
```

## 授權

Yahoo! KeyKey 原始碼由 Yahoo! Inc. 以 BSD 3-Clause License 釋出。本專案保留原始授權聲明，並以 CangjieX / 倉頡星 名義進行社群維護與發佈。
