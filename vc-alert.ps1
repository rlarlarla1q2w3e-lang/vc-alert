# VC 투자 알림 봇 - crypto-fundraising.info 신규 투자 라운드 감시
# 사용법:
#   .\vc-alert.ps1            # 정상 실행 (신규 감지 시 텔레그램 전송)
#   .\vc-alert.ps1 -DryRun    # 테스트 실행 (파싱 결과만 출력, 전송/저장 안 함)
#   .\vc-alert.ps1 -ResetBaseline  # 상태 초기화 (다음 실행이 기준선 설정)

param(
    [switch]$DryRun,
    [switch]$ResetBaseline
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$Root       = $PSScriptRoot
$ConfigPath = Join-Path $Root 'config.json'
$StatePath  = Join-Path $Root 'state.json'
$LogPath    = Join-Path $Root 'vc-alert.log'

function Write-Log([string]$msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    try { Add-Content -Path $LogPath -Value $line -Encoding UTF8 } catch {}
    if ($DryRun) { Write-Host $line }
}

function Normalize-Name([string]$name) {
    if (-not $name) { return '' }
    (($name.ToLowerInvariant()) -replace '\s+', ' ').Trim()
}

function Esc-Html([string]$s) {
    if (-not $s) { return '' }
    $s -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'
}

function Format-Usd([long]$v) {
    if ($v -le 0) { return '비공개' }
    if ($v -ge 1000000000) { return ('${0:0.#}B' -f ($v / 1000000000.0)) }
    if ($v -ge 1000000)    { return ('${0:0.#}M' -f ($v / 1000000.0)) }
    if ($v -ge 1000)       { return ('${0:0.#}K' -f ($v / 1000.0)) }
    return ('${0}' -f $v)
}

if ($ResetBaseline) {
    if (Test-Path $StatePath) { Remove-Item $StatePath -Force -Confirm:$false }
    Write-Log 'State reset. Next run will re-baseline.'
    return
}

# ---------- 설정 로드 ----------
$config = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

# 환경변수 우선 (GitHub Actions/클라우드에서는 토큰을 Secrets로 주입 → 파일에 평문 저장 안 함)
if ($env:TELEGRAM_BOT_TOKEN) { $config.telegram_bot_token = $env:TELEGRAM_BOT_TOKEN }
if ($env:TELEGRAM_CHAT_ID)   { $config.telegram_chat_id   = $env:TELEGRAM_CHAT_ID }
if ($env:WATCH_ALL)          { $config.watch_all          = ($env:WATCH_ALL -eq 'true') }

$aliases = @{}
if ($config.aliases) {
    foreach ($p in $config.aliases.PSObject.Properties) {
        $aliases[(Normalize-Name $p.Name)] = (Normalize-Name $p.Value)
    }
}

function Resolve-Investor([string]$name) {
    $n = Normalize-Name $name
    if ($aliases.ContainsKey($n)) { return $aliases[$n] }
    return $n
}

$watched = @{}
foreach ($w in @($config.watched_investors)) { $watched[(Resolve-Investor $w)] = $true }
$watchAll = [bool]$config.watch_all

$tokenSet = ($config.telegram_bot_token -and $config.telegram_bot_token -ne 'PUT_TOKEN_HERE')

# ---------- 텔레그램 ----------
function Get-ChatId {
    # chat_id가 비어 있으면 getUpdates로 자동 감지 후 config에 저장
    if ($config.telegram_chat_id) { return $config.telegram_chat_id }
    if (-not $tokenSet) { return $null }
    try {
        $r = Invoke-RestMethod -Uri ("https://api.telegram.org/bot{0}/getUpdates" -f $config.telegram_bot_token) -TimeoutSec 30
        $last = $r.result | Where-Object { $_.message.chat.id } | Select-Object -Last 1
        if ($last) {
            $cid = [string]$last.message.chat.id
            $config.telegram_chat_id = $cid
            $json = $config | ConvertTo-Json -Depth 5
            [IO.File]::WriteAllText($ConfigPath, $json, (New-Object Text.UTF8Encoding $true))
            Write-Log "Auto-detected chat_id: $cid"
            return $cid
        }
        Write-Log 'chat_id auto-detect failed: no messages. Send /start to your bot first.'
    } catch {
        Write-Log "getUpdates failed: $($_.Exception.Message)"
    }
    return $null
}

function Send-Telegram([string]$text) {
    if (-not $tokenSet) { Write-Log 'Telegram token not configured; skipping send.'; return $false }
    $chatId = Get-ChatId
    if (-not $chatId) { Write-Log 'No chat_id; skipping send.'; return $false }
    $payload = @{
        chat_id                  = $chatId
        text                     = $text
        parse_mode               = 'HTML'
        disable_web_page_preview = $true
    }
    $json  = $payload | ConvertTo-Json -Depth 3
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    try {
        Invoke-RestMethod -Uri ("https://api.telegram.org/bot{0}/sendMessage" -f $config.telegram_bot_token) `
            -Method Post -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec 30 | Out-Null
        return $true
    } catch {
        Write-Log "sendMessage failed: $($_.Exception.Message)"
        return $false
    }
}

# ---------- 프로젝트 상세 정보 (토큰/홈페이지/포인트 제도) ----------
function Get-ProjectDetails([string]$slug) {
    $d = @{ Ticker = ''; Website = ''; XUrl = ''; Points = '확인 불가' }
    if (-not $slug) { return $d }
    try {
        $r = Invoke-WebRequest -Uri ("https://crypto-fundraising.info/projects/{0}/" -f $slug) -UseBasicParsing -TimeoutSec 30 `
            -Headers @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36' }
        $ph = $r.Content
        foreach ($m in [regex]::Matches($ph, '<h2 class="header-ticker">\s*([^<]*?)\s*</h2>')) {
            if ($m.Groups[1].Value) { $d.Ticker = $m.Groups[1].Value.Trim(); break }
        }
        if ($ph -match '<span>Website</span>') {
            if ($ph -match 'href="(https?://[^"]+)"[^>]*class="linkwithicon">\s*<img[^>]*site_icon\.svg"><span>Website</span>') {
                $d.Website = $Matches[1]
            }
        }
        if ($ph -match 'href="(https?://(?:x\.com|twitter\.com)/[^"/]+)"') { $d.XUrl = $Matches[1] }
    } catch {
        Write-Log ("Project page fetch failed ({0}): {1}" -f $slug, $_.Exception.Message)
        return $d
    }
    # 포인트 제도: 공식 홈페이지에서 키워드 스캔 (휴리스틱)
    if ($d.Website) {
        try {
            $w = Invoke-WebRequest -Uri $d.Website -UseBasicParsing -TimeoutSec 20 `
                -Headers @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36' }
            $txt = $w.Content
            if ($txt -match '(?i)\b(points?\s+(program|system|season|campaign|leaderboard)|earn\s+points|loyalty\s+points|airdrop\s+points|reward\s+points|\bXP\s+(points|program)|포인트)') {
                $d.Points = '있음 (홈페이지에서 감지)'
            } elseif ($txt -match '(?i)\bpoints\b|\bairdrop\b') {
                $d.Points = '가능성 있음 (관련 단어 발견)'
            } else {
                $d.Points = '미감지'
            }
        } catch {
            $d.Points = '확인 불가 (홈페이지 접속 실패)'
        }
    } else {
        $d.Points = '확인 불가 (홈페이지 미등록)'
    }
    return $d
}

# ---------- 2차 소스: Cointelegraph 펀딩 뉴스 RSS ----------
function Get-FundingNews {
    $out = New-Object System.Collections.ArrayList
    try {
        $r = Invoke-WebRequest -Uri 'https://cointelegraph.com/rss/tag/funding' -UseBasicParsing -TimeoutSec 40 `
            -Headers @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36' }
        $xml = $r.Content
    } catch {
        Write-Log ("News fetch failed: {0}" -f $_.Exception.Message)
        return $out
    }
    foreach ($m in [regex]::Matches($xml, '(?s)<item>(.*?)</item>')) {
        $it = $m.Groups[1].Value
        $title = ''
        if ($it -match '(?s)<title>\s*(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?\s*</title>') {
            $title = [System.Net.WebUtility]::HtmlDecode($Matches[1].Trim())
        }
        $guid = ''
        if ($it -match '(?s)<guid[^>]*>\s*(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?\s*</guid>') { $guid = $Matches[1].Trim() }
        $link = $guid
        if ($it -match '(?s)<link>\s*(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?\s*</link>') {
            $raw = $Matches[1].Trim()
            if ($raw) { $link = ($raw -split '\?')[0] }
        }
        if (-not $title -or -not $link) { continue }

        # 투자 유치 헤드라인만 통과 (정치자금/기부/일반 뉴스 제외)
        $isRaise = $title -match '(?i)\b(raises?|raised|secures?|secured|lands?|nets?|closes?|bags?|snags?|clinches?)\b' `
                   -or $title -match '(?i)\b(series\s+[a-e]\b|seed\s+round|funding\s+round|pre-seed)' `
                   -or $title -match '(?i)\b(valuation|unicorn)\b'
        $hasMoney = $title -match '\$\s?\d' -or $title -match '(?i)\b\d[\d.,]*\s?(million|billion|[mb])\b'
        $isBad = $title -match '(?i)\b(pac|primary race|election|donat|lawsuit|sec charges|hack|exploit)\b' `
                 -or $title -match '(?i)(weekly close|close above|close below|rsi|bottom signal|price|resistance|support level|all-time high|\bath\b)'
        if (-not ($isRaise -and $hasMoney) -or $isBad) { continue }

        $amt = ''
        if ($title -match '(?i)(\$\s?\d[\d.,]*\s?(?:million|billion|[mb])?)') { $amt = ($Matches[1] -replace '\s','') }

        $id = [System.Security.Cryptography.MD5]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($link))
        $idHex = -join ($id | ForEach-Object { $_.ToString('x2') })

        [void]$out.Add([pscustomobject]@{
            Id     = $idHex
            Title  = $title
            Url    = $link
            Amount = $amt
        })
    }
    return $out
}

# ---------- 수집 ----------
try {
    $resp = Invoke-WebRequest -Uri 'https://crypto-fundraising.info/' -UseBasicParsing -TimeoutSec 60 `
        -Headers @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36' }
    $html = $resp.Content
} catch {
    Write-Log "Fetch failed: $($_.Exception.Message)"
    return
}

# ---------- 파싱 ----------
$chunks = $html -split '<div class="hp-table-row hpt-data"'
$deals = New-Object System.Collections.ArrayList
$seenThisRun = @{}   # 같은 딜이 페이지 내 여러 테이블에 중복 노출되는 경우 제거
for ($i = 1; $i -lt $chunks.Count; $i++) {
    $c = $chunks[$i]
    if ($c -notmatch 'data-eid="(\d+)"') { continue }
    $eid = $Matches[1]
    if ($seenThisRun.ContainsKey($eid)) { continue }
    $seenThisRun[$eid] = $true

    $slug = ''
    if ($c -match 'href="/projects/([^"]+)"') { $slug = $Matches[1] }
    $title = $slug
    if ($c -match '<h5 class="cointitle">([^<]*)</h5>') {
        $title = [System.Net.WebUtility]::HtmlDecode($Matches[1].Trim())
    }

    $col3 = [regex]::Matches($c, '<div class="hpt-col3">\s*([^<]*?)\s*</div>')
    $round = ''
    $ddate = ''
    if ($col3.Count -ge 1) { $round = $col3[0].Groups[1].Value.Trim() }
    if ($col3.Count -ge 2) { $ddate = $col3[1].Groups[1].Value.Trim() }

    $raised = [long]0
    if ($c -match 'class="abbrusd">\s*(\d+)') { $raised = [long]$Matches[1] }

    $cats = @()
    foreach ($m in [regex]::Matches($c, 'class="catitem"[^>]*>\s*([^<]+?)\s*</span>')) {
        $cats += [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value.Trim())
    }

    # 투자사: 로고 링크(title 속성, Lead 표시 포함) + 모바일용 텍스트 목록의 합집합
    $invMap = [ordered]@{}
    foreach ($m in [regex]::Matches($c, 'href="/funds/[^"]+"[^>]*>\s*<img[^>]*title="([^"]+)"')) {
        $t    = [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
        $lead = $t -match '\|\s*Lead'
        $name = ($t -split '\|')[0].Trim()
        $key  = Normalize-Name $name
        if ($key -and -not $invMap.Contains($key)) {
            $invMap[$key] = @{ Name = $name; Lead = [bool]$lead }
        }
    }
    foreach ($m in [regex]::Matches($c, '<div class="mob-only investlist">\s*([^<]+?)\s*</div>')) {
        foreach ($nm in ([System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value) -split ',')) {
            $nm2 = (($nm) -replace '\s+', ' ').Trim()
            $key = Normalize-Name $nm2
            if ($key -and -not $invMap.Contains($key)) {
                $invMap[$key] = @{ Name = $nm2; Lead = $false }
            }
        }
    }

    [void]$deals.Add([pscustomobject]@{
        Eid       = $eid
        Slug      = $slug
        Title     = $title
        Round     = $round
        Date      = $ddate
        Raised    = $raised
        Cats      = $cats
        Investors = @($invMap.Values)
    })
}

if ($deals.Count -eq 0) {
    Write-Log 'Parsed 0 deals - site structure may have changed. Check the HTML.'
    return
}

# ---------- 2차 소스 수집 ----------
$news = Get-FundingNews

# ---------- 상태 로드 ----------
$seen = @{}
$seenNews = @{}
$isBaseline = $true
$newsIsBaseline = $true
if (Test-Path $StatePath) {
    try {
        $state = Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($e in @($state.seen_eids)) { $seen[[string]$e] = $true }
        $isBaseline = $false
        if ($state.PSObject.Properties.Name -contains 'seen_news') {
            foreach ($n in @($state.seen_news)) { $seenNews[[string]$n] = $true }
            if ($seenNews.Count -gt 0) { $newsIsBaseline = $false }
        }
    } catch {
        Write-Log "State file unreadable, re-baselining: $($_.Exception.Message)"
    }
}

# ---------- 신규 판정 및 알림 ----------
$newDeals = @($deals | Where-Object { -not $seen.ContainsKey($_.Eid) })
$newNews  = @($news  | Where-Object { -not $seenNews.ContainsKey($_.Id) })

if ($DryRun) {
    Write-Host ("`n=== [1차] crypto-fundraising.info 딜 {0}건 (신규 {1}건) ===" -f $deals.Count, $newDeals.Count)
    foreach ($d in $deals) {
        $invNames = @($d.Investors | ForEach-Object { if ($_.Lead) { "$($_.Name)[Lead]" } else { $_.Name } })
        $hits = @($d.Investors | Where-Object { $watchAll -or $watched.ContainsKey((Resolve-Investor $_.Name)) })
        $mark = if ($hits.Count -gt 0) { ' <<< 관심 투자사 매칭!' } else { '' }
        Write-Host ("eid={0} | {1} | {2} | {3} | {4} | 투자사: {5}{6}" -f $d.Eid, $d.Title, $d.Round, $d.Date, (Format-Usd $d.Raised), ($invNames -join ', '), $mark)
    }
    Write-Host ("`n=== [2차] Cointelegraph 펀딩 뉴스 {0}건 (신규 {1}건) ===" -f $news.Count, $newNews.Count)
    foreach ($n in $news) {
        Write-Host ("{0} | {1}" -f $n.Amount, $n.Title)
    }
    return
}

if ($isBaseline) {
    # 첫 실행: 현재 딜을 기준선으로만 저장하고 알림은 보내지 않음
    Write-Log ("Baseline set with {0} deals." -f $deals.Count)
    if ($tokenSet) {
        [void](Send-Telegram ("✅ <b>VC 투자 감시 시작</b>`n현재 {0}건을 기준선으로 저장했습니다.`n이후 새로 올라오는 투자 라운드부터 알림을 보냅니다." -f $deals.Count))
    }
} else {
    # 오래된 것부터 순서대로 전송 (페이지는 최신순이므로 역순)
    [array]::Reverse($newDeals)
    foreach ($d in $newDeals) {
        $hits = @($d.Investors | Where-Object { $watched.ContainsKey((Resolve-Investor $_.Name)) })
        $send = $watchAll -or ($hits.Count -gt 0)

        $allNames = (@($d.Investors | ForEach-Object { $_.Name })) -join ', '
        Write-Log ("New deal eid={0} {1} ({2}) investors=[{3}] matched={4}" -f $d.Eid, $d.Title, $d.Round, $allNames, $send)

        if (-not $send) { continue }
        # 필수 필드 검사: 프로젝트명과 투자사가 없으면 스킵 (쓰레기 데이터 필터)
        if (-not $d.Title -or $d.Investors.Count -eq 0) { continue }

        $roundTxt = if ($d.Round -and $d.Round -ne 'Unknown') { $d.Round } else { '미공개' }
        $starTxt  = (@($hits | ForEach-Object { if ($_.Lead) { "$($_.Name) (Lead)" } else { $_.Name } })) -join ', '

        $detail = Get-ProjectDetails $d.Slug
        $tokenTxt = if ($detail.Ticker) { "발행됨 (`$$($detail.Ticker))" } else { '미발행/미확인' }

        $lines = New-Object System.Collections.ArrayList
        [void]$lines.Add("🚨🚨🚨 <b>신규 투자 감지</b> 🚨🚨🚨")
        [void]$lines.Add("━━━━━━━━━━━━━━━━")
        [void]$lines.Add(("📌 <b>{0}</b>" -f (Esc-Html $d.Title.ToUpper())))
        [void]$lines.Add("━━━━━━━━━━━━━━━━")
        [void]$lines.Add(("📊 라운드: <b>{0}</b>" -f (Esc-Html $roundTxt)))
        [void]$lines.Add(("💰 투자금액: <b>{0}</b>" -f (Format-Usd $d.Raised)))
        [void]$lines.Add(("🪙 토큰: <b>{0}</b>" -f (Esc-Html $tokenTxt)))
        [void]$lines.Add(("🎯 포인트 제도: <b>{0}</b>" -f (Esc-Html $detail.Points)))
        if ($d.Cats.Count -gt 0) { [void]$lines.Add(("🏷 분야: {0}" -f (Esc-Html ($d.Cats -join ', ')))) }
        [void]$lines.Add("━━━━━━━━━━━━━━━━")
        if ($starTxt) { [void]$lines.Add(("⭐⭐ 관심 투자사: <b>{0}</b> ⭐⭐" -f (Esc-Html $starTxt))) }
        [void]$lines.Add(("👥 투자사: {0}" -f (Esc-Html $allNames)))
        [void]$lines.Add("━━━━━━━━━━━━━━━━")
        if ($detail.Website) { [void]$lines.Add(("🌐 {0}" -f $detail.Website)) }
        if ($detail.XUrl) { [void]$lines.Add(("𝕏 {0}" -f $detail.XUrl)) }
        if ($d.Slug) { [void]$lines.Add(("🔗 https://crypto-fundraising.info/projects/{0}" -f $d.Slug)) }

        [void](Send-Telegram ($lines -join "`n"))
        Start-Sleep -Milliseconds 500
    }
}

# ---------- 2차 소스: 뉴스 알림 ----------
if ($newsIsBaseline) {
    Write-Log ("News baseline set with {0} items." -f $news.Count)
} else {
    [array]::Reverse($newNews)
    foreach ($n in $newNews) {
        Write-Log ("New funding news: {0}" -f $n.Title)
        $nl = New-Object System.Collections.ArrayList
        [void]$nl.Add("📰 <b>투자 뉴스 감지</b> (2차 소스)")
        [void]$nl.Add("━━━━━━━━━━━━━━━━")
        [void]$nl.Add(("<b>{0}</b>" -f (Esc-Html $n.Title)))
        if ($n.Amount) { [void]$nl.Add(("💰 금액: <b>{0}</b>" -f (Esc-Html $n.Amount))) }
        [void]$nl.Add("━━━━━━━━━━━━━━━━")
        [void]$nl.Add(("🔗 {0}" -f $n.Url))
        [void]$nl.Add("<i>출처: Cointelegraph</i>")
        [void](Send-Telegram ($nl -join "`n"))
        Start-Sleep -Milliseconds 500
    }
}

# ---------- 상태 저장 (최근 1000개 eid + 300개 뉴스 id 유지) ----------
foreach ($d in $deals) { $seen[$d.Eid] = $true }
foreach ($n in $news)  { $seenNews[$n.Id] = $true }
$allEids = @($seen.Keys | Sort-Object { [long]$_ } -Descending | Select-Object -First 1000)
$allNews = @($seenNews.Keys | Select-Object -First 300)
$stateJson = @{ seen_eids = $allEids; seen_news = $allNews; updated = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') } | ConvertTo-Json -Depth 3
[IO.File]::WriteAllText($StatePath, $stateJson, (New-Object Text.UTF8Encoding $true))
Write-Log ("Run complete. deals_parsed={0} new_deals={1} news_parsed={2} new_news={3}" -f $deals.Count, $newDeals.Count, $news.Count, $newNews.Count)
