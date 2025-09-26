# file: fix_invoices_fetch.ps1
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\fix_invoices_fetch.ps1
$ErrorActionPreference='Stop'
$root = Split-Path -Parent $PSCommandPath
Set-Location $root

function WriteUtf8NoBom([string]$Path,[string]$Content){
  $enc = New-Object System.Text.UTF8Encoding($false)
  [IO.File]::WriteAllText($Path,$Content,$enc)
}

# 1) Env front: appeler l'API directement (pas de proxy)
$envPath = Join-Path $root 'frontend/.env.local'
$envContent = @"
VITE_USE_PROXY=0
VITE_API_URL=http://localhost:8000
"@
WriteUtf8NoBom $envPath $envContent
Write-Host "[OK] frontend/.env.local écrit"

# 2) Patch Invoices.jsx -> /invoices/ (trailing slash)
$jsx = Join-Path $root 'frontend/src/Invoices.jsx'
if(!(Test-Path $jsx)){ throw "Introuvable: $jsx" }
$txt = Get-Content $jsx -Raw
# viser la ligne du GET
$before = 'fetch(base + "/invoices", { headers: { "Authorization": "Bearer " + token }})'
$after  = 'fetch(base + "/invoices/", { headers: { "Authorization": "Bearer " + token }})'
if($txt -like "*$before*"){
  $txt = $txt -replace [regex]::Escape($before), [System.Text.RegularExpressions.Regex]::Escape($after).Replace('\\','')
  WriteUtf8NoBom $jsx $txt
  Write-Host "[OK] Invoices.jsx -> utilise /invoices/ (avec slash)"
}else{
  # fallback plus large si la ligne a bougé
  $txt2 = $txt -replace 'fetch\(\s*base \+ "/invoices"\s*,', 'fetch(base + "/invoices/",'
  if($txt2 -ne $txt){
    WriteUtf8NoBom $jsx $txt2
    Write-Host "[OK] Invoices.jsx patché (regex) -> /invoices/"
  } else {
    Write-Warning "Aucun remplacement trouvé: vérifie le contenu de $jsx"
  }
}

# 3) Restart web
Write-Host "`n[STEP] docker compose restart web"
docker compose restart web | Out-Host

Write-Host "`n✅ Done. Ouvre http://localhost:3000 → Factures."
Write-Host "   Si ça re-fail: Ctrl+F5, puis regarde les requêtes réseau:"
Write-Host "   - GET http://localhost:8000/invoices/ doit renvoyer 200 (pas 307)."
