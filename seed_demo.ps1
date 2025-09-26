# file: seed_demo.ps1
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\seed_demo.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath
Set-Location $root

function Backup($p){ if(Test-Path $p){ $b="$p.bak_$(Get-Date -Format yyyyMMdd_HHmmss)"; Copy-Item $p $b -Force; Write-Host "[BACKUP] $p -> $b" } }
function ReadAll($p){ if(!(Test-Path $p)){ throw "Missing: $p" }; Get-Content $p -Raw }
function WriteUtf8NoBom([string]$Path,[string]$Content){ $enc = New-Object System.Text.UTF8Encoding($false); [IO.File]::WriteAllText($Path,$Content,$enc) }

# --- Ensure WeasyPrint present (requirements + Dockerfile) ---
$req = Join-Path $root 'backend/requirements.txt'
$df  = Join-Path $root 'backend/Dockerfile'
if(!(Test-Path $req) -or !(Test-Path $df)){ throw "Expected backend/requirements.txt and backend/Dockerfile" }

$reqText = ReadAll $req
if($reqText -notmatch '(?m)^\s*weasyprint(\s*==.*)?\s*$'){
  Backup $req
  $reqText = ($reqText.TrimEnd() + "`nweasyprint`n")
  WriteUtf8NoBom $req $reqText
  Write-Host "[OK] weasyprint added to requirements.txt"
}else{ Write-Host "[OK] weasyprint already in requirements.txt" }

$dfText = ReadAll $df
if($dfText -notmatch 'libcairo2'){
  # try to patch: insert apt-get deps before pip install -r requirements.txt
  $pattern = 'COPY\s+requirements\.txt\s+\.\s*\r?\n\s*RUN\s+pip install[^\r\n]+-r requirements\.txt'
  if([regex]::IsMatch($dfText, $pattern)){
    Backup $df
    $block = @'
COPY requirements.txt .
# Deps for WeasyPrint (Debian)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libcairo2 \
    libpango-1.0-0 \
    libgdk-pixbuf-2.0-0 \
    libharfbuzz0b \
    libfribidi0 \
    fonts-dejavu-core \
  && rm -rf /var/lib/apt/lists/* \
  && pip install --no-cache-dir -r requirements.txt
'@
    $dfText = [regex]::Replace($dfText, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $block })
    WriteUtf8NoBom $df $dfText
    Write-Host "[OK] Dockerfile patched with cairo/pango libs"
  } else {
    Write-Warning "Could not auto-patch Dockerfile. Ensure apt-get libs are present for WeasyPrint."
  }
} else {
  Write-Host "[OK] Dockerfile already contains cairo/pango libs"
}

# --- Rebuild API (fresh) ---
Write-Host "`n[STEP] docker compose build --no-cache api"
docker compose build --no-cache api | Out-Host

Write-Host "`n[STEP] docker compose up -d api"
docker compose up -d api | Out-Host

# --- Create seed_demo.py inside backend (mapped to /app in container) ---
$seedPyPath = Join-Path $root 'backend/seed_demo.py'
$seedPy = @'
import asyncio
from datetime import datetime
from sqlalchemy import select, func, and_
from app.db import database
from app import models
from app.link_utils import create_signed_token

async def main():
    await database.connect()
    # pick any existing user to get company_id
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

    # ensure demo client
    client = await database.fetch_one(
        select(ctbl).where(and_(ctbl.c.company_id==company_id, ctbl.c.email=="demo.client@example.com"))
    )
    if client:
        cid = int(client["id"])
    else:
        cid = await database.execute(ctbl.insert().values(
            name="Client Demo",
            email="demo.client@example.com",
            phone="0600000000",
            company_id=company_id
        ))

    # create invoice
    count = await database.fetch_val(
        select(func.count()).select_from(itbl).where(itbl.c.company_id==company_id)
    ) or 0
    number = f"F-{datetime.utcnow().year}-{(int(count)+1):04d}"
    iid = await database.execute(itbl.insert().values(
        number=number,
        title="Facture Demo",
        status="draft",
        currency="EUR",
        total_cents=0,
        issued_date=None,
        due_date=None,
        client_id=cid,
        company_id=company_id
    ))

    # add lines
    lines = [("Prestation A", 2, 15000), ("Prestation B", 1, 9900)]
    total = 0
    for desc, qty, unit in lines:
        total += qty * unit
        await database.execute(ltbl.insert().values(
            invoice_id=iid,
            description=desc,
            qty=int(qty),
            unit_price_cents=int(unit),
            total_cents=int(qty*unit),
        ))
    await database.execute(
        itbl.update().where(and_(itbl.c.id==iid, itbl.c.company_id==company_id)).values(total_cents=int(total))
    )

    # mark sent to set dates (optional)
    await database.execute(itbl.update().where(itbl.c.id==iid).values(status="sent"))

    # make signed link (PDF)
    token = create_signed_token(
        kind="invoice_pdf",
        data={"invoice_id": int(iid), "company_id": company_id},
        ttl_seconds=900
    )
    path = f"/invoices/public/{iid}/download.pdf?token={token}"
    print("OK", cid, iid, number, path)

    await database.disconnect()

if __name__ == "__main__":
    asyncio.run(main())
'@
Backup $seedPyPath
WriteUtf8NoBom $seedPyPath $seedPy
Write-Host "[OK] backend/seed_demo.py written"

# --- Execute seed in the api container ---
Write-Host "`n[STEP] docker compose exec api python /app/seed_demo.py"
# -T avoids pseudo-TTY issues on Windows
$cmd = "docker compose exec -T api python /app/seed_demo.py"
$proc = Start-Process -FilePath "powershell" -ArgumentList "-NoProfile","-Command",$cmd -PassThru -Wait -WindowStyle Hidden
# Grab output by re-running with capture (simpler approach below):
try{
  $out = & docker compose exec -T api python /app/seed_demo.py
}catch{
  Write-Warning "Seed execution returned non-zero. Retrying once..."
  Start-Sleep -Seconds 2
  $out = & docker compose exec -T api python /app/seed_demo.py
}
$out = ($out | Out-String).Trim()
Write-Host "[seed output] $out"

if($out -like "NO_USER*"){
  Write-Warning "No user found in DB. Please create an admin user via the app, then re-run seed_demo.ps1."
  exit 1
}
if($out -notmatch '^OK\s+'){
  Write-Warning "Unexpected seed output. Check 'docker compose logs -f api'."
  exit 1
}

# Parse: OK <cid> <iid> <number> <path>
$parts = $out -split '\s+'
$path  = $parts[-1]
$iid   = $parts[-2]
$number= $parts[-3]
Write-Host "`n[OK] Demo created:"
Write-Host "  Invoice ID : $iid"
Write-Host "  Number     : $number"
Write-Host "  Path       : $path"

# Open PDF public link (does not need auth)
$base = "http://localhost:8000"
$url  = "$base$path"
Write-Host "`n[OPEN] $url"
Start-Process $url | Out-Null

Write-Host "`nDone. If PDF fails to render, ensure api image includes WeasyPrint system libs and rebuild with --no-cache."
