# file: repair_pdf_stack.ps1
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\repair_pdf_stack.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath
Set-Location $root

function Backup($p){
  if(Test-Path $p){
    $b = "$p.bak_$(Get-Date -Format yyyyMMdd_HHmmss)"
    Copy-Item $p $b -Force
    Write-Host "[BACKUP] $p -> $b"
  }
}
function ReadAll($p){ if(!(Test-Path $p)){ return $null } ; Get-Content $p -Raw }
function WriteUtf8NoBom([string]$Path,[string]$Content){
  $enc = New-Object System.Text.UTF8Encoding($false)
  [IO.File]::WriteAllText($Path,$Content,$enc)
}

# --- Paths
$dockerfile = Join-Path $root 'backend/Dockerfile'
$requirements = Join-Path $root 'backend/requirements.txt'
$invoicesJsx = Join-Path $root 'frontend/src/Invoices.jsx'
$seedPy      = Join-Path $root 'backend/seed_demo.py'

# --- 1) Dockerfile: forcer une version compatible WeasyPrint (runtime libs Pango/FT2)
if(!(Test-Path $dockerfile)){ throw "Missing: $dockerfile" }
Backup $dockerfile
$dockerfileContent = @'
FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
WORKDIR /app

# System deps for WeasyPrint
RUN apt-get update && apt-get install -y --no-install-recommends \
    libcairo2 \
    libpango-1.0-0 \
    libpangoft2-1.0-0 \
    libpangocairo-1.0-0 \
    libgdk-pixbuf-2.0-0 \
    libharfbuzz0b \
    libfribidi0 \
    fonts-dejavu-core \
 && rm -rf /var/lib/apt/lists/*

ENV PYTHONPATH=/app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .
CMD ["uvicorn","app.main:app","--host","0.0.0.0","--port","8000","--reload"]
'@
WriteUtf8NoBom $dockerfile $dockerfileContent
Write-Host "[OK] backend/Dockerfile written (WeasyPrint libs included)"

# --- 2) requirements.txt: s'assurer de la présence de weasyprint
if(!(Test-Path $requirements)){ throw "Missing: $requirements" }
Backup $requirements
$reqTxt = ReadAll $requirements
if($reqTxt -notmatch '(?m)^\s*weasyprint(\s*==.*)?\s*$'){
  $reqTxt = ($reqTxt.TrimEnd() + "`nweasyprint`n")
  WriteUtf8NoBom $requirements $reqTxt
  Write-Host "[OK] weasyprint added to requirements.txt"
}else{
  Write-Host "[OK] weasyprint already present"
}

# --- 3) Invoices.jsx: remplacer par une version clean (PDF-only)
if(!(Test-Path $invoicesJsx)){ throw "Missing: $invoicesJsx" }
Backup $invoicesJsx
$invoicesClean = @'
import React, { useEffect, useState } from "react";

export default function Invoices() {
  const [items, setItems] = useState([]);
  const [sel, setSel] = useState(null);
  const [loading, setLoading] = useState(false);
  const base = (import.meta.env.VITE_USE_PROXY==="1"?"/api":(import.meta.env.VITE_API_URL??"http://localhost:8000"));

  async function load() {
    setLoading(true);
    try {
      const token = localStorage.getItem("token") || "";
      const res = await fetch(base + "/invoices", { headers: { "Authorization": "Bearer " + token }});
      if (!res.ok) throw new Error("load invoices: " + res.status);
      const data = await res.json();
      setItems(data);
      if (data.length) setSel(data[0]);
    } catch (e) { alert(e.message); }
    finally { setLoading(false); }
  }
  useEffect(() => { load(); }, []);

  return (
    <div style={{ padding: 16 }}>
      <h2>Factures</h2>
      <div style={{ display:"flex", gap:8, alignItems:"center", marginBottom:12 }}>
        <button onClick={load} disabled={loading}>{loading ? "Chargement..." : "Rafraichir"}</button>
        <select value={sel?.id ?? ""} onChange={e=>{
          const id = Number(e.target.value);
          setSel(items.find(x=>x.id===id) || null);
        }}>
          <option value="">-- choisir une facture --</option>
          {items.map(inv => (
            <option key={inv.id} value={inv.id}>{inv.number} - {inv.title}</option>
          ))}
        </select>
        <button onClick={async ()=>{
          if (!sel?.id) { alert("Selectionne une facture"); return; }
          try {
            const token = localStorage.getItem("token") || "";
            const resp = await fetch(base + "/invoices/" + sel.id + "/signed_link", {
              method: "POST",
              headers: { "Authorization": "Bearer " + token }
            });
            if (!resp.ok) throw new Error("link failed " + resp.status);
            const data = await resp.json();
            const url = base + data.path; // /invoices/public/{id}/download.pdf?token=...
            window.open(url, "_blank");
          } catch(e) { alert("PDF link error: " + e.message); }
        }}>Telecharger (PDF)</button>
      </div>
      <ul>
        {items.map(inv => (
          <li key={inv.id}>{inv.number} - {inv.title} [{inv.status}] total: {Math.round((inv.total_cents||0)/100)} EUR</li>
        ))}
      </ul>
    </div>
  );
}
'@
WriteUtf8NoBom $invoicesJsx $invoicesClean
Write-Host "[OK] frontend/src/Invoices.jsx replaced (PDF-only, no HTML)"

# --- 4) seed_demo.py: jeu de données + lien signé PDF
Backup $seedPy
$seedPyContent = @'
import asyncio
from datetime import datetime
from sqlalchemy import select, func, and_
from app.db import database
from app import models
from app.link_utils import create_signed_token

async def main():
    await database.connect()
    utbl = models.User.__table__
    u = await database.fetch_one(select(utbl).limit(1))
    if not u:
        print("NO_USER")
        await database.disconnect()
        return
    company_id = int(u["company_id"])

    ctbl = models.Client.__table__
    itbl = models.Invoice.__table__
    ltbl = models.InvoiceLine.__table__

    client = await database.fetch_one(
        select(ctbl).where(and_(ctbl.c.company_id==company_id, ctbl.c.email=="demo.client@example.com"))
    )
    if client:
        cid = int(client["id"])
    else:
        cid = await database.execute(ctbl.insert().values(
            name="Client Demo", email="demo.client@example.com", phone="0600000000", company_id=company_id
        ))

    count = await database.fetch_val(select(func.count()).select_from(itbl).where(itbl.c.company_id==company_id)) or 0
    number = f"F-{datetime.utcnow().year}-{(int(count)+1):04d}"
    iid = await database.execute(itbl.insert().values(
        number=number, title="Facture Demo", status="sent", currency="EUR",
        total_cents=0, issued_date=datetime.utcnow().date(), due_date=None,
        client_id=cid, company_id=company_id
    ))

    total = 0
    for desc, qty, unit in [("Prestation A",2,15000), ("Prestation B",1,9900)]:
        total += qty*unit
        await database.execute(ltbl.insert().values(
            invoice_id=iid, description=desc, qty=int(qty), unit_price_cents=int(unit), total_cents=int(qty*unit)
        ))
    await database.execute(itbl.update().where(and_(itbl.c.id==iid, itbl.c.company_id==company_id)).values(total_cents=int(total)))

    token = create_signed_token(kind="invoice_pdf", data={"invoice_id": int(iid), "company_id": company_id}, ttl_seconds=900)
    print(f"OK {cid} {iid} {number} /invoices/public/{iid}/download.pdf?token={token}")
    await database.disconnect()

if __name__ == "__main__":
    asyncio.run(main())
'@
WriteUtf8NoBom $seedPy $seedPyContent
Write-Host "[OK] backend/seed_demo.py written"

# --- 5) Rebuild & restart
Write-Host "`n[STEP] docker compose build --no-cache api"
docker compose build --no-cache api | Out-Host

Write-Host "`n[STEP] docker compose up -d"
docker compose up -d | Out-Host

# --- 6) Exécuter le seed et ouvrir le PDF (public, pas d'auth)
Write-Host "`n[STEP] docker compose exec -T api python /app/seed_demo.py"
$out = & docker compose exec -T api python /app/seed_demo.py
$out = ($out | Out-String).Trim()
Write-Host "[seed] $out"
if($out -like "NO_USER*"){
  Write-Warning "Aucun user en base. Connecte-toi une fois dans le front pour creer l'admin, puis relance ce script."
  exit 1
}
if($out -notmatch '^OK\s+'){
  Write-Warning "Seed inattendu. Consulte: docker compose logs -f api"
  exit 1
}

$parts = $out -split '\s+'
$path  = $parts[-1]
$url   = "http://localhost:8000$path"
Write-Host "`n[OPEN] $url"
Start-Process $url | Out-Null
Write-Host "`n✅ PDF OK si WeasyPrint est bien chargé. Recharge http://localhost:3000 et teste l'onglet Factures (bouton PDF)."
