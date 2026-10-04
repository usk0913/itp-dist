# itp-dist

Claude Code と Codex に、itp のプラグイン（itp-common と、任意で itp-3d）を1行のコマンドで導入するためのスクリプトです。配布物はパスワードで暗号化して、このリポジトリの Releases に置いています。パスワードは配布元から受け取ってください。

## 導入

### macOS・Linux

ターミナルで次の1行を実行し、パスワードを尋ねられたら入力します（入力した文字は表示されません）。

```bash
curl -fsSL https://raw.githubusercontent.com/usk0913/itp-dist/main/install.sh | sh
```

3D も入れるときは、次のようにします。

```bash
curl -fsSL https://raw.githubusercontent.com/usk0913/itp-dist/main/install.sh | sh -s -- --with 3d
```

中身を確かめてから実行したいときは、先に保存して読んでから `sh install.sh` で実行します。

```bash
curl -fsSL -o install.sh https://raw.githubusercontent.com/usk0913/itp-dist/main/install.sh
```

### Windows（PowerShell）

```powershell
& ([scriptblock]::Create((irm -UseBasicParsing https://raw.githubusercontent.com/usk0913/itp-dist/main/install.ps1)))
```

3D も入れるときは、末尾に `-With 3d` を付けます。

```powershell
& ([scriptblock]::Create((irm -UseBasicParsing https://raw.githubusercontent.com/usk0913/itp-dist/main/install.ps1))) -With 3d
```

## 選択肢

| id | 内容 | 前提 |
|---|---|---|
| `common` | itp-common（必須。常に入ります） | なし |
| `3d` | itp-3d（Blender と Three.js で 3D を扱うスキル） | Blender 5.2（無ければ警告だけ出して導入は続けます） |

端末で実行すると、番号で選択肢を切り替える画面が出ます。番号を入力して切り替え、空の行（Enter）で決定します。`q` で何もせずに終わります。

## 更新・削除

- **更新：** 同じ1行をもう一度実行します。前回選んだ項目が既定になります。古い版は、置き先の `backup/` に残ります。
- **項目を外す：** `--remove 3d`（Windows は `-Remove 3d`）。
- **全部を外す：** `--uninstall`（Windows は `-Uninstall`）。
- **反映：** Claude Code・Codex では、新しいセッションから反映されます。

置き先は、macOS・Linux では `~/.local/share/itp/dist/`、Windows では `%LOCALAPPDATA%\itp\dist\` です。

## 必要なもの

- **macOS・Linux：** `curl`、`tar`、`openssl`（OpenSSL 1.1.1 以降か LibreSSL）、`shasum` か `sha256sum`
- **Windows：** Windows 10 1809 以降、Windows PowerShell 5.1 以降、.NET Framework 4.7.2 以降、`tar.exe`
- **共通：** Claude Code か Codex の CLI。PATH にあるものだけに導入します

## 注意

- 他のエージェント（AI のコーディングツール）のサンドボックスの中では実行しないでください。通常の端末で実行してください。
- 同じ名前のプラグインが別の出所から入っているホストには、導入しません。そのホストだけ止めて案内を表示します。
- 改ざんの確認には限りがあります。暗号化したファイルの SHA-256 と、中身の SHA256SUMS は照合しますが、置き場そのものを乗っ取られた場合や、スクリプト自体が書き換えられた場合は見分けられません。
