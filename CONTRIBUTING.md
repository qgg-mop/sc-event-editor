# 貢獻指南（Contributing）

感謝你願意幫忙。這個專案是二創工具，**不包含任何遊戲素材**，請先讀完下面的規則再送出 PR。

## 可以貢獻什麼

| 類型 | 例子 |
|---|---|
| 🐛 Bug 回報 | 編輯器crash、素材載入失敗、配音無聲 |
| 🎨 介面／體驗 | 版面、快捷鍵、無障礙、深色模式 |
| 🗣 語體資料 | 修正角色統計、補充方言／語尾規則、新增角色 |
| 🔌 TTS 引擎 | 新增 adapter（VOICEVOX 以外的新引擎） |
| 📖 文件 | README、使用說明、英文翻譯 |

## 不可以提交什麼

- ❌ 遊戲素材（背景、Spine、字型、語音、立繪）
- ❌ 官方劇本原文（`資料/style/corpus`）
- ❌ API key、token、`llm-config.json`、`tts-keys.json`
- ❌ 別人的二創劇本（除非你本人同意以 MIT 釋出）

PR 若含上述內容會被直接關閉。

## 開發環境

- Windows 10/11 + PowerShell 5.1
- 編輯器本身是純前端（HTML/CSS/JS），不需要 build
- 選用：Python 3.10+（語體工具、Agent API）

```powershell
# 起本機伺服器
sc-export\run-server.cmd        # http://127.0.0.1:8000
```

> Spine 動畫一定要用 http 開啟，`file://` 會被 CORS 擋住。

## 回報 Bug

請附上：

1. 你做了什麼（點哪個按鈕、載入哪個劇本）
2. 預期結果 vs 實際結果
3. 瀏覽器 Console 的錯誤（F12 → Console）
4. 編輯器版本（`index.html` 開頭註解或截圖右下角）

## 送出 PR

```bash
git checkout -b fix/your-change
# 改完後
git commit -m "fix: 修正 XXX"
git push origin fix/your-change
```

- Commit 訊息用 `fix:` / `feat:` / `docs:` / `refactor:` 開頭
- 一次 PR 只做一件事
- 改到 `index.html` 請附上改前／改後截圖（**不要含遊戲素材**，可用空白背景）

## 更新語體資料

1. 改 `資料/style/翻译参数表.md`
2. 重新產生規格：
   ```bash
   python sc-editor/tools/build-style-spec.py
   ```
3. 驗證：
   ```bash
   python 資料/style/style_lookup.py --speaker 月岡戀鐘 --check "わかったばい、うちが準備しとくけんね。"
   ```
4. 確認 `violations` 為空，且 `style-spec.json` 格式沒變

## 授權

送出 PR 即表示你同意以 **MIT** 授權你的貢獻；遊戲素材相關內容仍屬 ©Bandai Namco Entertainment Inc.，不在授權範圍。