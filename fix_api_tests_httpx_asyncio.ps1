# file: fix_api_tests_httpx_asyncio.ps1
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\fix_api_tests_httpx_asyncio.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath
Set-Location $root

function WriteUtf8NoBom([string]$Path,[string]$Content){
  $enc = New-Object System.Text.UTF8Encoding($false)
  [IO.File]::WriteAllText($Path,$Content,$enc)
}

$testPath = Join-Path $root 'backend/tests/test_invoice_public_pdf.py'
if(!(Test-Path $testPath)){ throw "Introuvable: $testPath" }

# Backup
$backup = "$testPath.bak_$(Get-Date -Format yyyyMMdd_HHmmss)"
Copy-Item $testPath $backup -Force
Write-Host "[BACKUP] $testPath -> $backup"

# Rewrite test with ASGITransport + asyncio backend
$code = @'
import time
from datetime import datetime
import pytest
from httpx import AsyncClient, ASGITransport
from sqlalchemy import select, and_

from app.main import app
from app.db import database
from app import models
from app.link_utils import create_signed_token

# Force AnyIO to use asyncio only (évite l'install de trio)
@pytest.fixture
def anyio_backend():
    return "asyncio"

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
        await database.execute(
            itbl.update().where(and_(itbl.c.id==iid, itbl.c.company_id==company_id)).values(total_cents=12345)
        )

        token = create_signed_token(
            kind="invoice_pdf",
            data={"invoice_id": int(iid), "company_id": company_id},
            ttl_seconds=300
        )

        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
            r = await ac.get(f"/invoices/public/{iid}/download.pdf", params={"token": token, "vat_percent": 20})
            assert r.status_code == 200
            ct = r.headers.get("content-type","")
            assert ct.startswith("application/pdf")
            assert r.content[:4] == b"%PDF"
    finally:
        await database.disconnect()

@pytest.mark.anyio
async def test_public_invoice_pdf_invalid_token():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        r = await ac.get("/invoices/public/999999/download.pdf", params={"token": "not-a-valid-token"})
        assert r.status_code == 401
'@

WriteUtf8NoBom $testPath $code
Write-Host "[OK] Test mis à jour -> $testPath"

# Run pytest inside API container
Write-Host "`n[STEP] docker compose exec -T api pytest -q /app/tests/test_invoice_public_pdf.py"
$rc = 0
try{
  docker compose exec -T api pytest -q /app/tests/test_invoice_public_pdf.py
} catch {
  $rc = 1
}
if($rc -ne 0){
  Write-Host "`n[HINT] Echec tests. Regarde: docker compose logs -f api"
  exit $rc
}
Write-Host "`n✅ Tests OK."
