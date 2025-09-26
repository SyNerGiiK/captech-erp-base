# file: fix_download_button.ps1
# Usage: powershell -ExecutionPolicy Bypass -File .\fix_download_button.ps1
$ErrorActionPreference='Stop'
$root = Split-Path -Parent $PSCommandPath
$path = Join-Path $root "frontend/src/Invoices.jsx"
if (-not (Test-Path $path)) { throw "Introuvable: $path" }

# Charger source
$src = Get-Content $path -Raw

# Nouveau bouton (pas de template string, pas de backticks)
$buttonFixed = @'
<button onClick={async () => {
  if (!sel || !sel.id) { alert("Sélectionne une facture"); return; }
  const base = (import.meta.env.VITE_USE_PROXY==="1"?"/api":(import.meta.env.VITE_API_URL??"http://localhost:8000"));
  const url = base + "/invoices/" + sel.id + "/download.html?vat_percent=" + encodeURIComponent(vat);
  try {
    const token = localStorage.getItem("token") || "";
    const res = await fetch(url, { headers: { "Authorization": "Bearer " + token }});
    if (!res.ok) { throw new Error("download failed " + res.status); }
    const html = await res.text();
    const blob = new Blob([html], { type: "text/html" });
    const u = URL.createObjectURL(blob);
    window.open(u, "_blank");
    setTimeout(() => URL.revokeObjectURL(u), 10000);
  } catch(e) {
    alert("Téléchargement impossible: " + e.message);
  }
}}>Télécharger (HTML)</button>
'@

# 1) Supprimer toute ancienne version du bouton “Télécharger (HTML)”
$patternAnyBtn = [regex]'(?is)<button\b[^>]*>\s*T[ée]l[ée]charger\s*\(HTML\)\s*</button>'
$src = $patternAnyBtn.Replace($src, '', 1)

# 2) Insérer le bouton dans la barre d’actions (près de l’input TVA)
$anchor = 'style={{ marginLeft:"auto", display:"flex", gap:8 }}'
$idx = $src.IndexOf($anchor)
if ($idx -lt 0) { throw "Impossible de trouver la barre d’actions (ancre non trouvée)." }
$after = $src.IndexOf("</div>", $idx)
if ($after -le $idx) { throw "Impossible de localiser la fin du conteneur d’actions." }

# Insérer juste avant la fin du conteneur
$src = $src.Insert($after, "`n          " + $buttonFixed + "`n")

# Écrire en UTF-8 sans BOM
$enc = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($path, $src, $enc)
Write-Host "[OK] Bouton 'Télécharger (HTML)' corrigé"

# Redémarrer web
Write-Host "`n[STEP] docker compose restart web"
docker compose restart web | Out-Host

Write-Host "`n✅ Recharge http://localhost:3000 → Factures → Télécharger (HTML)"
Write-Host "Si ça coince : docker compose logs -f web"
