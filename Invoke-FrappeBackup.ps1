# ============================================================
#  Invoke-FrappeBackup.ps1
#  1. Creates a Frappe site backup (with files)
#  2. Copies the backup out of the container to Windows
#  3. Syncs to Google Drive via rclone
#  4. Prunes local backups older than 7 days
#
#  Prerequisite: Start-Frappe.ps1 must have completed
#  successfully and Frappe must be healthy.
# ============================================================

$LogFile    = "C:\Logs\frappe-daily.log"
$BackupDest = "C:\Users\$env:USERNAME\FrappeBackups"
$Site       = "lending.localhost"
$Container  = "frappe_docker-backend-1"

function Log($msg) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp — $msg" | Tee-Object -FilePath $LogFile -Append
}

Log "=== Invoke-FrappeBackup: backup started ==="

# ── Create backup inside the container ───────────────────────────────────────
Log "Running bench backup..."
docker compose -p lending exec $Container bench --site $Site backup --with-files 2>&1 |
    Tee-Object -FilePath $LogFile -Append

# ── Copy backup files to Windows ─────────────────────────────────────────────
Log "Copying backups to Windows..."
$RemoteBackupPath = "/home/frappe/frappe-bench/sites/$Site/private/backups"
docker compose -p lending cp "${Container}:${RemoteBackupPath}/." $BackupDest 2>&1 |
    Tee-Object -FilePath $LogFile -Append

# ── Sync to Google Drive ─────────────────────────────────────────────────────
Log "Syncing to Google Drive..."
& "C:\Program Files\rclone\rclone.exe" sync $BackupDest "gdrive:FrappeBackups" `
    --log-file=$LogFile `
    --log-level INFO

# ── Prune old local backups ───────────────────────────────────────────────────
Log "Pruning local backups older than 7 days..."
Get-ChildItem $BackupDest -File |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
    Remove-Item -Force

Log "=== Invoke-FrappeBackup: all done ==="
