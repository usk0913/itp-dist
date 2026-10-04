# itp のプラグインを、暗号化した配布物から Claude Code・Codex へ導入する（Windows 用。dist だけ）。
#
# 仕様は docs/installer/README.md の 1.2〜1.10（install.sh と同じ契約）。Windows PowerShell 5.1 と
# PowerShell 7 で動く。復号は openssl を使わず .NET で行い、tar は Windows 標準の tar.exe を使う。
#   powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 [-Edition dist] [-With <id>,<id>]
#              [-Remove <id>,<id>] [-Uninstall] [-Version <tag>] [-Help]
#
# このファイルは UTF-8 の BOM 付きで保存する（Windows PowerShell 5.1 が日本語を読めるように）。
# パスワードは環境変数 ITP_PASSWORD か端末（Read-Host -AsSecureString）からだけ読む。引数・出力・
# 例外の文言には出さない。本体は関数の中に置き、最後の行で呼ぶ（途中まで読まれても実行されないように）。

# 終了コード: 0 成功 / 1 その他 / 2 引数の誤り / 3 前提不足・対象ホスト無し /
#             4 取得・SHA-256・形式の失敗 / 5 復号の失敗 / 6 一部のホストを止めた

param(
    [string]$Edition = 'dist',
    [string]$With,
    [string]$Remove,
    [switch]$Uninstall,
    [string]$Version,
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)]
    [object[]]$Rest
)

# ---------------------------------------------------------------- 表示と終了

function Initialize-ItpOutput {
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $ok = $true
    try { [Console]::OutputEncoding = $utf8 } catch { $ok = $false }
    if (-not $ok) {
        # コンソールが無く、文字コードを変えられないときは、UTF-8 で直接書く
        $script:OutWriter = New-Object System.IO.StreamWriter([Console]::OpenStandardOutput(), $utf8)
        $script:OutWriter.AutoFlush = $true
        $script:ErrWriter = New-Object System.IO.StreamWriter([Console]::OpenStandardError(), $utf8)
        $script:ErrWriter.AutoFlush = $true
    }
}

function Write-ItpInfo([string]$Text) {
    if ($script:OutWriter) { $script:OutWriter.WriteLine($Text) } else { [Console]::Out.WriteLine($Text) }
}

function Write-ItpError([string]$Text) {
    if ($script:ErrWriter) { $script:ErrWriter.WriteLine($Text) } else { [Console]::Error.WriteLine($Text) }
}

function Write-ItpWarn([string]$Text) {
    Write-ItpError "警告: ${Text}"
}

# 終了コードを持った例外で巻き戻す（exit は、& ([scriptblock]::Create(...)) の形で実行したときに
# シェルごと閉じるため使わない。irm | iex での実行は案内しない）
function Stop-Itp([int]$Code, [string]$Message) {
    Write-ItpError "エラー: ${Message}"
    throw "ITP_EXIT:${Code}"
}

function Show-ItpUsage {
    Write-ItpInfo @'
使い方: install.ps1 [-Edition dist] [-With <id>,<id>] [-Remove <id>,<id>] [-Uninstall]
                    [-Version <tag>] [-Help]

  -Edition    系統。Windows 版は dist だけ（既定は dist）
  -With       任意の項目の集合を指定する（画面を出さない）。-With "" は任意の項目を選ばない
  -Remove     指定した任意の項目の登録を外す（配布物の取得とパスワードは要らない）
  -Uninstall  この系統の登録をすべて外して置き先を片付ける（backup\ は残す）
  -Version    Releases のタグを固定する。既定は最新
  -Help       この説明を表示する

パスワードは環境変数 ITP_PASSWORD か端末から読みます（引数では受け付けません）。
取得先は ITP_RELEASES_URL で変えられます。
'@
}

# ---------------------------------------------------------------- 一覧の部品（id の配列。呼び出し側は @() で包む）

function Test-ItpIn([string]$Item, $List) {
    return (@($List) -contains $Item)
}

function Get-ItpUnion($A, $B) {
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($x in (@($A) + @($B))) {
        if ($x -and -not $out.Contains([string]$x)) { $out.Add([string]$x) }
    }
    return $out.ToArray()
}

function Get-ItpMinus($A, $B) {
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($x in @($A)) {
        if ($x -and -not (Test-ItpIn ([string]$x) $B)) { $out.Add([string]$x) }
    }
    return $out.ToArray()
}

# 目録の並びで、指定した id だけを並べる
function Get-ItpInCatalogOrder($Ids) {
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($e in @($script:Catalog)) {
        if (Test-ItpIn $e.Id $Ids) { $out.Add($e.Id) }
    }
    return $out.ToArray()
}

function Split-ItpIds([string]$Text) {
    return @(($Text -replace ',', ' ') -split '\s+' | Where-Object { $_ })
}

# ---------------------------------------------------------------- 外部プロセス（標準入力は閉じて渡さない）

function ConvertTo-ItpArgString($Items) {
    $parts = foreach ($a in @($Items)) {
        $s = [string]$a
        if ($s.Length -eq 0) {
            '""'
        } elseif ($s -notmatch '[\s"&|<>^%()]') {
            $s
        } else {
            $q = $s -replace '(\\*)"', '$1$1\"'
            $q = $q -replace '(\\+)$', '$1$1'
            '"' + $q + '"'
        }
    }
    return ($parts -join ' ')
}

# 戻り値: ExitCode・Out・Err・Output（標準出力と標準エラーをつなげたもの）
function Invoke-ItpProcess([string]$Exe, $Arguments, [string]$WorkDir) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = ConvertTo-ItpArgString $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    if ($WorkDir) { $psi.WorkingDirectory = $WorkDir }
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    try {
        [void]$proc.Start()
    } catch {
        return [pscustomobject]@{ ExitCode = 127; Out = ''; Err = $_.Exception.Message; Output = $_.Exception.Message }
    }
    try {
        $proc.StandardInput.Close()
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        $proc.WaitForExit()
        $o = $outTask.Result
        $e = $errTask.Result
        return [pscustomobject]@{ ExitCode = $proc.ExitCode; Out = $o; Err = $e; Output = ($o + $e) }
    } finally {
        $proc.Dispose()
    }
}

# ---------------------------------------------------------------- 場所と状態

function Get-ItpState([string]$Key) {
    $file = Join-Path $script:DistDir 'state'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return '' }
    foreach ($line in [System.IO.File]::ReadAllLines($file)) {
        if ($line.StartsWith("${Key}=", [System.StringComparison]::Ordinal)) {
            return $line.Substring($Key.Length + 1)
        }
    }
    return ''
}

function Write-ItpState([string]$BundleVersion, $Selected, $Installed, $Hosts) {
    try {
        New-Item -ItemType Directory -Force -Path $script:DistDir | Out-Null
        $lines = @(
            "format=$($script:FormatVersion)",
            "edition=$($script:EditionName)",
            "bundle_version=${BundleVersion}",
            "selected=$((@($Selected)) -join ' ')",
            "installed=$((@($Installed)) -join ' ')",
            "hosts=$((@($Hosts)) -join ' ')"
        )
        $new = Join-Path $script:DistDir 'state.new'
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($new, (($lines -join "`n") + "`n"), $utf8)
        Move-Item -LiteralPath $new -Destination (Join-Path $script:DistDir 'state') -Force
    } catch {
        Stop-Itp 1 'state を書けません'
    }
}

# ---------------------------------------------------------------- 目録（タブ区切り）

function Read-ItpCatalog([string]$File) {
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($raw in [System.IO.File]::ReadAllLines($File)) {
        $line = $raw.TrimEnd("`r")
        if ($line.StartsWith('#') -or -not $line.Trim()) { continue }
        $c = $line -split "`t"
        if ($c.Length -lt 6 -or -not $c[0]) { continue }
        $entries.Add([pscustomobject]@{
                Id = $c[0]; Label = $c[1]; Plugin = $c[2]; Kind = $c[3]; Prereq = $c[4]; PrereqLabel = $c[5]
            })
    }
    return $entries.ToArray()
}

function Get-ItpCatalogEntry([string]$Id) {
    foreach ($e in @($script:Catalog)) {
        if ($e.Id -eq $Id) { return $e }
    }
    return $null
}

function Get-ItpPluginOf([string]$Id) {
    $e = $null
    if ($script:Catalog) { $e = Get-ItpCatalogEntry $Id }
    if ($e -and $e.Plugin) { return $e.Plugin }
    return "itp-${Id}"
}

# ---------------------------------------------------------------- ホスト

function Get-ItpHostLabel([string]$Name) {
    switch ($Name) {
        'claude' { return 'Claude Code' }
        'codex' { return 'Codex' }
        default { return $Name }
    }
}

function Find-ItpHosts {
    $found = New-Object System.Collections.Generic.List[string]
    $script:HostExe = @{}
    foreach ($name in @('claude', 'codex')) {
        $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) {
            $script:HostExe[$name] = $cmd.Source
            $found.Add($name)
        }
    }
    $script:PresentHosts = $found.ToArray()
}

# 登録の CLI を実行し、出力と終了コードを HostOut・HostRc に残す
function Invoke-ItpHost([string]$Name, [string[]]$Arguments) {
    $r = Invoke-ItpProcess $script:HostExe[$Name] $Arguments ''
    $script:HostOut = $r.Output
    $script:HostRc = $r.ExitCode
}

function Test-ItpSandboxHit([string]$Text) {
    return ($Text -match '(?i)sandbox initialization failed|operation not permitted')
}

function Write-ItpHostFailure([string]$Name, [string]$Command) {
    Write-ItpWarn "$(Get-ItpHostLabel $Name) を止めました。失敗したコマンド: ${Command} （終了コード $($script:HostRc)）"
    if ($script:HostOut) {
        foreach ($l in ($script:HostOut.TrimEnd() -split "`r?`n")) { Write-ItpError "    ${l}" }
    }
    if (Test-ItpSandboxHit $script:HostOut) {
        Write-ItpWarn 'ホストのサンドボックスの中では実行できません。通常の端末から、もう一度実行してください'
    }
    $script:Partial = $true
}

# 失敗したら報告して $false を返す
function Invoke-ItpHostStep([string]$Name, [string[]]$Arguments) {
    Invoke-ItpHost $Name $Arguments
    if ($script:HostRc -eq 0) { return $true }
    Write-ItpHostFailure $Name ("${Name} " + ($Arguments -join ' '))
    return $false
}

# 出力の中の `"キー": "値"` の値を集める（空白・改行の量に依らない）
function Get-ItpJsonValues([string]$Text, [string]$Key) {
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($Text, '"' + [regex]::Escape($Key) + '"\s*:\s*"([^"]*)"')) {
        $out.Add($m.Groups[1].Value)
    }
    return $out.ToArray()
}

function Get-ItpListIds([string]$Name) {
    $key = 'id'
    if ($Name -eq 'codex') { $key = 'pluginId' }
    return Get-ItpJsonValues $script:ListText[$Name] $key
}

function Test-ItpMarketplacePresent([string]$Name) {
    switch ($Name) {
        'claude' {
            Invoke-ItpHost 'claude' @('plugin', 'marketplace', 'list', '--json')
            if ($script:HostRc -ne 0) { return $false }
            return ($script:HostOut -match ('"name"\s*:\s*"' + [regex]::Escape($script:MpName) + '"'))
        }
        'codex' {
            Invoke-ItpHost 'codex' @('plugin', 'marketplace', 'list')
            if ($script:HostRc -ne 0) { return $false }
            return ($script:HostOut -match ('(?m)(^|[^A-Za-z0-9._-])' + [regex]::Escape($script:MpName) + '([^A-Za-z0-9._-]|$)'))
        }
    }
    return $false
}

# 外す前に、そのホストに登録があるかを確かめる（無ければ外す操作を呼ばない）。
# $true は登録あり（か、list が失敗して確かめられない）、$false は登録なし
function Test-ItpHostPluginRegistered([string]$Name, [string]$Plugin) {
    Invoke-ItpHost $Name @('plugin', 'list', '--json')
    if ($script:HostRc -ne 0) { return $true }
    $key = 'id'
    if ($Name -eq 'codex') { $key = 'pluginId' }
    $ids = @(Get-ItpJsonValues $script:HostOut $key)
    return ($ids -contains "${Plugin}@$($script:MpName)")
}

function Test-ItpMarketplaceRegistered([string]$Name) {
    if (Test-ItpMarketplacePresent $Name) { return $true }
    return ($script:HostRc -ne 0)
}

function Remove-ItpHostPlugin([string]$Name, [string]$Plugin) {
    if (-not (Test-ItpHostPluginRegistered $Name $Plugin)) { return $true }
    switch ($Name) {
        'claude' { return (Invoke-ItpHostStep 'claude' @('plugin', 'uninstall', "${Plugin}@$($script:MpName)", '--scope', 'user')) }
        'codex' { return (Invoke-ItpHostStep 'codex' @('plugin', 'remove', "${Plugin}@$($script:MpName)")) }
    }
    return $false
}

# ---------------------------------------------------------------- 前提・パスワード

function Test-ItpPrereqs {
    $missing = @()
    $tar = Get-Command tar -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($tar) { $script:TarExe = $tar.Source } else { $missing += 'tar' }
    if ($missing.Count -gt 0) {
        Stop-Itp 3 ('前提のコマンドが足りません: ' + ($missing -join ' '))
    }
    # 復号に使う Rfc2898DeriveBytes の SHA-256 版（byte[]・byte[]・int・HashAlgorithmName を取るコンストラクタ）は
    # .NET Framework 4.7.2 以降（PowerShell 7 は標準）にある。実際にあるかを確かめる
    $hashType = 'System.Security.Cryptography.HashAlgorithmName' -as [type]
    $ctor = $null
    if ($hashType) {
        $ctor = [System.Security.Cryptography.Rfc2898DeriveBytes].GetConstructor([Type[]]@([byte[]], [byte[]], [int], $hashType))
    }
    if (-not $ctor) {
        Stop-Itp 3 '.NET Framework 4.7.2 以降（または PowerShell 7）が要ります'
    }
}

# パスワードを UTF-8 のバイト列で返す。文字列の変数は残さない。環境変数は Start-Itp の最初に取って消してある
# （どの経路でも、子プロセスに渡さない）
function Read-ItpPassword {
    $secret = $script:EnvSecret
    $script:EnvSecret = $null
    if ([string]::IsNullOrEmpty($secret)) {
        if ([Console]::IsInputRedirected) {
            Stop-Itp 5 'パスワードがありません。環境変数 ITP_PASSWORD に入れるか、端末から実行してください'
        }
        $secure = Read-Host -AsSecureString 'パスワード'
        $bstr = [IntPtr]::Zero
        try {
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
            $secret = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        } finally {
            if ($bstr -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
            $secure.Dispose()
        }
    }
    if ([string]::IsNullOrEmpty($secret)) { Stop-Itp 5 'パスワードが空です' }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($secret)
    $secret = $null
    return , $bytes
}

# ---------------------------------------------------------------- 取得・検証・展開

function Get-ItpSha256([string]$File) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead($File)
    try {
        $hash = $sha.ComputeHash($stream)
    } finally {
        $stream.Dispose()
        $sha.Dispose()
    }
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Save-ItpFile([string]$Url, [string]$Dest) {
    try {
        if ($Url -match '^(?i)file:') {
            # PowerShell 7 の Invoke-WebRequest は file: を読めないので、ローカルのファイルを写す
            Copy-Item -LiteralPath ([System.Uri]$Url).LocalPath -Destination $Dest -ErrorAction Stop
        } else {
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            } catch { }
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Dest -ErrorAction Stop
        }
        return $true
    } catch {
        return $false
    }
}

function Get-ItpBundle {
    $base = $env:ITP_RELEASES_URL
    if (-not $base) { $base = $script:DefaultReleasesUrl }
    $base = $base.TrimEnd('/')
    if ($script:ReleaseTag) { $url = "${base}/download/$($script:ReleaseTag)" } else { $url = "${base}/latest/download" }
    $name = "itp-$($script:EditionName).tar.gz.enc"
    $script:EncFile = Join-Path $script:TmpRoot $name
    Write-ItpInfo "配布物を取得しています: ${url}"
    if (-not (Save-ItpFile "${url}/${name}" $script:EncFile)) {
        Stop-Itp 4 "配布物を取得できません: ${url}/${name}"
    }
    if (-not (Save-ItpFile "${url}/${name}.sha256" "$($script:EncFile).sha256")) {
        Stop-Itp 4 "SHA-256 のファイルを取得できません: ${url}/${name}.sha256"
    }
}

function Test-ItpDownload {
    $text = ''
    try { $text = [System.IO.File]::ReadAllText("$($script:EncFile).sha256") } catch { }
    $m = [regex]::Match($text, '^\s*([0-9a-fA-F]{64})(\s|$)')
    if (-not $m.Success) { Stop-Itp 4 'SHA-256 のファイルの形が正しくありません' }
    if ((Get-ItpSha256 $script:EncFile) -ne $m.Groups[1].Value.ToLowerInvariant()) {
        Stop-Itp 4 '配布物の SHA-256 が一致しません'
    }
}

# 1.3 の形式: Salted__ + 8バイトの塩 + AES-256-CBC（PKCS7）。PBKDF2-HMAC-SHA256・600000回で48バイトを導出し、
# 前の32バイトを鍵、後ろの16バイトを IV にする。パスワードのバイト列は使い終わったら消す
function Expand-ItpBundle {
    $script:TarFile = Join-Path $script:TmpRoot 'bundle.tar.gz'
    $ok = $false
    $pw = $script:PwBytes
    $script:PwBytes = $null
    $keyIv = $null
    try {
        $data = [System.IO.File]::ReadAllBytes($script:EncFile)
        if ($data.Length -lt 32 -or [System.Text.Encoding]::ASCII.GetString($data, 0, 8) -ne 'Salted__') {
            throw 'format'
        }
        $salt = New-Object byte[] 8
        [Array]::Copy($data, 8, $salt, 0, 8)
        $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($pw, $salt, 600000, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
        try { $keyIv = $kdf.GetBytes(48) } finally { $kdf.Dispose() }
        $key = New-Object byte[] 32
        $iv = New-Object byte[] 16
        [Array]::Copy($keyIv, 0, $key, 0, 32)
        [Array]::Copy($keyIv, 32, $iv, 0, 16)
        $aes = [System.Security.Cryptography.Aes]::Create()
        try {
            $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
            $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
            $aes.Key = $key
            $aes.IV = $iv
            $decryptor = $aes.CreateDecryptor()
            try { $plain = $decryptor.TransformFinalBlock($data, 16, $data.Length - 16) } finally { $decryptor.Dispose() }
        } finally {
            $aes.Dispose()
            [Array]::Clear($key, 0, $key.Length)
            [Array]::Clear($iv, 0, $iv.Length)
        }
        [System.IO.File]::WriteAllBytes($script:TarFile, $plain)
        $ok = $true
    } catch {
        $ok = $false
    } finally {
        [Array]::Clear($pw, 0, $pw.Length)
        if ($keyIv) { [Array]::Clear($keyIv, 0, $keyIv.Length) }
    }
    if (-not $ok) { Stop-Itp 5 '復号できません（パスワードが違う可能性があります）' }

    # 誤ったパスワードでも詰め物が通ることがあるので、tar として読めるかも確かめる
    $listing = Invoke-ItpProcess $script:TarExe @('-tzf', 'bundle.tar.gz') $script:TmpRoot
    if ($listing.ExitCode -ne 0) { Stop-Itp 5 '復号できません（パスワードが違う可能性があります）' }
    foreach ($entry in ($listing.Out -split "`r?`n")) {
        if ($entry -match '^/|^[A-Za-z]:|\\|(^|/)\.\.(/|$)') { Stop-Itp 4 '配布物に危険なパスが含まれています' }
    }
    $script:Stage = Join-Path $script:TmpRoot 'stage'
    New-Item -ItemType Directory -Path $script:Stage | Out-Null
    $extract = Invoke-ItpProcess $script:TarExe @('-xzf', 'bundle.tar.gz', '-C', 'stage') $script:TmpRoot
    if ($extract.ExitCode -ne 0) { Stop-Itp 4 '配布物を展開できません' }
    $script:Bundle = Join-Path $script:Stage 'itp-bundle'
    if (-not (Test-Path -LiteralPath $script:Bundle -PathType Container)) { Stop-Itp 4 '配布物に itp-bundle/ がありません' }
    $links = @(Get-ChildItem -LiteralPath $script:Bundle -Recurse -Force | Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint })
    if ($links.Count -gt 0) { Stop-Itp 4 '配布物にシンボリックリンクが含まれています' }
}

# bundle の中で SHA256SUMS の全行を照合し、載っていないファイルが無いことも確かめる
function Test-ItpSumsInBundle {
    $sums = Join-Path $script:Bundle 'SHA256SUMS'
    if (-not (Test-Path -LiteralPath $sums -PathType Leaf)) { return $false }
    $n = 0
    $seen = @{}   # 同じパスの行は拒む（ハッシュテーブルは大文字小文字を区別しない。Windows のファイル名に合わせる）
    foreach ($raw in [System.IO.File]::ReadAllLines($sums)) {
        $line = $raw.TrimEnd("`r")
        if (-not $line) { continue }
        $m = [regex]::Match($line, '^([0-9a-f]{64})  (.+)$')
        if (-not $m.Success) { return $false }
        $rel = $m.Groups[2].Value
        if ($seen.ContainsKey($rel)) { return $false }
        $seen[$rel] = $true
        if ($rel -match '^/|^[A-Za-z]:|\\|//|(^|/)\.{1,2}(/|$)') { return $false }
        $file = Join-Path $script:Bundle ($rel -replace '/', '\')
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $false }
        if ((Get-ItpSha256 $file) -ne $m.Groups[1].Value) { return $false }
        $n++
    }
    $files = @(Get-ChildItem -LiteralPath $script:Bundle -Recurse -Force -File)
    return ($files.Count -eq ($n + 1))
}

function Get-ItpBundleValue([string]$Key) {
    $file = Join-Path $script:Bundle 'BUNDLE.txt'
    foreach ($line in [System.IO.File]::ReadAllLines($file)) {
        if ($line.StartsWith("${Key}=", [System.StringComparison]::Ordinal)) {
            return $line.Substring($Key.Length + 1).TrimEnd("`r")
        }
    }
    return ''
}

function Test-ItpBundle {
    if (-not (Test-ItpSumsInBundle)) { Stop-Itp 4 '配布物の中身の SHA-256 の照合に失敗しました' }
    $fv = Get-ItpBundleValue 'format_version'
    if ($fv -ne [string]$script:FormatVersion) { Stop-Itp 4 "対応しない形式の配布物です（format_version=${fv}）" }
    if ((Get-ItpBundleValue 'edition') -ne $script:EditionName) { Stop-Itp 4 '配布物の系統が違います' }
    if ((Get-ItpBundleValue 'marketplace') -ne $script:MpName) { Stop-Itp 4 '配布物の marketplace の名前が違います' }
    $script:BundleVersion = Get-ItpBundleValue 'bundle_version'
    $catalogFile = Join-Path $script:Bundle 'catalog.tsv'
    if (-not (Test-Path -LiteralPath $catalogFile -PathType Leaf)) { Stop-Itp 4 '配布物に目録がありません' }
    $script:CatalogFile = $catalogFile
    $script:Catalog = Read-ItpCatalog $catalogFile
    if (-not (Test-Path -LiteralPath (Join-Path $script:Bundle 'marketplace') -PathType Container)) {
        Stop-Itp 4 '配布物に marketplace/ がありません'
    }
}

# ---------------------------------------------------------------- 選択

# 引数: 初期の選択（任意の項目の id）。選んだ集合を返す。q で終了コード0
function Select-ItpOptional($Initial) {
    $sel = @($Initial)
    while ($true) {
        Write-ItpInfo ''
        Write-ItpInfo '導入する項目を選んでください。'
        foreach ($id in $script:CatReq) {
            Write-ItpInfo "  [x] $((Get-ItpCatalogEntry $id).Label)（必須）"
        }
        $n = 0
        foreach ($id in $script:CatOpt) {
            $n++
            $mark = ' '
            if (Test-ItpIn $id $sel) { $mark = 'x' }
            Write-ItpInfo "  [${mark}] ${n}) $((Get-ItpCatalogEntry $id).Label)"
        }
        $line = Read-Host '番号で切り替え、空の行で決定、q で中止'
        if ($null -eq $line) { Stop-Itp 1 '端末の入力が閉じました' }
        if ($line -eq 'q' -or $line -eq 'Q') {
            Write-ItpInfo '中止しました。何も変更していません'
            throw 'ITP_EXIT:0'
        }
        if ($line -eq '') { return $sel }
        if ($line -notmatch '^[0-9]+$') {
            Write-ItpInfo '番号か q を入力してください'
            continue
        }
        $idx = [int]$line
        if ($idx -lt 1 -or $idx -gt @($script:CatOpt).Count) {
            Write-ItpInfo '範囲外の番号です'
            continue
        }
        $hit = @($script:CatOpt)[$idx - 1]
        if (Test-ItpIn $hit $sel) { $sel = @(Get-ItpMinus $sel @($hit)) } else { $sel = @(Get-ItpUnion $sel @($hit)) }
    }
}

function Select-ItpPlugins {
    $script:CatReq = @($script:Catalog | Where-Object { $_.Kind -eq 'required' } | ForEach-Object { $_.Id })
    $script:CatOpt = @($script:Catalog | Where-Object { $_.Kind -ne 'required' } | ForEach-Object { $_.Id })

    $prior = @()
    foreach ($id in (Split-ItpIds (Get-ItpState 'selected'))) {
        if (Get-ItpCatalogEntry $id) { $prior += $id }
    }
    $prior = @(Get-ItpMinus $prior $script:CatReq)

    if ($script:WithSet) {
        foreach ($id in $script:WithIds) {
            if (-not (Get-ItpCatalogEntry $id)) { Stop-Itp 2 "目録に無い id です: ${id}" }
        }
        $selOpt = @(Get-ItpMinus $script:WithIds $script:CatReq)
    } elseif (-not [Console]::IsInputRedirected) {
        $selOpt = @(Select-ItpOptional $prior)
    } else {
        $selOpt = $prior
    }
    $script:SelIds = @(Get-ItpInCatalogOrder (Get-ItpUnion $script:CatReq $selOpt))
    $plugins = @()
    foreach ($id in $script:SelIds) {
        $p = (Get-ItpCatalogEntry $id).Plugin
        if (-not (Test-Path -LiteralPath (Join-Path $script:Bundle "marketplace\plugins\${p}") -PathType Container)) {
            Stop-Itp 4 "配布物にプラグインがありません: ${p}"
        }
        $plugins += $p
    }
    $script:SelPlugins = $plugins
}

function Write-ItpPrereqWarnings {
    foreach ($id in $script:SelIds) {
        $e = Get-ItpCatalogEntry $id
        if (-not $e.Prereq -or $e.Prereq -eq '-') { continue }
        if (-not (Get-Command $e.Prereq -CommandType Application -ErrorAction SilentlyContinue)) {
            Write-ItpWarn "$($e.Label) の前提 $($e.PrereqLabel)（コマンド $($e.Prereq)）が PATH に見つかりません。登録は続けます"
        }
    }
}

# ---------------------------------------------------------------- 登録

# 別の出所の同名プラグインがあれば、そのホストを止める。止めなかったホストを ActiveHosts に積む
function Find-ItpDuplicates {
    $active = @()
    $script:ListText = @{}
    foreach ($hn in $script:PresentHosts) {
        Invoke-ItpHost $hn @('plugin', 'list', '--json')
        $script:ListText[$hn] = $script:HostOut
        if ($script:HostRc -ne 0) {
            Write-ItpHostFailure $hn "${hn} plugin list --json"
            continue
        }
        $ids = @(Get-ItpListIds $hn)
        $dup = @()
        foreach ($p in $script:SelPlugins) {
            foreach ($id in $ids) {
                if ($id.StartsWith("${p}@", [System.StringComparison]::Ordinal) -and $id -ne "${p}@$($script:MpName)") {
                    $dup += $id
                }
            }
        }
        if ($dup.Count -gt 0) {
            Write-ItpWarn "$(Get-ItpHostLabel $hn) を止めました。別の出所の同名のプラグインが入っています: $($dup -join ' ')"
            foreach ($d in $dup) {
                if ($hn -eq 'claude') { Write-ItpWarn "  外すには: claude plugin uninstall ${d} --scope user" }
                else { Write-ItpWarn "  外すには: codex plugin remove ${d}" }
            }
            Write-ItpWarn '外してから、もう一度実行してください'
            $script:Partial = $true
            continue
        }
        $active += $hn
    }
    $script:ActiveHosts = $active
}

# marketplace.new\ に写して今の marketplace\ と入れ替える（今の版は backup\<時刻>\ へ移す）
function Install-ItpMarketplace {
    $new = Join-Path $script:DistDir 'marketplace.new'
    try {
        New-Item -ItemType Directory -Force -Path $script:DistDir | Out-Null
        if (Test-Path -LiteralPath $new) { Remove-Item -LiteralPath $new -Recurse -Force }
        New-Item -ItemType Directory -Path $new | Out-Null
        Get-ChildItem -LiteralPath (Join-Path $script:Bundle 'marketplace') -Force |
            Copy-Item -Destination $new -Recurse -Force
        Copy-Item -LiteralPath $script:CatalogFile -Destination (Join-Path $script:DistDir 'catalog.tsv') -Force
    } catch {
        Stop-Itp 1 '配布物を置き先へ写せません'
    }
    $backup = ''
    if (Test-Path -LiteralPath $script:MpDir) {
        try {
            $backupRoot = Join-Path $script:DistDir 'backup'
            New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $backup = Join-Path $backupRoot $stamp
            $i = 1
            while (Test-Path -LiteralPath $backup) {
                $backup = Join-Path $backupRoot "${stamp}-${i}"
                $i++
            }
            Move-Item -LiteralPath $script:MpDir -Destination $backup
        } catch {
            Stop-Itp 1 '前の版を backup\ へ移せません'
        }
    }
    try {
        Move-Item -LiteralPath $new -Destination $script:MpDir
    } catch {
        if ($backup) { Move-Item -LiteralPath $backup -Destination $script:MpDir -ErrorAction SilentlyContinue }
        Stop-Itp 1 '新しい版を置けません'
    }
    if ($backup) { Write-ItpInfo "前の版を保全しました: ${backup}" }
}

function Register-ItpHost([string]$Name) {
    $mp = $script:MpName
    switch ($Name) {
        'claude' {
            if (Test-ItpMarketplacePresent 'claude') {
                if (-not (Invoke-ItpHostStep 'claude' @('plugin', 'marketplace', 'update', $mp))) { return $false }
            } else {
                if (-not (Invoke-ItpHostStep 'claude' @('plugin', 'marketplace', 'add', $script:MpDir, '--scope', 'user'))) { return $false }
            }
            $ids = @(Get-ItpListIds 'claude')
            foreach ($p in $script:SelPlugins) {
                if ($ids -contains "${p}@${mp}") {
                    if (-not (Invoke-ItpHostStep 'claude' @('plugin', 'uninstall', "${p}@${mp}", '--scope', 'user'))) { return $false }
                }
                if (-not (Invoke-ItpHostStep 'claude' @('plugin', 'install', "${p}@${mp}", '--scope', 'user'))) { return $false }
            }
        }
        'codex' {
            if (-not (Test-ItpMarketplacePresent 'codex')) {
                if (-not (Invoke-ItpHostStep 'codex' @('plugin', 'marketplace', 'add', $script:MpDir))) { return $false }
            }
            foreach ($p in $script:SelPlugins) {
                if (-not (Invoke-ItpHostStep 'codex' @('plugin', 'add', "${p}@${mp}"))) { return $false }
            }
        }
    }
    Write-ItpInfo "$(Get-ItpHostLabel $Name): 登録しました（$($script:SelPlugins -join ' ')）"
    return $true
}

# ---------------------------------------------------------------- 外す

# state の hosts のうち、いま CLI があるもの。CLI が無いホストは登録を外せないので、MissingHost を立て、
# Partial にする（呼び出し側は、片付け・state の更新をしない）
function Get-ItpStateHostsPresent {
    $out = @()
    foreach ($hn in (Split-ItpIds (Get-ItpState 'hosts'))) {
        if (Test-ItpIn $hn $script:PresentHosts) {
            $out += $hn
        } else {
            Write-ItpWarn "$(Get-ItpHostLabel $hn) の CLI が見つかりません。登録は外せませんでした"
            $script:MissingHost = $true
            $script:Partial = $true
        }
    }
    return $out
}

function Invoke-ItpRemove {
    $catalogFile = Join-Path $script:DistDir 'catalog.tsv'
    $script:Catalog = $null
    if (Test-Path -LiteralPath $catalogFile -PathType Leaf) { $script:Catalog = Read-ItpCatalog $catalogFile }
    $required = @('common')
    foreach ($e in @($script:Catalog)) {
        if ($e.Kind -eq 'required') { $required += $e.Id }
    }
    foreach ($id in $script:RemoveIds) {
        if (Test-ItpIn $id $required) { Stop-Itp 2 "必須の項目は外せません: ${id}" }
        if ($script:Catalog -and -not (Get-ItpCatalogEntry $id)) { Stop-Itp 2 "目録に無い id です: ${id}" }
    }

    Find-ItpHosts
    $installed = @(Split-ItpIds (Get-ItpState 'installed'))
    $hosts = @(Get-ItpStateHostsPresent)
    $removed = @()
    foreach ($id in $script:RemoveIds) {
        if (-not (Test-ItpIn $id $installed)) {
            Write-ItpInfo "入っていません: ${id}"
            continue
        }
        $plugin = Get-ItpPluginOf $id
        $failed = $script:MissingHost
        foreach ($hn in $hosts) {
            if (-not (Remove-ItpHostPlugin $hn $plugin)) { $failed = $true }
        }
        if (-not $failed) {
            $removed += $id
            Write-ItpInfo "外しました: ${id}"
        } else {
            Write-ItpWarn "外せなかったので、state には残しました: ${id}"
        }
    }
    if ((Test-Path -LiteralPath (Join-Path $script:DistDir 'state') -PathType Leaf) -and $removed.Count -gt 0) {
        Write-ItpState (Get-ItpState 'bundle_version') `
            @(Get-ItpMinus (Split-ItpIds (Get-ItpState 'selected')) $removed) `
            @(Get-ItpMinus $installed $removed) `
            (Split-ItpIds (Get-ItpState 'hosts'))
    }
}

function Invoke-ItpUninstall {
    $catalogFile = Join-Path $script:DistDir 'catalog.tsv'
    $script:Catalog = $null
    if (Test-Path -LiteralPath $catalogFile -PathType Leaf) { $script:Catalog = Read-ItpCatalog $catalogFile }
    Find-ItpHosts
    $installed = @(Split-ItpIds (Get-ItpState 'installed'))
    $hosts = @(Get-ItpStateHostsPresent)
    foreach ($hn in $hosts) {
        foreach ($id in $installed) {
            [void](Remove-ItpHostPlugin $hn (Get-ItpPluginOf $id))
        }
        if (Test-ItpMarketplaceRegistered $hn) {
            [void](Invoke-ItpHostStep $hn @('plugin', 'marketplace', 'remove', $script:MpName))
        }
    }
    if ($script:Partial) {
        Write-ItpWarn '外せなかった登録があるので、置き先は片付けませんでした。原因を直して、もう一度実行してください'
        return
    }
    foreach ($name in @('marketplace', 'marketplace.new', 'state', 'state.new', 'catalog.tsv', 'opencode-files')) {
        $target = Join-Path $script:DistDir $name
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
    }
    Write-ItpInfo "登録を外し、置き先を片付けました（backup\ は残しています）: $($script:DistDir)"
}

# ---------------------------------------------------------------- 導入

function Invoke-ItpInstall {
    Test-ItpPrereqs
    Find-ItpHosts
    if (@($script:PresentHosts).Count -eq 0) { Stop-Itp 3 '対象のホスト（claude・codex）が PATH に見つかりません' }
    $script:PwBytes = Read-ItpPassword

    $script:TmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('itp-install.' + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $script:TmpRoot | Out-Null
    } catch {
        Stop-Itp 1 '作業用の一時フォルダを作れません'
    }
    Get-ItpBundle
    Test-ItpDownload
    Expand-ItpBundle
    Test-ItpBundle
    Select-ItpPlugins
    Write-ItpPrereqWarnings

    Find-ItpDuplicates
    if (@($script:ActiveHosts).Count -eq 0) {
        Write-ItpWarn '登録できるホストが無いので、何も変更しませんでした'
        throw 'ITP_EXIT:6'
    }

    Install-ItpMarketplace
    $okHosts = @()
    foreach ($hn in $script:ActiveHosts) {
        if (Register-ItpHost $hn) { $okHosts += $hn }
    }

    if ($okHosts.Count -gt 0) {
        # 前回までに登録したホストは、今回の登録に失敗・停止しても残す
        $oldHosts = @(Split-ItpIds (Get-ItpState 'hosts'))
        Write-ItpState $script:BundleVersion $script:SelIds `
            @(Get-ItpInCatalogOrder (Get-ItpUnion (Split-ItpIds (Get-ItpState 'installed')) $script:SelIds)) `
            @(Get-ItpUnion $okHosts $oldHosts)
        Write-ItpInfo "導入が終わりました（版 $($script:BundleVersion)）。Claude Code・Codex は新しいセッションから使えます"
    }

    $have = @(Get-ItpUnion (Split-ItpIds (Get-ItpState 'installed')) $script:SelIds)
    $later = @()
    foreach ($id in $script:CatOpt) {
        if (-not (Test-ItpIn $id $have)) { $later += "$((Get-ItpCatalogEntry $id).Label)（-With ${id}）" }
    }
    if ($later.Count -gt 0) {
        Write-ItpInfo ('任意の項目: ' + ($later -join ' ') + ' は、必要になったら -With を付けて、もう一度実行すると追加できます')
    }
}

# ---------------------------------------------------------------- 本体

function Start-Itp {
    param(
        [string]$EditionArg,
        [bool]$WithSet,
        [string]$WithText,
        [string]$RemoveText,
        [bool]$DoUninstall,
        [string]$Tag,
        [bool]$ShowHelp,
        $ExtraArgs
    )
    $ErrorActionPreference = 'Stop'
    $script:DefaultReleasesUrl = 'https://github.com/usk0913/itp-dist/releases'
    $script:FormatVersion = 1
    $script:Partial = $false
    $script:TmpRoot = ''
    $script:PwBytes = $null
    $script:MissingHost = $false
    $script:OutWriter = $null
    $script:ErrWriter = $null
    # パスワードは最初に環境変数から取り、環境変数は消す（-Remove・-Uninstall を含むどの経路でも、子プロセスに渡さない）
    $script:EnvSecret = $env:ITP_PASSWORD
    Remove-Item -LiteralPath 'Env:\ITP_PASSWORD' -ErrorAction SilentlyContinue
    $rc = 0
    try {
        Initialize-ItpOutput
        if ($ShowHelp) {
            Show-ItpUsage
            return 0
        }

        # 引数
        $extra = @($ExtraArgs | Where-Object { $null -ne $_ })
        foreach ($x in $extra) {
            if ("$x" -like '-Password*') {
                Stop-Itp 2 '-Password は受け付けません。パスワードは環境変数 ITP_PASSWORD か端末から渡してください'
            }
        }
        if ($extra.Count -gt 0) { Stop-Itp 2 '不明な引数があります（-Help で使い方を表示します）' }
        if ($EditionArg -cne 'dist' -and $EditionArg -cne 'self') { Stop-Itp 2 '-Edition は dist か self です' }
        $script:EditionName = $EditionArg
        $script:WithSet = $WithSet
        if ($WithText -notmatch '^[A-Za-z0-9._ ,-]*$') { Stop-Itp 2 '-With に使えない文字があります' }
        if ($RemoveText -notmatch '^[A-Za-z0-9._ ,-]*$') { Stop-Itp 2 '-Remove に使えない文字があります' }
        if ($Tag -notmatch '^[A-Za-z0-9._-]*$') { Stop-Itp 2 '-Version のタグに使えない文字があります' }
        $script:WithIds = @(Split-ItpIds $WithText)
        $script:RemoveIds = @(Split-ItpIds $RemoveText)
        $script:ReleaseTag = $Tag
        if ($DoUninstall -and ($script:RemoveIds.Count -gt 0 -or $WithSet)) {
            Stop-Itp 2 '-Uninstall は -With・-Remove と同時に使えません'
        }
        if ($script:RemoveIds.Count -gt 0 -and $WithSet) { Stop-Itp 2 '-Remove は -With と同時に使えません' }

        # 置き先
        $base = $env:LOCALAPPDATA
        if (-not $base -or -not [System.IO.Path]::IsPathRooted($base)) {
            Stop-Itp 1 '置き先の元（LOCALAPPDATA）が絶対パスではありません'
        }
        $script:MpName = 'itp-' + $script:EditionName
        $script:DistDir = Join-Path (Join-Path $base 'itp') $script:EditionName
        $script:MpDir = Join-Path $script:DistDir 'marketplace'
        if ($script:EditionName -eq 'self') { Stop-Itp 1 '-Edition self は Windows 版では対応していません' }

        if ($DoUninstall) { Invoke-ItpUninstall }
        elseif ($script:RemoveIds.Count -gt 0) { Invoke-ItpRemove }
        else { Invoke-ItpInstall }

        if ($script:Partial) { $rc = 6 }
    } catch {
        $m = $_.Exception.Message
        if ($m -match '^ITP_EXIT:(\d+)$') {
            $rc = [int]$Matches[1]
        } else {
            Write-ItpError "エラー: ${m}"
            $rc = 1
        }
    } finally {
        $script:EnvSecret = $null
        if ($script:PwBytes) { [Array]::Clear($script:PwBytes, 0, $script:PwBytes.Length); $script:PwBytes = $null }
        if ($script:TmpRoot -and (Test-Path -LiteralPath $script:TmpRoot)) {
            Remove-Item -LiteralPath $script:TmpRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    return $rc
}

$itpRc = Start-Itp -EditionArg $Edition -WithSet ($PSBoundParameters.ContainsKey('With')) -WithText $With `
    -RemoveText $Remove -DoUninstall ([bool]$Uninstall) -Tag $Version -ShowHelp ([bool]$Help) -ExtraArgs $Rest
if ($PSCommandPath) { exit $itpRc } else { $global:LASTEXITCODE = $itpRc }
