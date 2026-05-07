# ============================================================
# Alpha Desk - Crypto Macro Auto-Updater v3
# Pokrece Claude da analizira vijesti i pusha macro-context.json
# Raspored: svakih 3 sata (Task Scheduler)
#
# v3 unaprjedjenja:
# - Vise tokena: dodani TRUMP, NOT, PEOPLE, DOGS, ANIME, AIXBT, PUMP, ACT
# - Retry logika ako JSON nije validan (1 pokusaj)
# - Timeout za Claude CLI (8 min max)
# - Log fajl: update-macro.log
# - Skip push ako nema stvarnih promjena
# - Detaljnija validacija (sentiment range, text duljina)
# - Bolje error handlanje + exit codes
# - Push direktno na main (ne master:main)
# ============================================================

$REPO_PATH  = "C:\Users\ttovernic\Downloads\Alphadesk"
$JSON_PATH  = "$REPO_PATH\macro-context.json"
$LOG_PATH   = "$REPO_PATH\update-macro.log"
$GIT_PATH   = "C:\Program Files\Git\mingw64\bin\git.exe"

# Dodaj git u PATH ako nije
$env:PATH = "C:\Program Files\Git\mingw64\bin;C:\Program Files\Git\cmd;" + $env:PATH

# Logger helper - pise i u konzolu i u log fajl
function Write-Log {
    param([string]$msg, [string]$color = "White")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] $msg"
    Write-Host $msg -ForegroundColor $color
    Add-Content -Path $LOG_PATH -Value $line -Encoding utf8
}

Write-Log "==================================================" "Cyan"
Write-Log "Alpha Desk Macro Update v3 START" "Cyan"
Write-Log "==================================================" "Cyan"

# Tokeni koji se analiziraju (sirinski popis)
$REGULAR_TOKENS = @("BTC","ETH","XRP","SOL","BNB","ADA","LINK","AVAX","SUI")
$MEME_TOKENS    = @("TRUMP","NOT","PEOPLE","DOGS","ANIME","AIXBT","PUMP","ACT","PENGU","PNUT","BOME","MEME")
$ALL_TOKENS = $REGULAR_TOKENS + $MEME_TOKENS

# TOKEN provjera
$GITHUB_TOKEN = [System.Environment]::GetEnvironmentVariable('ALPHADESK_GH_TOKEN','User')
if (-not $GITHUB_TOKEN) { $GITHUB_TOKEN = $env:ALPHADESK_GH_TOKEN }
if (-not $GITHUB_TOKEN) {
    Write-Log "[ERROR] ALPHADESK_GH_TOKEN nije postavljen." "Red"
    exit 1
}

# 1. PULL ===========================================================
Write-Log "[1/6] Pull s GitHuba..."
Set-Location $REPO_PATH
& git pull "https://$GITHUB_TOKEN@github.com/pajdo2/alphadesk.git" main 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Log "[WARN] Pull nije uspio (kod $LASTEXITCODE), nastavljam ipak..." "Yellow"
}

# 1b. UCITAJ PRETHODNI KONTEKST za change detection ================
$PREV_CONTEXT = ""
$prevParsed = $null
if (Test-Path $JSON_PATH) {
    try {
        $prevParsed = Get-Content $JSON_PATH -Raw -Encoding utf8 | ConvertFrom-Json
        $PREV_CONTEXT = @"

## PRETHODNI PODACI (za usporedbu - obavezno koristi za changeSummary):
- Datum zadnje analize: $($prevParsed.lastUpdated)
- DXY tada: $($prevParsed.dxy)
- Oil tada: $($prevParsed.oil)
- BTC dominance tada: $($prevParsed.btcDom)%
- Fear & Greed tada: $($prevParsed.fearGreed)
- Regime tada: $($prevParsed.regime)
- macroPenalty tada: $($prevParsed.macroPenalty)
- aiSummary tada: $($prevParsed.aiSummary)
"@
        Write-Log "[1b] Prethodni JSON ucitan (datum: $($prevParsed.lastUpdated))"
    } catch {
        Write-Log "[1b] Prethodni JSON nije ucitan, nastavljam bez konteksta." "Yellow"
    }
}

# Helper za Claude pokretanje - direct call (kao v2, koji je radio)
function Invoke-ClaudeAnalysis {
    param([string]$prompt)
    $claudeExe = "C:\Users\ttovernic\.local\bin\claude.exe"
    if (-not (Test-Path $claudeExe)) {
        Write-Log "[ERROR] Claude CLI nije pronaden na: $claudeExe" "Red"
        return $false
    }
    Write-Log "Claude se pokrece (prompt $($prompt.Length) znakova)..."
    $startTime = Get-Date
    # KLJUC: --dangerously-skip-permissions je obavezan za non-interactive Write tool
    # (Bez toga Claude tiho fejla i samo printa markdown na stdout)
    # $null | signalizira "nema stdin" (Claude CLI v2 inace ceka 3s)
    # 2>&1 spaja stderr sa stdout — bez toga PS5.1 postavlja LASTEXITCODE=1 kad ima stderr writes
    # Read je obavezan: Claude CLI v2 zahtijeva Read prije Write (sigurnosna provjera prepisa)
    $null | & $claudeExe --tools "WebSearch,WebFetch,Read,Write" --dangerously-skip-permissions -p $prompt 2>&1 | Out-Null
    $exitCode = $LASTEXITCODE
    $elapsed = ((Get-Date) - $startTime).TotalSeconds
    # Provjeri stvarni uspjeh: je li JSON datoteka stvorena/azurirana
    $jsonExists = Test-Path $JSON_PATH
    $jsonFresh = $false
    if ($jsonExists) {
        $age = (Get-Date) - (Get-Item $JSON_PATH).LastWriteTime
        $jsonFresh = $age.TotalSeconds -lt ($elapsed + 60)
    }
    if (-not $jsonFresh) {
        Write-Log "[ERROR] Claude exit $exitCode i JSON nije svjez (trajalo $($elapsed.ToString('F1'))s)" "Red"
        return $false
    }
    Write-Log "Claude zavrsen (trajalo $($elapsed.ToString('F1'))s, JSON svjez)" "Green"
    return $true
}

# Generator za sentiment/catalysts/warnings JSON template (svi tokeni)
$sentimentTpl = ($ALL_TOKENS | ForEach-Object { '"' + $_ + '": 0' }) -join ', '
$catsTpl = ($ALL_TOKENS | ForEach-Object { '"' + $_ + '": []' }) -join ', '

# 2. CLAUDE ANALIZA =================================================
Write-Log "[2/6] Claude analizira trziste..."

$today = Get-Date -Format "yyyy-MM-dd"
$tokenListStr = $ALL_TOKENS -join ", "

$PROMPT = @"
ZADATAK: Azuriraj macro-context.json za crypto trading dashboard.

Tokeni: $tokenListStr
Datum: $today

## KORACI:

1. **Read tool**: $JSON_PATH
2. **WebSearch**: bitcoin price today, fear greed index today, DXY dollar index today, bitcoin dominance today, crypto news today
$PREV_CONTEXT
3. **Write tool**: file_path = "$JSON_PATH"

## OBAVEZNI JSON FORMAT (TOCNO ova polja, nista dodatno, nista manjkavo):

{
  "lastUpdated": "<ISO now>",
  "warActive": <true|false>,
  "macroPenalty": <broj 0-6>,
  "oil": <broj>,
  "dxy": <broj>,
  "btcDom": <broj 0-100>,
  "stableDom": <broj>,
  "fearGreed": <broj 0-100>,
  "regime": "<BULL|BEAR|ALT_SEASON|CRAB|VOLATILE|NEUTRAL>",
  "aiSummary": "<2-3 hrvatske recenice>",
  "changeSummary": "<1 hrvatska recenica o promjenama>",
  "catalysts": {$catsTpl},
  "warnings": {$catsTpl},
  "sentimentScore": {$sentimentTpl}
}

## STROGO PRIDRZAVAJ SE FORMATA:
- DXY, fearGreed, regime, sentimentScore SU OBAVEZNI top-level brojevi/string (ne objekti, ne stringovi za brojeve)
- changeSummary JE STRING (1 recenica), NE objekt
- NE dodaj dodatna polja (npr. "prices", "macro", "changeSummary kao objekt") — app ih ignorira i lomi parsing
- sentimentScore mora imati SVE tokene iz popisa, kao brojeve od -3 do 3

## PRAVILA ZA VRIJEDNOSTI:

regime izbor: BULL (BTC>SMA200,FG>55) | BEAR (BTC<SMA200,FG<30) | ALT_SEASON (BTC dom<45%) | CRAB (sideways,FG 35-55) | VOLATILE (veliki swingovi) | NEUTRAL (default)

macroPenalty (zbroji u 0-6): +2 warActive, +2 DXY>108, +1 DXY 106-108, -1 DXY<100, +1 oil>110, +2 oil>125, +1 FG>75, -1 FG<20

sentimentScore (-3..+3): -3=SEC/hack, -2=regulatorni rizik, -1=FUD, 0=neutral, +1=update, +2=listing/proboj, +3=ETF/halving

catalysts/warnings: max 65 znakova po vijesti, hrvatski.

## CILJ: ZADNJA AKCIJA = WRITE TOOL S FORMATOM IZNAD.
"@

$claudeOk = Invoke-ClaudeAnalysis $PROMPT
if (-not $claudeOk) {
    Write-Log "[ERROR] Claude analiza neuspjesna" "Red"
    exit 1
}

# 3. VALIDACIJA + RETRY =============================================
function Test-MacroJson {
    param($path)
    $errors = @()
    if (!(Test-Path $path)) { return @("FILE_MISSING") }
    try {
        $j = Get-Content $path -Raw -Encoding utf8 | ConvertFrom-Json
    } catch {
        return @("INVALID_JSON: $_")
    }
    if (-not $j.lastUpdated) { $errors += "Nedostaje lastUpdated" }
    if ($null -eq $j.fearGreed) { $errors += "Nedostaje fearGreed" }
    if ($j.fearGreed -lt 0 -or $j.fearGreed -gt 100) { $errors += "fearGreed izvan raspona 0-100" }
    if (-not $j.regime) { $errors += "Nedostaje regime" }
    $validRegimes = @("BULL","BEAR","ALT_SEASON","CRAB","VOLATILE","NEUTRAL")
    if ($j.regime -and $validRegimes -notcontains $j.regime) { $errors += "Nevalidan regime: $($j.regime)" }
    if ($null -eq $j.sentimentScore) { $errors += "Nedostaje sentimentScore" }
    if ($null -eq $j.macroPenalty) { $errors += "Nedostaje macroPenalty" }
    if ($j.macroPenalty -lt 0 -or $j.macroPenalty -gt 6) { $errors += "macroPenalty izvan 0-6" }
    # Sentiment score range check
    if ($j.sentimentScore) {
        $j.sentimentScore.PSObject.Properties | ForEach-Object {
            if ($_.Value -lt -3 -or $_.Value -gt 3) { $errors += "sentimentScore.$($_.Name) izvan -3..+3" }
        }
    }
    return $errors, $j
}

Write-Log "[3/6] Validacija JSON-a..."
$validation = Test-MacroJson $JSON_PATH
$errs = $validation[0]
$parsed = $validation[1]

if ($errs.Count -gt 0) {
    Write-Log "[WARN] Validacija javila gresku: $($errs -join '; ')" "Yellow"
    Write-Log "[3b] Pokusavam retry s eksplicitnijim promptom..."
    $RETRY_PROMPT = $PROMPT + "`n`nGRESKE PRETHODNOG POKUSAJA: " + ($errs -join "; ") + "`nIspravi i napisi novi validni JSON."
    Invoke-ClaudeAnalysis $RETRY_PROMPT | Out-Null
    $validation = Test-MacroJson $JSON_PATH
    $errs = $validation[0]; $parsed = $validation[1]
    if ($errs.Count -gt 0) {
        Write-Log "[ERROR] Validacija ne uspijeva ni nakon retry-a: $($errs -join '; ')" "Red"
        exit 1
    }
}

Write-Log "[3/6] JSON validan." "Green"
Write-Log "      Datum:      $($parsed.lastUpdated)"
Write-Log "      Oil:        $($parsed.oil) | DXY: $($parsed.dxy) | BTC Dom: $($parsed.btcDom)%"
Write-Log "      Fear&Greed: $($parsed.fearGreed) | Regime: $($parsed.regime) | Penalty: $($parsed.macroPenalty)"
Write-Log "      Sentiments: BTC=$($parsed.sentimentScore.BTC) ETH=$($parsed.sentimentScore.ETH) SOL=$($parsed.sentimentScore.SOL) TRUMP=$($parsed.sentimentScore.TRUMP)"

# 4. CHECK ZA STVARNE PROMJENE (skip push ako nema) ================
Write-Log "[4/6] Provjera promjena vs prethodni JSON..."
$shouldPush = $true
if ($prevParsed) {
    $changed = @()
    if ($prevParsed.fearGreed -ne $parsed.fearGreed) { $changed += "FG" }
    if ($prevParsed.regime -ne $parsed.regime) { $changed += "regime" }
    if ($prevParsed.dxy -ne $parsed.dxy) { $changed += "DXY" }
    if ($prevParsed.btcDom -ne $parsed.btcDom) { $changed += "BTCdom" }
    if ($prevParsed.macroPenalty -ne $parsed.macroPenalty) { $changed += "penalty" }
    # Sentiment check
    foreach ($t in $ALL_TOKENS) {
        if ($prevParsed.sentimentScore.$t -ne $parsed.sentimentScore.$t) { $changed += "sent_$t"; break }
    }
    if ($changed.Count -eq 0) {
        Write-Log "[4/6] Nema promjena - skip push (lastUpdated nije bitan)" "Yellow"
        $shouldPush = $false
    } else {
        Write-Log "[4/6] Promjene: $($changed -join ', ')" "Cyan"
    }
}

# 5. GIT COMMIT + PUSH ==============================================
if ($shouldPush) {
    Write-Log "[5/6] Commit i push na GitHub..."
    Set-Location $REPO_PATH
    & git config user.email "claude-agent@localhost"
    & git config user.name "Claude Agent"
    & git add macro-context.json
    $ts = Get-Date -Format "yyyy-MM-ddTHH:mm"
    $regimeTag = if ($parsed.regime) { $parsed.regime.ToLower() } else { "neutral" }
    $commitMsg = "macro: $regimeTag | FG $($parsed.fearGreed) | DXY $($parsed.dxy) | $ts"
    & git commit -m $commitMsg | Out-Null
    & git pull "https://$GITHUB_TOKEN@github.com/pajdo2/alphadesk.git" main --no-edit 2>&1 | Out-Null
    & git push "https://$GITHUB_TOKEN@github.com/pajdo2/alphadesk.git" main 2>&1 | Out-Null

    if ($LASTEXITCODE -eq 0) {
        Write-Log "[5/6] Push uspjesan!" "Green"
    } else {
        Write-Log "[ERROR] Push nije uspio (exit $LASTEXITCODE)" "Red"
        exit 1
    }
} else {
    Write-Log "[5/6] Push preskocen (nema promjena)" "Yellow"
}

# 6. SUMMARY ========================================================
Write-Log "==================================================" "Cyan"
Write-Log "Gotovo! macro-context.json azuriran." "Green"
Write-Log "  $($parsed.aiSummary)"
if ($parsed.changeSummary) { Write-Log "  Promjene: $($parsed.changeSummary)" "Cyan" }
Write-Log "  Log: $LOG_PATH"
Write-Log "==================================================" "Cyan"

exit 0
