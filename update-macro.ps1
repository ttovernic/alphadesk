# ============================================================
# Alpha Desk — Crypto Macro Auto-Updater
# Pokrece Claude da analizira vijesti i pusha macro-context.json
# Raspored: svakih 3 sata (Task Scheduler)
# ============================================================

$REPO_PATH  = "C:\Users\ttovernic\Downloads\Alphadesk"
$JSON_PATH  = "$REPO_PATH\macro-context.json"
$GIT_PATH   = "C:\Program Files\Git\mingw64\bin\git.exe"

# Dodaj git u PATH ako nije
$env:PATH = "C:\Program Files\Git\mingw64\bin;C:\Program Files\Git\cmd;" + $env:PATH

# ── TOKEN ────────────────────────────────────────────────────
$GITHUB_TOKEN = [System.Environment]::GetEnvironmentVariable('ALPHADESK_GH_TOKEN','User')
if (-not $GITHUB_TOKEN) { $GITHUB_TOKEN = $env:ALPHADESK_GH_TOKEN }
if (-not $GITHUB_TOKEN) {
    Write-Host "[ERROR] ALPHADESK_GH_TOKEN nije postavljen." -ForegroundColor Red
    exit 1
}

# ── 1. Pull najnovijeg stanja ─────────────────────────────────
Write-Host "[1/4] Pull s GitHuba..."
Set-Location $REPO_PATH
& git pull "https://$GITHUB_TOKEN@github.com/pajdo2/alphadesk.git" main 2>&1 | Out-Null

# ── 2. Claude analiza ────────────────────────────────────────
Write-Host "[2/4] Claude analizira trziste..."

$PROMPT = @"
Ti si crypto market analyst. Tvoj zadatak je pretraziti najnovije vijesti i trzisne uvjete te napisati azurirani macro-context.json.

## TOKENI: BTC, ETH, XRP, SOL, BNB, ADA, LINK, AVAX, SUI

## KORACI:

1. WebSearch pretrage (izvrsi svaku):
   - "crypto fear greed index today"
   - "bitcoin dominance today percentage"
   - "crude oil price today WTI"
   - "DXY US dollar index today value"
   - "stablecoin dominance crypto today"
   - "geopolitical risk crypto today"
   - "Bitcoin BTC news today"
   - "Ethereum ETH news today"
   - "XRP Ripple news today"
   - "Solana SOL news today"
   - "BNB Binance news today"
   - "Chainlink LINK news today"
   - "Avalanche AVAX news today"
   - "Cardano ADA news today"
   - "Sui SUI crypto news today"

2. Na temelju rezultata napisi TOCNO ovu JSON strukturu u datoteku: $JSON_PATH

{
  "lastUpdated": "<ISO timestamp sada, npr. 2026-04-16T12:00:00.000Z>",
  "warActive": <true ili false>,
  "macroPenalty": <broj 0-6>,
  "oil": <WTI cijena kao broj, npr. 84.5>,
  "dxy": <US Dollar Index kao broj, npr. 104.2>,
  "btcDom": <BTC dominance kao broj>,
  "stableDom": <stablecoin dominance kao broj>,
  "aiSummary": "<2-3 recenice na hrvatskom koje ukljucuju DXY kontekst>",
  "catalysts": {
    "BTC": ["<vijest max 65 znakova>"],
    "ETH": [], "XRP": [], "SOL": [], "BNB": [],
    "ADA": [], "LINK": [], "AVAX": [], "SUI": []
  },
  "warnings": {
    "BTC": [],
    "ETH": [], "XRP": [], "SOL": [], "BNB": [],
    "ADA": [], "LINK": [], "AVAX": [], "SUI": []
  }
}

VAZNO: Napisi SAMO validni JSON. Bez markdown blokova, bez komentara.
DXY tumacenje: >106 = jak dolar (bearish kripto), 100-103 = neutralno, <100 = slab dolar (bullish kripto).
"@

$claudeExe = "C:\Users\ttovernic\.local\bin\claude.exe"
& $claudeExe --allowedTools "WebSearch,WebFetch,Write" -p $PROMPT

# ── 3. Validacija ─────────────────────────────────────────────
if (!(Test-Path $JSON_PATH)) {
    Write-Host "[ERROR] macro-context.json nije kreiran." -ForegroundColor Red
    exit 1
}
try {
    $parsed = Get-Content $JSON_PATH -Raw | ConvertFrom-Json
    if (-not $parsed.lastUpdated) { throw "Nedostaje lastUpdated" }
    Write-Host "[3/4] JSON validan. Datum: $($parsed.lastUpdated), Nafta: $($parsed.oil), DXY: $($parsed.dxy), BTC Dom: $($parsed.btcDom)%"
} catch {
    Write-Host "[ERROR] JSON nije validan: $_" -ForegroundColor Red
    exit 1
}

# ── 4. Git commit + push ──────────────────────────────────────
Write-Host "[4/4] Commit i push na GitHub..."

Set-Location $REPO_PATH
& git config user.email "claude-agent@localhost"
& git config user.name "Claude Agent"
& git add macro-context.json
$ts = Get-Date -Format "yyyy-MM-ddTHH:mm"
& git commit -m "macro: auto-update $ts"
& git push "https://$GITHUB_TOKEN@github.com/pajdo2/alphadesk.git" master:main 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "OK Gotovo! macro-context.json azuriran." -ForegroundColor Green
    Write-Host "   $($parsed.aiSummary)"
} else {
    Write-Host "[ERROR] Push nije uspio (exit $LASTEXITCODE)." -ForegroundColor Red
    exit 1
}
