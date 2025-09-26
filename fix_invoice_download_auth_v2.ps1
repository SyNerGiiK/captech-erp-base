# file: fix_invoice_download_auth_v2.ps1
# Usage: powershell -ExecutionPolicy Bypass -File .\fix_invoice_download_auth_v2.ps1
$ErrorActionPreference='Stop'
$root = Split-Path -Parent $PSCommandPath
$path = Join-Path $root "frontend/src/Invoices.jsx"
if (-not (Test-Path $path)) { throw "Introuvable: $path" }

# Chargement
$src = Get-Content $path -Raw

# Handler inline (ouvre HTML protégé via fetch + Authorization)
$handler = @"
async () => {
  const base = (import.meta.env.VITE_USE_PROXY==="1"?"/api":(import.meta.env.VITE_API_URL??"http://localhost:8000"));
  const url = `${base}/invoices/${sel?.id}/download.html?vat_percent=${encodeURIComponent(vat)}`;
  try {
    if (!sel?.id) throw new Error("no invoice selected");
    const res = await fetch(url, { headers: { "Authorization": \`Bearer \${localStorage.getItem("token")||""}\` }});
    if (!res.ok) throw new Error(\`download failed \${res.status}\`);
    const html = await res.text();
    const blob = new Blob([html], { type: "text/html" });
    const u = URL.createObjectURL(blob);
    window.open(u, "_blank");
    setTimeout(() => URL.revokeObjectURL(u), 10000);
  } catch(e) { alert("Téléchargement impossible: " + e.message); }
}
"@

$changed = $false

# 1) Cas le plus simple : remplacer un bouton existant <button onClick={downloadHTML}>Télécharger (HTML)</button>
$patternBtn = [regex]'<button\s+onClick=\{downloadHTML\}>\s*Télécharger\s*\(HTML\)\s*</button>'
if ($patternBtn.IsMatch($src)) {
  $replacement = "<button onClick={$handler}>Télécharger (HTML)</button>"
  $src = $patternBtn.Replace($src, $replacement, 1)
  $changed = $true
}

# 2) Sinon : remplacer tout bouton où le texte est "Télécharger (HTML)" (peu importe onClick)
if (-not $changed) {
  $patternAnyBtn = [regex]'<button\s+[^>]*>\s*Télécharger\s*\(HTML\)\s*</button>'
  if ($patternAnyBtn.IsMatch($src)) {
    $replacement = "<button onClick={$handler}>Télécharger (HTML)</button>"
    $src = $patternAnyBtn.Replace($src, $replacement, 1)
    $changed = $true
  }
}

# 3) Sinon : insérer le bouton dans la barre d’actions (à côté de l’input TVA)
if (-not $changed) {
  $anchor = 'style={{ marginLeft:"auto", display:"flex", gap:8 }}'
  $idx = $src.IndexOf($anchor)
  if ($idx -ge 0) {
    # Trouver la fin du <div ...> (insertion avant son premier </div> après l’ancre)
    $after = $src.IndexOf("</div>", $idx)
    if ($after -gt $idx) {
      $button = "<button onClick={$handler}>Télécharger (HTML)</button>"
      $src = $src.Insert($after, "`n          $button")
      $changed = $true
    }
  }
}

if (-not $changed) {
  throw "Impossible d’ajouter/patcher le bouton. Montre-moi un extrait de frontend/src/Invoices.jsx (la section des boutons)."
}

# Écrire en UTF-8 sans BOM
$enc = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($path, $src, $enc)
Write-Host "[OK] Invoices.jsx patché (download HTML authentifié)"

Write-Host "`n[STEP] docker compose restart web"
docker compose restart web | Out-Host

Write-Host "`n✅ Recharge http://localhost:3000 → Factures → “Télécharger (HTML)”"
Write-Host "En cas de souci: docker compose logs -f web"
