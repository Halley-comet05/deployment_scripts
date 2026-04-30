# ============================================================
#  Start-Frappe.ps1
#  1. Refreshes the WSL2 port proxy
#  2. Waits until the Frappe container is healthy
#  3. Runs daily lending jobs via direct Python invocation
#
#  Run this on system startup / laptop wake, or manually
#  before triggering Invoke-FrappeBackup.ps1.
# ============================================================

$LogFile   = "C:\Logs\frappe-daily.log"
$Site      = "lending.localhost"
$Container = "backend"
$SitesPath = "/home/frappe/frappe-bench/sites"
$Python    = "/home/frappe/frappe-bench/env/bin/python"

function Log($msg) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp — $msg" | Tee-Object -FilePath $LogFile -Append
}

function Invoke-FrappeScript {
    param([string]$Description, [string]$PyScript)
    Log "Running: $Description..."
    $result = $PyScript | docker compose -p lending exec -T $Container bash -c "cd $SitesPath && $Python" 2>&1
    if ($LASTEXITCODE -eq 0) {
        Log "✓ $Description completed"
    } else {
        Log "✗ $Description FAILED - $result"
    }
}

Log "=== Start-Frappe: startup sequence begun ==="

# ── Update WSL2 port proxy ────────────────────────────────────────────────────
Log "Updating WSL2 port proxy..."
try {
    $wslIp = (wsl ip addr show eth0 | Select-String "inet " | ForEach-Object {
        $_.ToString().Trim().Split(" ")[1].Split("/")[0]
    })

    if (-not $wslIp) { throw "Could not determine WSL2 IP" }

    netsh interface portproxy delete v4tov4 listenport=8080 listenaddress=0.0.0.0 | Out-Null
    netsh interface portproxy add v4tov4 listenport=8080 listenaddress=0.0.0.0 `
        connectport=8080 connectaddress=$wslIp | Out-Null

    Log "✓ Port proxy updated - WSL2 IP: $wslIp"
} catch {
    Log "✗ Port proxy update failed - $_"
    # Non-fatal: docker exec commands may still work without this
}

# ── Wait for Frappe to be ready ───────────────────────────────────────────────
Log "Waiting for Frappe to be ready..."
$retries = 0
do {
    Start-Sleep -Seconds 10
    $ready = docker compose -p lending exec $Container bench --site $Site doctor 2>&1
    $retries++
} while ($LASTEXITCODE -ne 0 -and $retries -lt 12)   # wait up to 2 minutes

if ($LASTEXITCODE -ne 0) {
    Log "✗ Frappe not ready after 2 minutes - aborting"
    exit 1
}

Log "✓ Frappe is ready"

# ── Daily Lending Jobs ────────────────────────────────────────────────────────
$today     = Get-Date -Format "yyyy-MM-dd"
$yesterday = (Get-Date).AddDays(-1).ToString("yyyy-MM-dd")

Invoke-FrappeScript "Loan Interest Accrual" @"
import frappe
frappe.init(site='$Site', sites_path='.')
frappe.connect()
from lending.lending.loan_management.doctype.process_loan_interest_accrual.process_loan_interest_accrual import process_loan_interest_accrual_for_loans
process_loan_interest_accrual_for_loans(posting_date='$yesterday', accrual_type='Regular')
frappe.db.commit()
frappe.destroy()
"@

Invoke-FrappeScript "Loan Demand" @"
import frappe
frappe.init(site='$Site', sites_path='.')
frappe.connect()
from lending.lending.loan_management.doctype.process_loan_demand.process_loan_demand import process_daily_loan_demands
process_daily_loan_demands(posting_date='$today')
frappe.db.commit()
frappe.destroy()
"@

Invoke-FrappeScript "Loan Security Shortfall" @"
import frappe
frappe.init(site='$Site', sites_path='.')
frappe.connect()
from lending.lending.loan_management.doctype.process_loan_security_shortfall.process_loan_security_shortfall import create_process_loan_security_shortfall
create_process_loan_security_shortfall()
frappe.db.commit()
frappe.destroy()
"@

Invoke-FrappeScript "Loan Classification" @"
import frappe
frappe.init(site='$Site', sites_path='.')
frappe.connect()
from lending.lending.loan_management.doctype.process_loan_classification.process_loan_classification import process_loan_classification_batch
process_loan_classification_batch(posting_date='$yesterday')
frappe.db.commit()
frappe.destroy()
"@

Log "=== Start-Frappe: startup sequence complete ==="
