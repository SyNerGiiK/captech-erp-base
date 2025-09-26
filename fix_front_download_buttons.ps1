# file: fix_front_download_buttons.ps1
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\fix_front_download_buttons.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath
$path = Join-Path $root 'frontend/src/Invoices.jsx'
if (-not (Test-Path $path)) { throw "Introuvable: $path" }

# 1) Backup
$bak = "$path.bak_$(Get-Date -Format yyyyMMdd_HHmmss)"
Copy-Item $path $bak -Force
Write-Host "[BACKUP] -> $bak"

# 2) Lire source
$src = Get-Content $path -Raw

# 3) Supprimer tout ancien bouton Téléchargement (HTML|PDF), y compris handlers cassés
#    - on cible <button ...> ... Télécharger (HTML|PDF) ... </button> en DOTALL
$reBtnAny = [regex]'(?is)<button\b[^>]*>\s*T[ée]l[ée]charger\s*\((?:HTML|PDF)\)\s*</button>'
$src = $reBtnAny.Replace($src, '', 0)

# 4) Définir boutons propres (utilisent les liens signés côté API)
$btnHtml = @'
<button onClick={async () => {
  if (!sel || !sel.id) { alert("Sélectionne une facture"); return; }
  const base = (import.meta.env.VITE_USE_PROXY==="1"?"/api":(import.meta.env.VITE_API_URL??"http://localhost:8000"));
  try {
    const token = localStorage.getItem("token") || "";
    const resp = await fetch(base + "/invoices/" + sel.id + "/signed_link?kind=html&ttl=300", {
      method: "POST",
      headers: { "Authorization": "Bearer " + token }
    });
    if (!resp.ok) throw new Error("link failed " + resp.status);
    const data = await resp.json();
    const url = base + data.path; // /invoices/public/{id}/download.html?token=...
    window.open(url, "_blank");
  } catch(e) { alert("Lien HTML impossible: " + e.message); }
}}>Télécharger (HTML)</button>
'@

$btnPdf = @'
<button onClick={async () => {
  if (!sel || !sel.id) { alert("Sélectionne une facture"); return; }
  const base = (import.meta.env.VITE_USE_PROXY==="1"?"/api":(import.meta.env.VITE_API_URL??"http://localhost:8000"));
  try {
    const token = localStorage.getItem("token") || "";
    const resp = await fetch(base + "/invoices/" + sel.id + "/signed_link?kind=pdf&ttl=300", {
      method: "POST",
      headers: { "Authorization": "Bearer " + token }
    });
    if (!resp.ok) throw new Error("link failed " + resp.status);
    const data = await resp.json();
    const url = base + data.path; // /invoices/public/{id}/download.pdf?token=...
    window.open(url, "_blank");
  } catch(e) { alert("Lien PDF impossible: " + e.message); }
}}>Télécharger (PDF)</button>
'@

# 5) Trouver la barre d’actions (même ancre que précédemment)
$anchors = @(
  'style={{ marginLeft:"auto", display:"flex", gap:8 }}',
  'style={{ marginLeft:"auto", display:"flex", gap: 8 }}'
)
$anchorIdx = -1
$anchorText = $null
foreach($a in $anchors){
  $i = $src.IndexOf($a)
  if($i -ge 0){ $anchorIdx = $i; $anchorText = $a; break }
}
if($anchorIdx -lt 0){
  throw "Impossible de trouver la barre d’actions (ancre non trouvée). Montre-moi la section des boutons d’actions de Invoices.jsx."
}

# 6) Insérer juste avant la fin du conteneur d’actions
$after = $src.IndexOf("</div>", $anchorIdx)
if($after -le $anchorIdx){ throw "Impossible de localiser la fin du conteneur d’actions." }

$insertion = "`n          " + $btnHtml + "`n          " + $btnPdf + "`n"
$src = $src.Insert($after, $insertion)

# 7) Écrire en UTF-8 sans BOM
$enc = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($path, $src, $enc)
Write-Host "[OK] Boutons HTML/PDF propres injectés dans Invoices.jsx"

# 8) Redémarrer le conteneur web
Write-Host "`n[STEP] docker compose restart web"
docker compose restart web | Out-Host

Write-Host "`n✅ Recharge http://localhost:3000 (onglet Factures)."
Write-Host "   • 'Télécharger (HTML)' et 'Télécharger (PDF)' ouvrent via lien signé (pas d’Authorization dans l’onglet)."
Write-Host "   • Si Vite cache encore l’ancien code: ctrl+F5."
