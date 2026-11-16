#Requires -Version 5.1
<#
  tts-generate.ps1 —— TTS 生成工作者（由 serve.ps1 以隱藏進程呼叫）
  也可以獨立手動跑：
    powershell -ExecutionPolicy Bypass -File tts-generate.ps1 -Root D:\事件編輯器 -BodyFile job.json -OutFile result.json
  流程：讀 BodyFile（統一 TTS Request）→ 快取優先 → 呼叫本地服務／雲端 API
       → 連線被中途掐斷時自動重試（模型切換期間連線會斷，服務端仍會繼續載入）→ 結果寫 OutFile
#>
param(
  [string]$Root,
  [string]$BodyFile,
  [string]$OutFile
)
$ErrorActionPreference = 'Stop'

function Read-JsonObj([string]$s) {
  if (-not $s) { return $null }
  try { return $s | ConvertFrom-Json } catch { return $null }
}

function Invoke-HttpJson([string]$method, [string]$url, $bodyObj, [int]$timeoutSec = 10, $headers = @{}, [string]$contentType = 'application/json') {
  $req = [System.Net.HttpWebRequest]::Create($url)
  $req.Method = $method
  $req.Proxy = $null
  $req.Timeout = $timeoutSec * 1000
  $req.ReadWriteTimeout = $timeoutSec * 1000
  if ($bodyObj -ne $null) { $req.ContentType = $contentType }
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


function Invoke-TtsGenerateCore([string]$rootFull, [string]$bodyText) {
  $j = Read-JsonObj $bodyText
  if (-not $j -or -not $j.text) { throw '缺少 text' }
  $source = [string]$j.source
  $provider = [string]$j.provider
  $fmt = if ($j.format) { [string]$j.format } else { 'wav' }
  $hash = Get-ShaHex ($source + '|' + $provider + '|' + $j.endpoint + '|' + $j.model + '|' + $j.voice + '|' + $j.emotion + '|' + $j.speed + '|' + $j.seed + '|' + $j.text)
  $dir = Join-Path $rootFull 'sc-editor\tts-cache'
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

  # 快取優先：同內容直接回
  $candidates = @('wav', 'mp3')
  foreach ($c in $candidates) {
    $f = Join-Path $dir ($hash.Substring(0, 24) + '.' + $c)
    if (Test-Path $f) {
      return (@{ ok = $true; url = ('/sc-editor/tts-cache/' + (Split-Path $f -Leaf)); bytes = (Get-Item $f).Length; cached = $true } | ConvertTo-Json -Depth 4)
    }
  }

  $audio = $null
  $ext = if ($fmt) { $fmt } else { 'wav' }
  $lastErr = ''

    if ($source -eq 'local') {
      # 本機 TTS：依 provider 分派（掃描到的引擎）
      $base = if ($j.endpoint) { ([string]$j.endpoint).TrimEnd('/') } else { 'http://127.0.0.1:8088' }
      $engine = if (-not $provider -or $provider -eq 'local') { 'irodori' } else { $provider }
      if ($engine -eq 'irodori') {
        if (-not $j.voice) { throw '缺少聲線（voice）' }
          if ($j.model) {
            $hb = Invoke-HttpJson 'GET' ($base + '/health') $null 8
            $hj = [Text.Encoding]::UTF8.GetString($hb) | ConvertFrom-Json
            if ($hj.model -ne [string]$j.model) {
              # 切換前先檢查顯存，避免 OOM 把整個服務打死
              $freeMb = 0
              try {
                $raw = & nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>$null | Select-Object -First 1
                $freeMb = [int]([string]$raw).Trim()
              } catch { }
              $needGb = 0
              try {
                $mb = Invoke-HttpJson 'GET' ($base + '/models') $null 8
                $mj = [Text.Encoding]::UTF8.GetString($mb) | ConvertFrom-Json
                $mm = @($mj.models) | Where-Object { $_.id -eq [string]$j.model } | Select-Object -First 1
                if ($mm) { $needGb = [double]$mm.size_gb }
              } catch { }
              if ($freeMb -gt 0 -and $needGb -gt 0 -and $freeMb -lt ($needGb * 1024 * 0.8)) {
                throw ('顯存不足：只剩 ' + $freeMb + ' MB，模型約 ' + [math]::Round($needGb, 1) + ' GB。請關掉遊戲，或改用小模型（七草日花 1.4GB／三峰結華等）。')
              }
              $null = Invoke-HttpJson 'POST' ($base + '/model/load') @{ model = [string]$j.model } 300
            }
          }
        $req = @{ text = [string]$j.text; voice = [string]$j.voice; response = 'wav' }
          if ($j.emotion) { $req.emotion = [string]$j.emotion }
          if ($j.caption) { $req.caption = [string]$j.caption }
          if ($j.duration_scale) { $req.duration_scale = [double]$j.duration_scale }
          elseif ($j.speed) { $req.duration_scale = [math]::Round(1.0 / [double]$j.speed, 3) }
        $audio = Invoke-HttpJson 'POST' ($base + '/tts') $req 300
        $ext = 'wav'
      } elseif ($engine -eq 'voicevox' -or $engine -eq 'aivis') {
        if (-not $j.voice) { throw '缺少聲線（speaker id）' }
        $q = [uri]::EscapeDataString([string]$j.text)
        $spk = [uri]::EscapeDataString([string]$j.voice)
        $qraw = Invoke-HttpJson 'POST' ($base + '/audio_query?text=' + $q + '&speaker=' + $spk) $null 120
        $qtext = [Text.Encoding]::UTF8.GetString($qraw)
        $audio = Invoke-HttpJson 'POST' ($base + '/synthesis?speaker=' + $spk) $qtext 300
        $ext = 'wav'
      } elseif ($engine -eq 'gpt-sovits') {
        $req = @{ text = [string]$j.text; text_lang = 'ja'; text_split_method = 'cut5'; media_type = 'wav'; streaming_mode = $false }
        if ($j.voice) { $req.ref_audio_path = [string]$j.voice }
        if ($j.emotion) { $req.prompt_text = [string]$j.emotion; $req.prompt_lang = 'ja' }
        $audio = Invoke-HttpJson 'POST' ($base + '/tts') $req 300
        $ext = 'wav'
      } elseif ($engine -eq 'openai') {
        $req = @{ model = if ($j.model) { [string]$j.model } else { 'tts-1' }; input = [string]$j.text; response_format = 'wav' }
        if ($j.voice) { $req.voice = [string]$j.voice }
        if ($j.speed) { $req.speed = [double]$j.speed }
        $audio = Invoke-HttpJson 'POST' ($base + '/v1/audio/speech') $req 300
        $ext = 'wav'
      } else {
        throw ('未知的本機引擎：' + $engine)
      }
    } elseif ($source -eq 'cloud') {
    $keys = Get-TtsKeys $rootFull
    if ($provider -eq 'elevenlabs') {
      if (-not $keys.elevenlabs) { throw 'ElevenLabs 尚未設定 API Key' }
      if (-not $j.voice) { throw '缺少 Voice ID' }
      $url = 'https://api.elevenlabs.io/v1/text-to-speech/' + [string]$j.voice + '?output_format=mp3_44100_128'
      $req = @{ text = [string]$j.text; model_id = if ($j.model) { [string]$j.model } else { 'eleven_multilingual_v2' } }
      $audio = Invoke-HttpJson 'POST' $url $req 180 @{ 'xi-api-key' = [string]$keys.elevenlabs }
      $ext = 'mp3'
    } elseif ($provider -eq 'azure') {
      if (-not ($keys.azure -and $keys.azure.key -and $keys.azure.region)) { throw 'Azure Speech 尚未設定 Key / 區域' }
      if (-not $j.voice) { throw '缺少 Azure 語音名稱（如 ja-JP-NanamiNeural）' }
      $safe = ([string]$j.text) -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'
      $ssml = "<speak version='1.0' xml:lang='ja-JP'><voice name=`"$([string]$j.voice)`">$safe</voice></speak>"
      $url = 'https://' + [string]$keys.azure.region + '.tts.speech.microsoft.com/cognitiveservices/v1'
      $audio = Invoke-HttpJson 'POST' $url $ssml 60 @{
        'Ocp-Apim-Subscription-Key' = [string]$keys.azure.key
        'X-Microsoft-OutputFormat'  = 'audio-24khz-48kbitrate-mono-mp3'
      } 'application/ssml+xml'
      $ext = 'mp3'
    } elseif ($provider -eq 'custom') {
      if (-not ($keys.custom -and $keys.custom.key -and $keys.custom.endpoint)) { throw '自訂 API 尚未設定 Key / Endpoint' }
      $req = @{ input = [string]$j.text; response_format = if ($fmt) { $fmt } else { 'mp3' } }
      $req.model = if ($j.model) { [string]$j.model } else { 'tts-1' }
      if ($j.voice) { $req.voice = [string]$j.voice }
      if ($j.speed) { $req.speed = [double]$j.speed }
      $audio = Invoke-HttpJson 'POST' ([string]$keys.custom.endpoint) $req 300 @{ 'Authorization' = ('Bearer ' + [string]$keys.custom.key) }
      $ext = if ($fmt) { $fmt } else { 'mp3' }
    } else {
      throw ('未知的雲端供應商：' + $provider)
    }
  } else {
    throw ('未知的 source：' + $source)
  }

  if (-not $audio -or $audio.Length -eq 0) { throw '沒有取得音訊' }
  $fname = $hash.Substring(0, 24) + '.' + $ext
  $fpath = Join-Path $dir $fname
  [IO.File]::WriteAllBytes($fpath, $audio)
  return (@{ ok = $true; url = ('/sc-editor/tts-cache/' + $fname); bytes = $audio.Length; cached = $false } | ConvertTo-Json -Depth 4)
}

if (-not $Root) { return }   # 被 serve.ps1 點載時只取函式

$bodyText = [IO.File]::ReadAllText($BodyFile, [Text.Encoding]::UTF8)
try {
  $result = Invoke-TtsGenerateCore $Root $bodyText
} catch {
  $emsg = $_.Exception.Message -replace '"', "'"
  if ($emsg.Length -gt 300) { $emsg = $emsg.Substring(0, 300) }
  $result = (@{ ok = $false; error = $emsg } | ConvertTo-Json -Depth 4)
}
[IO.File]::WriteAllText($OutFile, $result, (New-Object Text.UTF8Encoding($false)))