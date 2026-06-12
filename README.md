# CangjieX / 倉頡星

為現代 macOS 而生的開源倉頡輸入法發佈專案，基於 Yahoo! KeyKey 與 OpenVanilla，目標是把經典倉頡輸入體驗重新整理成可維護、可簽署、可發佈的 macOS 安裝包。

## 目前狀態

這個倉庫目前是發佈打包倉庫：它會把既有的 Yahoo! KeyKey 輸入法 app 重新整理為 `CangjieX.app`，並輸出 `CangjieX.pkg`。底層二進制仍是舊版 Yahoo! KeyKey，因此 Apple Silicon 目前仍依賴 Rosetta；真正的 arm64 原生支援需要後續從 YahooArchive/KeyKey 或 bency/YahooKeyKey 的源碼重建。

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

推送版本 tag 會自動建置並發佈 `CangjieX.pkg` 到 GitHub Releases：

```sh
git tag v1.0.1
git push origin v1.0.1
```

也可以在 GitHub Actions 頁面手動執行 `Release` workflow，輸入版本號即可。

目前 CI 發佈的是未簽署 pkg。若要公開給一般使用者下載，建議後續在 Actions 補上 Developer ID 憑證匯入、簽名與 notarization。

## 安裝行為

安裝包會安裝到：

```text
/Library/Input Methods/CangjieX.app
```

安裝前會移除舊的 `/Library/Input Methods/CangjieX.app` 與 `/Library/Input Methods/Yahoo! KeyKey.app`，避免同一套舊輸入法服務被 macOS 重複註冊。這不會刪除使用者詞庫或偏好資料。

安裝後請登出再登入，然後到「系統設定 > 鍵盤 > 輸入方式」啟用 CangjieX。

## 授權

Yahoo! KeyKey 原始碼由 Yahoo! Inc. 以 BSD 3-Clause License 釋出。本專案保留原始授權聲明，並以 CangjieX / 倉頡星 名義進行社群維護與發佈。
