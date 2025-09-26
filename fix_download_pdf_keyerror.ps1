# file: fix_download_pdf_keyerror.ps1
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\fix_download_pdf_keyerror.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath
Set-Location $root

$path = Join-Path $root 'backend/app/routers/invoices.py'
if(!(Test-Path $path)){ throw "Introuvable: $path" }

# Backup
$backup = "$path.bak_$(Get-Date -Format yyyyMMdd_HHmmss)"
Copy-Item $path $backup -Force
Write-Host "[BACKUP] $path -> $backup"

# Read/patch
$text = Get-Content $path -Raw
if($text -notmatch 'inv\.get\("number"\)'){
  Write-Host "[INFO] Rien à patcher (inv.get('number') introuvable)."
} else {
  $text = $text -replace 'inv\.get\("number"\)','dict(inv).get("number")'
  # Optionnel: sécuriser aussi l'accès au champ number si on veut être 100% dict-based :
  # $text = $text -replace "invoice_\{inv\['number'\]\}\.pdf","invoice_{dict(inv).get('number', str(invoice_id))}.pdf"
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [IO.File]::WriteAllText($path, $text, $utf8NoBom)
  Write-Host "[OK] Patch appliqué dans invoices.py"
}

# Restart API
Write-Host "`n[STEP] docker compose restart api"
docker compose restart api | Out-Host

Write-Host "`n✅ Teste maintenant un lien PDF:"
Write-Host "  - Via front: onglet Factures > 'Telecharger (PDF)'"
Write-Host "  - Ou via seed: powershell -ExecutionPolicy Bypass -File .\seed_demo.ps1"
Write-Host "  - Check logs: docker compose logs -f api"
