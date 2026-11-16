#Requires -Version 5.1
<#
  export-assets.ps1
  把 ShinyColors 事件用到的素材，照原站目錄結構匯出到本機。

  範例：
    .\export-assets.ps1 -EventType produce_events -EventId 202100711
    .\export-assets.ps1 -EventType produce_communications -EventId 102400100011 -SkipSpine
    .\export-assets.ps1 -EventType produce_events -EventId 202100711,202400901 -Out D:\SC\assets
    .\export-assets.ps1 -EventType produce_events -EventId 202100711 -List      # 只看清單不下載

  參數：
    -EventType   事件類型（預設 produce_events）
    -EventId     一個或多個事件 ID
    -Out         輸出根目錄（預設：本腳本旁邊的 assets）
    -SkipAudio   不要語音 / 音效 / BGM（省很多空間）
    -SkipSpine   不要立繪骨架（data.json/atlas/png）
    -Force       已存在的檔案也重新下載
    -List        只列出會下載的路徑
    -DelayMs     每個檔案之間的間隔（預設 40ms，對來源站客氣一點）

  注意：素材版權屬 Bandai Namco／各權利方，請只做個人本機研究，不要重新上傳或散布。
#>
[CmdletBinding()]
param(
  [string]$EventType = 'produce_events',
  [string[]]$EventId,
  [string]$Out,
  [string]$BaseUrl = 'https://viewer.shinycolors.moe',
  [switch]$SkipAudio,
  [switch]$SkipSpine,
  [switch]$SkipMovie,
  [switch]$Force,
  [switch]$List,
  [int]$DelayMs = 40
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

if (-not $Out) { $Out = Join-Path $PSScriptRoot 'assets' }
if (-not $EventId -or $EventId.Count -eq 0) {
  Write-Host '缺少 -EventId。範例：' -ForegroundColor Yellow
  Write-Host '  .\export-assets.ps1 -EventType produce_events -EventId 202100711'
  Write-Host '  .\export-assets.ps1 -EventType produce_communications -EventId 102400100011 -SkipSpine'
  exit 1
}

# ---------- 狀態 ----------
$stats = @{
  ok = 0; skip = 0; fail = 0; bytes = 0L
  failures = New-Object System.Collections.ArrayList
  files    = New-Object System.Collections.ArrayList
}

$categoryAlias = @{
  'stand_fix' = 'stand'; 'stand_costume_fix' = 'stand_costume'
  'stand_flex' = 'stand'; 'stand_costume_flex' = 'stand_costume'
  'stand' = 'stand'; 'stand_costume' = 'stand_costume'
  'stand_jersey' = 'stand_jersey'; 'stand_silhouette' = 'stand_silhouette'
}

function Get-Text([string]$url) {
  $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 60
  if ($resp.Content -is [byte[]]) { return [Text.Encoding]::UTF8.GetString($resp.Content) }
  return [string]$resp.Content
}

function Resolve-Category([string]$cat) {
  if ($cat -and $categoryAlias.ContainsKey($cat)) { return $categoryAlias[$cat] }
  return 'stand'
}

function Add-Rel($set, [string]$rel) {
  if ([string]::IsNullOrWhiteSpace($rel)) { return }
  $rel = $rel -replace '\\', '/'
  if (-not $set.Contains($rel)) { [void]$set.Add($rel) }
}

function Get-SpineFiles([string]$dir) {
  # 回傳這個立繪資料夾的三件套；png 名稱之後依 atlas 內容補齊
  return @("$dir/data.json", "$dir/data.atlas", "$dir/data.png")
}

function Save-Rel([string]$rel) {
  $dest = Join-Path $Out ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
  $dir = Split-Path -Parent $dest
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

  if ((Test-Path $dest) -and -not $Force) {
    $stats.skip++
    [void]$stats.files.Add([pscustomobject]@{ rel = $rel; bytes = (Get-Item $dest).Length; cached = $true })
    return $true
  }

  $url = $BaseUrl.TrimEnd('/') + '/' + $rel
  for ($attempt = 1; $attempt -le 2; $attempt++) {
    try {
      Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -TimeoutSec 120
      $len = (Get-Item $dest).Length
      $stats.ok++
      $stats.bytes += $len
      [void]$stats.files.Add([pscustomobject]@{ rel = $rel; bytes = $len; cached = $false })
      Start-Sleep -Milliseconds $DelayMs
      return $true
    }
    catch {
      if ($attempt -lt 2) { Start-Sleep -Milliseconds 500; continue }
      if (Test-Path $dest) { Remove-Item $dest -Force -ErrorAction SilentlyContinue }
      $stats.fail++
      [void]$stats.failures.Add($rel)
      Write-Host ("  ! 失敗 {0}" -f $rel) -ForegroundColor DarkYellow
      return $false
    }
  }
}

function Get-AtlasPages([string]$atlasRel) {
  $path = Join-Path $Out ($atlasRel -replace '/', [IO.Path]::DirectorySeparatorChar)
  if (-not (Test-Path $path)) { return @() }
  $text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
  $pages = @()
  foreach ($m in [regex]::Matches($text, '(?m)^\s*([^\s:]+\.png)\s*$')) {
    $pages += $m.Groups[1].Value
  }
  return $pages
}

# ---------- 主流程 ----------
Write-Host ''
Write-Host '素材匯出' -ForegroundColor Cyan
Write-Host ("  來源：{0}" -f $BaseUrl)
Write-Host ("  輸出：{0}" -f $Out)
Write-Host ("  事件：{0} / {1}" -f $EventType, ($EventId -join ', '))
if ($SkipAudio) { Write-Host '  略過：語音 / 音效 / BGM' -ForegroundColor DarkGray }
if ($SkipSpine) { Write-Host '  略過：立繪 spine' -ForegroundColor DarkGray }
if ($SkipMovie) { Write-Host '  略過：影片' -ForegroundColor DarkGray }
Write-Host ''

if (-not (Test-Path $Out)) { New-Item -ItemType Directory -Force -Path $Out | Out-Null }

$manifest = @()

# 允許 -EventId "202100711,202400901" 這種逗號寫法
$eventIds = @()
foreach ($raw in $EventId) {
  foreach ($piece in ([string]$raw -split ',')) {
    $t = $piece.Trim()
    if ($t) { $eventIds += $t }
  }
}
if ($eventIds.Count -eq 0) { Write-Host '沒有有效的事件 ID。' -ForegroundColor Red; exit 1 }

foreach ($id in $eventIds) {

  $jsonRel = "json/$EventType/$id.json"
  Write-Host ("[{0}] 讀取腳本 {1}" -f $id, $jsonRel)

  try {
    $raw = Get-Text ("{0}/{1}" -f $BaseUrl.TrimEnd('/'), $jsonRel)
    $data = $raw | ConvertFrom-Json
    $tracks = @($data)
  }
  catch {
    Write-Host ("  x 讀不到（{0}）" -f $_.Exception.Message) -ForegroundColor Red
    $manifest += [pscustomobject]@{ eventType = $EventType; eventId = $id; error = 'json'; files = 0; bytes = 0; failures = @() }
    continue
  }

  # 腳本本身也存一份（離線播放器要讀它）
  if (-not $List) {
    $jsonDest = Join-Path $Out ($jsonRel -replace '/', [IO.Path]::DirectorySeparatorChar)
    $jsonDir = Split-Path -Parent $jsonDest
    if (-not (Test-Path $jsonDir)) { New-Item -ItemType Directory -Force -Path $jsonDir | Out-Null }
    [IO.File]::WriteAllText($jsonDest, $raw, (New-Object Text.UTF8Encoding($false)))
  }

  $set = New-Object 'System.Collections.Generic.HashSet[string]'
  $spineDirs = New-Object 'System.Collections.Generic.HashSet[string]'

  foreach ($t in $tracks) {
    if (-not $t) { continue }

    if ($t.bg -and $t.bg -ne 'off' -and $t.bg -ne 'fade_out') { Add-Rel $set "images/event/bg/$($t.bg).jpg" }

    if ($t.fg -and $t.fg -ne 'off' -and $t.fg -ne 'fade_out') {
      $fg = [string]$t.fg
      if ($fg -match '\.jpg$') { Add-Rel $set "images/event/fg/$fg" }
      else { Add-Rel $set "images/event/fg/$fg.png" }
    }

    if ($t.still -and $t.still -ne 'off') { Add-Rel $set "images/event/still/$($t.still).jpg" }
    if ($t.stillType -and $t.stillId) { Add-Rel $set "images/content/$($t.stillType)/card/$($t.stillId).jpg" }

    if ($t.textFrame -and $t.textFrame -ne 'off') { Add-Rel $set "images/event/text_frame/$($t.textFrame).png" }

    if ($t.select) {
      1..3 | ForEach-Object { Add-Rel $set ("images/event/select_frame/00{0}.png" -f $_) }
    }

    if ($t.se) { Add-Rel $set "sounds/se/event/$($t.se).m4a" }
    if ($t.voice) { Add-Rel $set "sounds/voice/events/$($t.voice).m4a" }
    if ($t.bgm -and $t.bgm -ne 'off' -and $t.bgm -ne 'fade_out') { Add-Rel $set "sounds/bgm/$($t.bgm).m4a" }
    if ($t.movie) { Add-Rel $set "movies/idols/card/$($t.movie).mp4" }

    if ($t.charId -and $t.charType) {
      $cat = Resolve-Category $t.charCategory
      $dir = "spine/$($t.charType)/$cat/$($t.charId)"
      if (-not $spineDirs.Contains($dir)) { [void]$spineDirs.Add($dir) }
    }
  }

  if ($SkipAudio) {
    $audio = @($set | Where-Object { $_ -like 'sounds/*' })
    foreach ($a in $audio) { [void]$set.Remove($a) }
  }

  if ($SkipSpine) { $spineDirs.Clear() }

  if ($SkipMovie) {
    $movies = @($set | Where-Object { $_ -like 'movies/*' })
    foreach ($mv in $movies) { [void]$set.Remove($mv) }
  }

  Write-Host ("  需要 {0} 個檔案，{1} 組立繪" -f ($set.Count + ($spineDirs.Count * 3)), $spineDirs.Count)

  if ($List) {
    $set | Sort-Object | ForEach-Object { '    ' + $_ }
    $spineDirs | Sort-Object | ForEach-Object { '    ' + $_ + '/data.{json,atlas,png}' }
    $manifest += [pscustomobject]@{ eventType = $EventType; eventId = $id; files = $set.Count; bytes = 0; failures = @() }
    continue
  }

  # 一般素材
  $i = 0
  $total = $set.Count
  foreach ($rel in ($set | Sort-Object)) {
    $i++
    Save-Rel $rel | Out-Null
    if ($i % 15 -eq 0 -or $i -eq $total) {
      Write-Host ("    進度 {0}/{1}" -f $i, $total) -ForegroundColor DarkGray
    }
  }

  # 立繪：先抓 data.json / data.atlas，再依 atlas 補貼圖頁
  foreach ($dir in ($spineDirs | Sort-Object)) {
    $okJson = Save-Rel "$dir/data.json"
    $okAtlas = Save-Rel "$dir/data.atlas"

    $pages = @()
    if ($okAtlas) { $pages = Get-AtlasPages "$dir/data.atlas" }
    if (-not $pages -or $pages.Count -eq 0) { $pages = @('data.png') }

    foreach ($p in $pages) { Save-Rel "$dir/$p" | Out-Null }
    Write-Host ("    立繪 {0}（{1} 張貼圖）" -f $dir, $pages.Count) -ForegroundColor DarkGray
  }

  $manifest += [pscustomobject]@{
    eventType = $EventType
    eventId   = $id
    files     = $set.Count + ($spineDirs.Count * 3)
    failures  = @($stats.failures)
  }
}

# ---------- 收尾 ----------
if (-not $List) {
  $manifestPath = Join-Path $Out 'manifest.json'

  # 合併舊清單：分幾次匯出也能在素材庫頁全部看到
  $merged = [ordered]@{}
  if (Test-Path $manifestPath) {
    try {
      $old = Get-Content -Raw -Encoding UTF8 $manifestPath | ConvertFrom-Json
      foreach ($e in @($old.events)) {
        if ($e -and $e.eventId) { $merged["$($e.eventType)/$($e.eventId)"] = $e }
      }
    } catch { }
  }
  foreach ($e in $manifest) { $merged["$($e.eventType)/$($e.eventId)"] = $e }

  # 資料夾裡有 json 但清單漏掉的，也補進來
  $jsonRoot = Join-Path $Out 'json'
  if (Test-Path $jsonRoot) {
    Get-ChildItem $jsonRoot -Directory | ForEach-Object {
      $typeName = $_.Name
      Get-ChildItem $_.FullName -Filter *.json -File | ForEach-Object {
        $eventIdOnly = [IO.Path]::GetFileNameWithoutExtension($_.Name)
        $key = "$typeName/$eventIdOnly"
        if (-not $merged.Contains($key)) {
          $merged[$key] = [pscustomobject]@{ eventType = $typeName; eventId = $eventIdOnly; files = 0; failures = @() }
        }
      }
    }
  }

  $summary = [pscustomobject]@{
    generatedAt = (Get-Date).ToString('s')
    source      = $BaseUrl
    events      = @($merged.Values)
    downloaded  = $stats.ok
    skipped     = $stats.skip
    failed      = $stats.fail
    bytes       = $stats.bytes
    failures    = @($stats.failures)
  }
  $summary | ConvertTo-Json -Depth 6 | Out-File -FilePath $manifestPath -Encoding UTF8

  Write-Host ''
  Write-Host '完成' -ForegroundColor Green
  Write-Host ("  新下載 {0} 個 / 已有 {1} 個 / 失敗 {2} 個" -f $stats.ok, $stats.skip, $stats.fail)
  Write-Host ("  本次寫入約 {0:N1} MB" -f ($stats.bytes / 1MB))
  Write-Host ("  位置：{0}" -f $Out)

  if ($stats.fail -gt 0) {
    Write-Host '  失敗清單：' -ForegroundColor Yellow
    $stats.failures | Select-Object -First 30 | ForEach-Object { '    ' + $_ }
    if ($stats.failures.Count -gt 30) { '    …（其餘見 manifest.json）' }
  }

  Write-Host ''
  Write-Host '離線播放：把播放器的 assetUrl 改成這個資料夾，並用本機 HTTP 開（見 serve.ps1）' -ForegroundColor DarkGray
}