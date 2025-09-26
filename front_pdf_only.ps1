# file: front_pdf_only.ps1
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\front_pdf_only.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath
$path = Join-Path $root 'frontend/src/Invoices.jsx'
if (-not (Test-Path $path)) { throw "Introuvable: $path" }

# 1) Backup
$bak = "$path.bak_$(Get-Date -Format yyyyMMdd_HHmmss)"
Copy-Item $path $bak -Force
Write-Host "[BACKUP] -> $bak"

# 2) Lire la source
$src = Get-Content $path -Raw

# 3) Supprimer tous les anciens boutons (HTML + PDF), même cassés (DOTALL)
$reBtnHtml = [regex]'(?is)<button\b[^>]*>[\s\S]*?\(HTML\)[\s\S]*?<\/button>'
$reBtnPdf  = [regex]'(?is)<button\b[^>]*>[\s\S]*?\(PDF\)[\s\S]*?<\/button>'
$src = $reBtnHtml.Replace($src, '', 0)
$src = $reBtnPdf.Replace($src, '', 0)

# 4) Supprimer une éventuelle ancienne fonction downloadHTML (si elle existe)
$reFn = [regex]'(?is)const\s+downloadHTML\s*=\s*async\s*\([^)]*\)\s*=>\s*\{[\s\S]*?\};'
$src = $reFn.Replace($src, '', 1)

# 5) Préparer le bouton PDF propre (lien signé, pas de template string)
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

# 6) Trouver la barre d’actions et insérer le bouton
$anchors = @(
  'style={{ marginLeft:"auto", display:"flex", gap:8 }}',
  'style={{ marginLeft:"auto", display:"flex", gap: 8 }}'
)
$anchorIdx = -1
foreach($a in $anchors){
  $i = $src.IndexOf($a)
  if($i -ge 0){ $anchorIdx = $i; break }
}
if($anchorIdx -lt 0){ throw "Impossible de trouver la barre d’actions (ancre non trouvée). Montre-moi la section des boutons dans Invoices.jsx." }

$after = $src.IndexOf("</div>", $anchorIdx)
if($after -le $anchorIdx){ throw "Impossible de localiser la fin du conteneur d’actions." }

$src = $src.Insert($after, "`n          " + $btnPdf + "`n")

# 7) Écrire en UTF-8 sans BOM
$enc = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($path, $src, $enc)
Write-Host "[OK] Invoices.jsx nettoyé (HTML retiré) + bouton PDF propre inséré"

# 8) Redémarrer web
Write-Host "`n[STEP] docker compose restart web"
docker compose restart web | Out-Host

Write-Host "`n✅ Recharge http://localhost:3000 (onglet Factures)."
Write-Host "   • Il ne reste que “Télécharger (PDF)” (lien signé, pas d’Authorization dans l’onglet)."
Write-Host "   • Si Vite garde un cache: Ctrl+F5."
