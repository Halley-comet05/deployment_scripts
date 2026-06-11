# ── Config ────────────────────────────────────────────────────────────────────
$LogDir    = "C:\Logs"
$LogFile   = "$LogDir\frappe-daily.log"
$Site      = "lending.localhost"
$Container = "frappe_docker-backend-1"

# Ensure log directory exists
if (!(Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir | Out-Null
}

function Log($msg) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp — $msg" | Tee-Object -FilePath $LogFile -Append
}

function Invoke-BenchJob {
    param([string]$Description, [string]$Command)

    Log "Running: $Description..."
    $result = docker compose -p lending exec $Container bash -c "$Command" 2>&1

    if ($LASTEXITCODE -eq 0) {
        Log "✓ $Description completed"
    } else {
        Log "✗ $Description FAILED — $result"
    }
}

Log "=== Start-Frappe: startup sequence begun ==="

# ── Update WSL2 port proxy ────────────────────────────────────────────────────
Log "Updating WSL2 port proxy..."
try {
    $wslIp = (wsl hostname -I).Trim().Split(" ")[0]

    if (-not $wslIp) { throw "Could not determine WSL2 IP" }

    netsh interface portproxy delete v4tov4 listenport=8080 listenaddress=0.0.0.0 | Out-Null
    netsh interface portproxy add v4tov4 listenport=8080 listenaddress=0.0.0.0 `
        connectport=8080 connectaddress=$wslIp | Out-Null

    Log "✓ Port proxy updated — WSL2 IP: $wslIp"
} catch {
    Log "✗ Port proxy update failed — $_"
}

# ── Wait for Frappe to be ready ───────────────────────────────────────────────
Log "Waiting for Frappe to be ready..."
$retries = 0

do {
    Start-Sleep -Seconds 10
    docker compose -p lending exec $Container bench --site $Site doctor *> $null
    $exitCode = $LASTEXITCODE
    $retries++
} while ($exitCode -ne 0 -and $retries -lt 12)

if ($exitCode -ne 0) {
    Log "✗ Frappe not ready after 2 minutes — aborting"
    exit 1
}

Log "✓ Frappe is ready"

# ── Dates ─────────────────────────────────────────────────────────────────────
$today     = Get-Date -Format "yyyy-MM-dd"
$yesterday = (Get-Date).AddDays(-1).ToString("yyyy-MM-dd")

# Build JSON args safely
$interestArgs = "[{`"posting_date`": `"$yesterday`", `"accrual_type`": `"Regular`"}]"
$demandArgs   = "[{`"posting_date`": `"$today`"}]"
$classArgs    = "[{`"posting_date`": `"$yesterday`"}]"

# ── Daily Lending Jobs ────────────────────────────────────────────────────────
Invoke-BenchJob "Loan Interest Accrual" `
    "bench --site $Site execute lending.lending.doctype.process_loan_interest_accrual.process_loan_interest_accrual.process_loan_interest_accrual --args '$interestArgs'"

Invoke-BenchJob "Loan Demand" `
    "bench --site $Site execute lending.lending.doctype.process_loan_demand.process_loan_demand.process_loan_demand --args '$demandArgs'"

Invoke-BenchJob "Loan Security Shortfall" `
    "bench --site $Site execute lending.lending.doctype.process_loan_security_shortfall.process_loan_security_shortfall.process_loan_security_shortfall"

Invoke-BenchJob "Loan Classification" `
    "bench --site $Site execute lending.lending.doctype.process_loan_classification.process_loan_classification.process_loan_classification --args '$classArgs'"

Log "=== Start-Frappe: startup sequence complete ==="
