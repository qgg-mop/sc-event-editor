#Requires -Version 5.1
<#
  serve.ps1
  零依賴的本機靜態伺服器（不用 python / node）。
  用途：讓播放器能用 http:// 讀取匯出好的素材（file:// 會被瀏覽器的 CORS 擋）。

  範例：
    .\serve.ps1                                  # 服務本腳本旁的 assets 資料夾，埠 8000
    .\serve.ps1 -Root D:\事件編輯器 -Port 8080       # 服務整個工作區
    .\serve.ps1 -Root D:\事件編輯器 -Port 8080 -Open # 順便開瀏覽器

  停止：在這個視窗按 Ctrl+C。
#>
[CmdletBinding()]
param(
  [int]$Port = 8000,
  [string]$Root,
  [switch]$Open,
  [string]$OpenPath
)

$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Join-Path $PSScriptRoot 'assets' }
if (-not (Test-Path $Root)) { throw "找不到資料夾：$Root（先跑 export-assets.ps1）" }

$rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
$types = @{
  '.html' = 'text/html; charset=utf-8'
  '.htm'  = 'text/html; charset=utf-8'
  '.js'   = 'application/javascript; charset=utf-8'
  '.css'  = 'text/css; charset=utf-8'
  '.json' = 'application/json; charset=utf-8'
  '.atlas'= 'text/plain; charset=utf-8'
  '.txt'  = 'text/plain; charset=utf-8'
  '.md'   = 'text/plain; charset=utf-8'
  '.png'  = 'image/png'
  '.jpg'  = 'image/jpeg'
  '.jpeg' = 'image/jpeg'
  '.gif'  = 'image/gif'
  '.webp' = 'image/webp'
  '.svg'  = 'image/svg+xml'
  '.ico'  = 'image/x-icon'
  '.m4a'  = 'audio/mp4'
  '.mp3'  = 'audio/mpeg'
  '.wav'  = 'audio/wav'
  '.ogg'  = 'audio/ogg'
  '.mp4'  = 'video/mp4'
  '.ttf'  = 'font/ttf'
  '.woff' = 'font/woff'
  '.woff2'= 'font/woff2'
}

function Send-Bytes($stream, [byte[]]$body, [string]$ctype, [string]$status, [string]$extra = '') {
  $head = "HTTP/1.1 $status`r`n" +
          "Content-Type: $ctype`r`n" +
          "Content-Length: $($body.Length)`r`n" +
          "Accept-Ranges: bytes`r`n" +
          "Cache-Control: no-cache`r`n" +
          "Access-Control-Allow-Origin: *`r`n" +
          "Connection: close`r`n" + $extra + "`r`n"
  $hb = [Text.Encoding]::ASCII.GetBytes($head)
  $stream.Write($hb, 0, $hb.Length)
  $stream.Write($body, 0, $body.Length)
  $stream.Flush()
}

  # ---------- TTS 後端：讀 POST 內容 ----------
  function Read-BodyText($stream, $text, $buffer, $read) {
    $cm = [regex]::Match($text, '(?im)^Content-Length:\s*(\d+)\s*$')
    $bodyLen = if ($cm.Success) { [int64]$cm.Groups[1].Value } else { 0 }
    if ($bodyLen -le 0) { return '' }
    if ($text -match '(?im)^Expect:\s*100-continue') {
      $cont = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 100 Continue`r`n`r`n")
      $stream.Write($cont, 0, $cont.Length)
      $stream.Flush()
    }
    $hdrEnd = $text.IndexOf("`r`n`r`n")
    $bodyStart = if ($hdrEnd -ge 0) { $hdrEnd + 4 } else { $read }
    $body = New-Object byte[] $bodyLen
    $got = [Math]::Max(0, [Math]::Min($bodyLen, $read - $bodyStart))
    if ($got -gt 0) { [Array]::Copy($buffer, $bodyStart, $body, 0, $got) }
    while ($got -lt $bodyLen) {
      $n = $stream.Read($body, $got, $bodyLen - $got)
      if ($n -le 0) { break }
      $got += $n
    }
    return [Text.Encoding]::UTF8.GetString($body, 0, $got)
  }

  function Read-JsonObj([string]$s) {
    if (-not $s) { return $null }
    try { return $s | ConvertFrom-Json } catch { return $null }
  }

  # 對外 HTTP（關掉 proxy，localhost 探測才不會被系統代理拖慢）
  function Invoke-HttpJson([string]$method, [string]$url, $bodyObj, [int]$timeoutSec = 10, $headers = @{}, [string]$contentType = 'application/json') {
    $req = [System.Net.HttpWebRequest]::Create($url)
    $req.Method = $method
    $req.Proxy = $null
    $req.Timeout = $timeoutSec * 1000
    $req.ReadWriteTimeout = $timeoutSec * 1000
    if ($bodyObj -ne $null) {
      $req.ContentType = $contentType
    }
    foreach ($k in $headers.Keys) { $req.Headers[$k] = [string]$headers[$k] }
    if ($bodyObj -ne $null) {
      $json = if ($bodyObj -is [string]) { $bodyObj } else { $bodyObj | ConvertTo-Json -Depth 8 -Compress }
      $bb = [Text.Encoding]::UTF8.GetBytes($json)
      $req.ContentLength = $bb.Length
      $rs = $req.GetRequestStream()
      $rs.Write($bb, 0, $bb.Length)
      $rs.Close()
    }
    $resp = $req.GetResponse()
    $ms = New-Object IO.MemoryStream
    $resp.GetResponseStream().CopyTo($ms)
    $resp.Close()
    return , $ms.ToArray()
  }

  function Get-ShaHex([string]$s) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $b = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($s))
    return (([byte[]]$b | ForEach-Object { $_.ToString('x2') }) -join '')
  }

  function Get-TtsKeys($rootFull) {
    $p = Join-Path $rootFull 'tts-keys.json'
    if (Test-Path $p) { try { return Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
    return New-Object PSObject
  }

  # /tts/generate：送出背景生成工作（模型切換可能超過 20 秒，長連線會被中斷，所以改成工作＋輪詢）
  # /tts/scan：掃描 127.0.0.1 上常見的 TTS 服務（Irodori／VOICEVOX／AivisSpeech／GPT-SoVITS／OpenAI 相容）
  function Invoke-TtsScan() {
    function Try-Get([string]$url, [int]$timeout = 800) {
      try {
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.Proxy = $null
        $req.Timeout = $timeout
        $req.ReadWriteTimeout = $timeout
        $resp = $req.GetResponse()
        $ms = New-Object IO.MemoryStream
        $resp.GetResponseStream().CopyTo($ms)
        $resp.Close()
        return [Text.Encoding]::UTF8.GetString($ms.ToArray())
      } catch { return $null }
    }
    $found = New-Object System.Collections.ArrayList
    foreach ($port in 8088, 9880) {
      $h = Try-Get ("http://127.0.0.1:" + $port + "/health")
      if ($h -and $h -match '"model"') {
        $voices = @(); $models = @()
        $v = Try-Get ("http://127.0.0.1:" + $port + "/voices")
        if ($v) { try { $vj = $v | ConvertFrom-Json; foreach ($x in @($vj.voices)) { $voices += @{ id = [string]$x.id; label = ([string]$x.character + '・' + [string]$x.id) } } } catch {} }
        $m = Try-Get ("http://127.0.0.1:" + $port + "/models")
        if ($m) { try { $mj = $m | ConvertFrom-Json; foreach ($x in @($mj.models)) { $models += [string]$x.id } } catch {} }
        $null = $found.Add(@{ engine = 'irodori'; label = 'Irodori TTS'; base = ("http://127.0.0.1:" + $port); version = ''; voices = $voices; models = $models })
      }
    }
    foreach ($port in 50021, 10101) {
      $ver = Try-Get ("http://127.0.0.1:" + $port + "/version")
      if ($ver) {
        $voices = @()
        $sp = Try-Get ("http://127.0.0.1:" + $port + "/speakers")
        if ($sp) {
          try {
            $sj = $sp | ConvertFrom-Json
            foreach ($spk in @($sj)) {
              foreach ($st in @($spk.styles)) { $voices += @{ id = [string]$st.id; label = ([string]$spk.name + '・' + [string]$st.name) } }
            }
          } catch {}
        }
        $eng = if ($port -eq 50021) { 'voicevox' } else { 'aivis' }
        $lbl = if ($eng -eq 'voicevox') { 'VOICEVOX' } else { 'AivisSpeech' }
        $null = $found.Add(@{ engine = $eng; label = $lbl; base = ("http://127.0.0.1:" + $port); version = ([string]$ver).Trim('"'); voices = $voices; models = @() })
      }
    }
    foreach ($port in 9880, 9881) {
      $o = Try-Get ("http://127.0.0.1:" + $port + "/openapi.json")
      if ($o -and $o -match '"/tts"') {
        $null = $found.Add(@{ engine = 'gpt-sovits'; label = 'GPT-SoVITS'; base = ("http://127.0.0.1:" + $port); version = 'api_v2'; voices = @(); models = @() })
      }
    }
    foreach ($port in 8080, 5000, 8000, 8001, 8880) {
      $m = Try-Get ("http://127.0.0.1:" + $port + "/v1/models")
      if ($m) {
        try {
          $mj = $m | ConvertFrom-Json
          if ($mj.data) {
            $ids = @(); foreach ($x in @($mj.data)) { $ids += [string]$x.id }
            $null = $found.Add(@{ engine = 'openai'; label = 'OpenAI 相容'; base = ("http://127.0.0.1:" + $port); version = ''; voices = @(); models = $ids })
          }
        } catch {}
      }
    }
    return (@{ ok = $true; found = @($found) } | ConvertTo-Json -Depth 8 -Compress)
  }

  function Invoke-TtsGenerateAsync($rootFull, $body) {
    $j = Read-JsonObj $body
    if (-not $j -or -not $j.text) { throw '缺少 text' }
    $jobId = [Guid]::NewGuid().ToString('N').Substring(0, 20)
    $bodyFile = Join-Path $env:TEMP ('tts-body-' + $jobId + '.json')
    $outFile = Join-Path $env:TEMP ('tts-job-' + $jobId + '.json')
    if (Test-Path $outFile) { Remove-Item $outFile -Force -ErrorAction SilentlyContinue }
    [IO.File]::WriteAllText($bodyFile, $body, (New-Object Text.UTF8Encoding($false)))
    $gen = Join-Path $PSScriptRoot 'tts-generate.ps1'
    $null = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru -ArgumentList @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
      '-File', ('"{0}"' -f $gen),
      '-Root', ('"{0}"' -f $rootFull),
      '-BodyFile', ('"{0}"' -f $bodyFile),
      '-OutFile', ('"{0}"' -f $outFile)
    )
    return (@{ ok = $true; job = $jobId; pending = $true } | ConvertTo-Json)
  }

  function Invoke-TtsResult($rootFull, $jobId) {
    if (-not ($jobId -match '^[a-f0-9]{6,32}$')) { throw 'bad job id' }
    $outFile = Join-Path $env:TEMP ('tts-job-' + $jobId + '.json')
    if (Test-Path $outFile) {
      $txt = Get-Content $outFile -Raw -Encoding UTF8
      # 成功的結果讀過就清掉（快取檔還在，重生成會秒回）
      $j = Read-JsonObj $txt
      if ($j -and $j.ok) { Remove-Item $outFile -Force -ErrorAction SilentlyContinue }
      return $txt
    }
    return (@{ ok = $true; pending = $true } | ConvertTo-Json)
  }

  # /tts/test：用一句測試文本實際生成一次（同樣走背景工作）
  function Invoke-TtsTest($rootFull, $body) {
    $j = Read-JsonObj $body
    if (-not $j) { throw 'invalid json' }
    $j | Add-Member -NotePropertyName text -NotePropertyValue 'テスト、マイクの音確認。' -Force
    return Invoke-TtsGenerateAsync $rootFull ($j | ConvertTo-Json -Depth 8)
  }

  # /tts/keys：雲端 Key 只存在伺服器端（tts-keys.json），永遠不回傳 Key 本體
  function Invoke-TtsKeysSet($rootFull, $body) {
    $j = Read-JsonObj $body
    if (-not $j) { throw 'invalid json' }
    $keys = Get-TtsKeys $rootFull
    $provider = [string]$j.provider
    if ($provider -eq 'elevenlabs') {
      if ($j.clear) { $keys.PSObject.Properties.Remove('elevenlabs') }
      elseif ($j.key) { $keys | Add-Member -NotePropertyName elevenlabs -NotePropertyValue ([string]$j.key) -Force }
    } elseif ($provider -eq 'azure') {
      if ($j.clear) { $keys.PSObject.Properties.Remove('azure') }
      else {
        $a = @{}
        if ($keys.azure) { $a.key = [string]$keys.azure.key; $a.region = [string]$keys.azure.region }
        if ($j.key) { $a.key = [string]$j.key }
        if ($j.region) { $a.region = [string]$j.region }
        if (-not $a.key) { throw '缺少 API Key' }
        $keys | Add-Member -NotePropertyName azure -NotePropertyValue (New-Object PSObject -Property $a) -Force
      }
    } elseif ($provider -eq 'custom') {
      if ($j.clear) { $keys.PSObject.Properties.Remove('custom') }
      else {
        $a = @{}
        if ($keys.custom) { $a.key = [string]$keys.custom.key; $a.endpoint = [string]$keys.custom.endpoint }
        if ($j.key) { $a.key = [string]$j.key }
        if ($j.endpoint) { $a.endpoint = [string]$j.endpoint }
        if (-not $a.key -or -not $a.endpoint) { throw '缺少 API Key / Endpoint' }
        $keys | Add-Member -NotePropertyName custom -NotePropertyValue (New-Object PSObject -Property $a) -Force
      }
    } else {
      throw ('未知供應商：' + $provider)
    }
    $keys | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $rootFull 'tts-keys.json') -Encoding UTF8
    return (@{ ok = $true } | ConvertTo-Json)
  }

  function Invoke-TtsKeysStatus($rootFull) {
    $keys = Get-TtsKeys $rootFull
    $st = @{ elevenlabs = [bool]$keys.elevenlabs; azure = $false; azureRegion = ''; custom = $false; customEndpoint = '' }
    if ($keys.azure -and $keys.azure.key) { $st.azure = $true; $st.azureRegion = [string]$keys.azure.region }
    if ($keys.custom -and $keys.custom.key) { $st.custom = $true; $st.customEndpoint = [string]$keys.custom.endpoint }
    return (@{ ok = $true; status = $st } | ConvertTo-Json -Depth 4)
  }

  # /tts/test：改用背景工作，見上方 Invoke-TtsTest


  function Invoke-TtsRoute([string]$target, [string]$method, [string]$body, [string]$rootFull, [string]$query) {
    if ($target -eq '/tts/scan') { return Invoke-TtsScan }
    if ($target -eq '/tts/generate') { return Invoke-TtsGenerateAsync $rootFull $body }
    if ($target -eq '/tts/keys') { if ($method -eq 'GET') { return Invoke-TtsKeysStatus $rootFull } else { return Invoke-TtsKeysSet $rootFull $body } }
    if ($target -eq '/tts/test') { return Invoke-TtsTest $rootFull $body }
    if ($target -eq '/tts/result') {
      $job = ''
      if ($query -match '(^|&)job=([^&]+)') { $job = [Uri]::UnescapeDataString($Matches[2]) }
      return Invoke-TtsResult $rootFull $job
    }
    throw ('未知 TTS 端點：' + $target)
  }

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
try { $listener.Start() }
catch {
  Write-Host ("連接埠 {0} 被佔用，換一個試試（-Port 8081）" -f $Port) -ForegroundColor Red
  exit 1
}

Write-Host ''
Write-Host '  本機靜態伺服器' -ForegroundColor Cyan
Write-Host ("  根目錄：{0}" -f $rootFull)
Write-Host ("  網址　：http://localhost:{0}/" -f $Port) -ForegroundColor Green
Write-Host '  停止　：Ctrl+C'
Write-Host ''

if ($Open) {
  $u = "http://localhost:{0}/" -f $Port
  if ($OpenPath) { $u = $u + $OpenPath.TrimStart('/') }
  Start-Process $u | Out-Null
}

while ($true) {
  $client = $listener.AcceptTcpClient()
  try {
    $stream = $client.GetStream()
    $stream.ReadTimeout = 5000
    $buffer = New-Object byte[] 8192
    $read = $stream.Read($buffer, 0, $buffer.Length)
    if ($read -le 0) { continue }

    $text = [Text.Encoding]::ASCII.GetString($buffer, 0, $read)
    $rmSuccess = $false; $rangeStart = -1; $rangeEnd = -1
    $rm = [regex]::Match($text, '(?im)^Range:\s*bytes=(\d*)-(\d*)\s*$')
    if ($rm.Success -and $rm.Groups[1].Value -ne '') {
      $rmSuccess = $true
      $rangeStart = [int64]$rm.Groups[1].Value
      if ($rm.Groups[2].Value -ne '') { $rangeEnd = [int64]$rm.Groups[2].Value }
    }
    $first = ($text -split "`r`n")[0]
    $parts = $first -split ' '
    $rawTarget = if ($parts.Count -ge 2) { $parts[1] } else { '/' }
    $query = ''
    $qi = $rawTarget.IndexOf('?')
    if ($qi -ge 0) { $query = $rawTarget.Substring($qi + 1); $rawTarget = $rawTarget.Substring(0, $qi) }
    $target = [Uri]::UnescapeDataString($rawTarget)
    if ($target -eq '/' -or $target -eq '') { $target = '/index.html' }

    $method = if ($parts.Count -ge 1 -and $parts[0]) { $parts[0].ToUpperInvariant() } else { 'GET' }

    # 事件編輯器的「清除」：刪掉上次保存的劇本
    if ($method -eq 'DELETE' -and $target -eq '/sc-editor/saved-project.json') {
      $savePath = Join-Path $rootFull 'sc-editor\saved-project.json'
      if (Test-Path $savePath) { Remove-Item -LiteralPath $savePath -Force }
      Send-Bytes $stream ([Text.Encoding]::UTF8.GetBytes('{"ok":true}')) 'application/json; charset=utf-8' '200 OK'
      Write-Host ("  200  DELETE {0}" -f $target) -ForegroundColor DarkGray
      continue
    }

    # 事件編輯器的「保存」：POST 一份劇本，寫成 sc-editor/saved-project.json
    if ($method -eq 'POST' -and $target -eq '/sc-editor/saved-project.json') {
      $cm = [regex]::Match($text, '(?im)^Content-Length:\s*(\d+)\s*$')
      $bodyLen = if ($cm.Success) { [int64]$cm.Groups[1].Value } else { 0 }
      if ($bodyLen -le 0 -or $bodyLen -gt 64MB) {
        Send-Bytes $stream ([Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"empty body"}')) 'application/json; charset=utf-8' '400 Bad Request'
        Write-Host ("  400  POST {0}  (empty body)" -f $target) -ForegroundColor DarkYellow
        continue
      }

      if ($text -match '(?im)^Expect:\s*100-continue') {
        $cont = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 100 Continue`r`n`r`n")
        $stream.Write($cont, 0, $cont.Length)
        $stream.Flush()
      }

      $hdrEnd = $text.IndexOf("`r`n`r`n")
      $bodyStart = if ($hdrEnd -ge 0) { $hdrEnd + 4 } else { $read }
      $body = New-Object byte[] $bodyLen
      $got = [Math]::Max(0, [Math]::Min($bodyLen, $read - $bodyStart))
      if ($got -gt 0) { [Array]::Copy($buffer, $bodyStart, $body, 0, $got) }
      while ($got -lt $bodyLen) {
        $n = $stream.Read($body, $got, $bodyLen - $got)
        if ($n -le 0) { break }
        $got += $n
      }

      $jsonText = [Text.Encoding]::UTF8.GetString($body, 0, $got)
      $valid = $false
      try { $null = $jsonText | ConvertFrom-Json; $valid = $true } catch {}
      if (-not $valid) {
        Send-Bytes $stream ([Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"invalid json"}')) 'application/json; charset=utf-8' '400 Bad Request'
        Write-Host ("  400  POST {0}  (invalid json)" -f $target) -ForegroundColor DarkYellow
        continue
      }

      $savePath = Join-Path $rootFull 'sc-editor\saved-project.json'
      $tmpPath = $savePath + '.tmp'
      [IO.File]::WriteAllText($tmpPath, $jsonText, (New-Object Text.UTF8Encoding($false)))
      Move-Item -LiteralPath $tmpPath -Destination $savePath -Force

      $resp = '{"ok":true,"bytes":' + $got + '}'
      Send-Bytes $stream ([Text.Encoding]::UTF8.GetBytes($resp)) 'application/json; charset=utf-8' '200 OK'
      Write-Host ("  200  POST {0}  ({1:N0} bytes)" -f $target, $got) -ForegroundColor DarkGray
      continue
    }

    # ---------- TTS：語音服務後端（掃描／生成／Key 保管） ----------
    if ($target -like '/tts/*' -and ($method -eq 'POST' -or $method -eq 'GET')) {
      try {
        $body = Read-BodyText $stream $text $buffer $read
        $resp = Invoke-TtsRoute $target $method $body $rootFull $query
        $bytes = [Text.Encoding]::UTF8.GetBytes($resp)
        Send-Bytes $stream $bytes 'application/json; charset=utf-8' '200 OK'
        Write-Host ("  200  {0} {1}" -f $method, $target) -ForegroundColor DarkGray
      } catch {
        $emsg = $_.Exception.Message -replace '"', "'"
        if ($emsg.Length -gt 200) { $emsg = $emsg.Substring(0, 200) }
        $errJson = '{"ok":false,"error":"' + $emsg + '"}'
        Send-Bytes $stream ([Text.Encoding]::UTF8.GetBytes($errJson)) 'application/json; charset=utf-8' '200 OK'
        Write-Host ("  ERR  {0} {1}  {2}" -f $method, $target, $emsg) -ForegroundColor DarkYellow
      }
      continue
    }

    $rel = $target.TrimStart('/') -replace '/', '\'
    $file = [IO.Path]::GetFullPath((Join-Path $rootFull $rel))

    if (-not $file.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
      Send-Bytes $stream ([Text.Encoding]::UTF8.GetBytes('403 Forbidden')) 'text/plain; charset=utf-8' '403 Forbidden'
      Write-Host ("  403  {0}" -f $target) -ForegroundColor Red
      continue
    }

    if ((Test-Path $file) -and (Get-Item $file).PSIsContainer) {
      $file = Join-Path $file 'index.html'
    }

    if (-not (Test-Path $file)) {
      Send-Bytes $stream ([Text.Encoding]::UTF8.GetBytes('404 Not Found')) 'text/plain; charset=utf-8' '404 Not Found'
      Write-Host ("  404  {0}" -f $target) -ForegroundColor DarkYellow
      continue
    }

    $ext = [IO.Path]::GetExtension($file).ToLowerInvariant()
    $ctype = if ($types.ContainsKey($ext)) { $types[$ext] } else { 'application/octet-stream' }
    $total = (Get-Item $file).Length

    if ($rmSuccess) {
      $start = [Math]::Min($rangeStart, $total - 1)
      $end = if ($rangeEnd -lt 0 -or $rangeEnd -ge $total) { $total - 1 } else { $rangeEnd }
      if ($start -gt $end) { $start = 0; $end = $total - 1 }
      $len = $end - $start + 1

      $fs = [IO.File]::OpenRead($file)
      try {
        $null = $fs.Seek($start, 'Begin')
        $buf = New-Object byte[] $len
        $got = 0
        while ($got -lt $len) {
          $n = $fs.Read($buf, $got, $len - $got)
          if ($n -le 0) { break }
          $got += $n
        }
      } finally { $fs.Close() }

      $extra = "Content-Range: bytes $start-$end/$total`r`n"
      Send-Bytes $stream $buf $ctype '206 Partial Content' $extra
      Write-Host ("  206  {0}  [{1}-{2}/{3}]" -f $target, $start, $end, $total) -ForegroundColor DarkGray
    } else {
      $bytes = [IO.File]::ReadAllBytes($file)
      Send-Bytes $stream $bytes $ctype '200 OK'
      Write-Host ("  200  {0}  ({1:N0} bytes)" -f $target, $bytes.Length) -ForegroundColor DarkGray
    }
  }
  catch {
    $msg = $_.Exception.Message
    # 瀏覽器主動斷線（關頁、重新整理、取消圖片載入）→ 不算錯誤
    if ($msg -match 'aborted|abort|broken|pipe|reset|已中止|已強制關閉|連線') {
      Write-Host ("  斷線  {0}" -f $target) -ForegroundColor DarkGray
    } else {
      Write-Host ("  500  {0}" -f $msg) -ForegroundColor Red
    }
  }
  finally {
    $client.Close()
  }
}