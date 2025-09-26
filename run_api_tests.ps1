# file: run_api_tests.ps1
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\run_api_tests.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath
Set-Location $root

function WriteUtf8NoBom([string]$Path,[string]$Content){
  $enc = New-Object System.Text.UTF8Encoding($false)
  [IO.File]::WriteAllText($Path,$Content,$enc)
}
function Ensure-Line([string]$file,[string]$needle){
  $txt = Get-Content $file -Raw
  if($txt -notmatch [regex]::Escape($needle)){
    $txt = ($txt.TrimEnd() + "`n$needle`n")
    WriteUtf8NoBom $file $txt
    Write-Host "[OK] Added to $(Split-Path $file -Leaf): $needle"
  } else {
    Write-Host "[OK] Already present in $(Split-Path $file -Leaf): $needle"
  }
}

# 1) Créer le test
$testsDir = Join-Path $root 'backend/tests'
$newTest  = Join-Path $testsDir 'test_invoice_public_pdf.py'
New-Item -ItemType Directory -Force -Path $testsDir | Out-Null

$testCode = @'
import time
from datetime import datetime
import pytest
from httpx import AsyncClient
from sqlalchemy import select, and_

from app.main import app
from app.db import database
from app import models
from app.link_utils import create_signed_token

# Pourquoi: test end-to-end sans réseau (ASGI), garantit que le PDF public fonctionne
@pytest.mark.anyio
async def test_public_invoice_pdf_success():
    await database.connect()
    try:
        utbl = models.User.__table__
        u = await database.fetch_one(select(utbl).limit(1))
        if not u:
            pytest.skip("No user in DB. Create admin via UI, then rerun tests.")
        company_id = int(u["company_id"])

        ctbl = models.Client.__table__
        itbl = models.Invoice.__table__
        ltbl = models.InvoiceLine.__table__

        # client
        cid = await database.execute(ctbl.insert().values(
            name="Test Client",
            email=f"test.client.{int(time.time())}@example.com",
            phone="0600000000",
            company_id=company_id
        ))
        # facture + ligne
        iid = await database.execute(itbl.insert().values(
            number=f"T-{int(time.time())}",
            title="Test PDF",
            status="sent",
            currency="EUR",
            total_cents=0,
            issued_date=datetime.utcnow().date(),
            due_date=None,
            client_id=cid,
            company_id=company_id,
        ))
        await database.execute(ltbl.insert().values(
            invoice_id=iid, description="Ligne test", qty=1, unit_price_cents=12345, total_cents=12345
        ))
        await database.execute(itbl.update().where(and_(itbl.c.id==iid, itbl.c.company_id==company_id)).values(total_cents=12345))

        token = create_signed_token(kind="invoice_pdf", data={"invoice_id": int(iid), "company_id": company_id}, ttl_seconds=300)

        async with AsyncClient(app=app, base_url="http://test") as ac:
            r = await ac.get(f"/invoices/public/{iid}/download.pdf", params={"token": token, "vat_percent": 20})
            assert r.status_code == 200
            ct = r.headers.get("content-type","")
            assert ct.startswith("application/pdf")
            assert r.content[:4] == b"%PDF"
    finally:
        await database.disconnect()

@pytest.mark.anyio
async def test_public_invoice_pdf_invalid_token():
    async with AsyncClient(app=app, base_url="http://test") as ac:
        r = await ac.get("/invoices/public/999999/download.pdf", params={"token": "not-a-valid-token"})
        assert r.status_code == 401
'@
WriteUtf8NoBom $newTest $testCode
Write-Host "[OK] Wrote tests -> backend/tests/test_invoice_public_pdf.py"

# 2) Ajouter deps de test
$req = Join-Path $root 'backend/requirements.txt'
if(!(Test-Path $req)){ throw "Missing: backend/requirements.txt" }
Ensure-Line $req 'pytest'
Ensure-Line $req 'anyio'
Ensure-Line $req 'httpx'

# 3) Build & up
Write-Host "`n[STEP] docker compose build --no-cache api"
docker compose build --no-cache api | Out-Host

Write-Host "`n[STEP] docker compose up -d"
docker compose up -d | Out-Host

# 4) Run pytest in container
Write-Host "`n[STEP] docker compose exec -T api pytest -q /app/tests/test_invoice_public_pdf.py"
$rc = 0
try{
  docker compose exec -T api pytest -q /app/tests/test_invoice_public_pdf.py
} catch {
  $rc = 1
}
if($rc -ne 0){
  Write-Host "`n[HINT] Check logs: docker compose logs -f api"
  exit $rc
}
Write-Host "`n✅ Tests passed. Endpoint public PDF couvert."
