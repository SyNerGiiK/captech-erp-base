# apply_all_fixes.ps1
# Remet en place auth_utils + routes invoices (PDF public), et ajuste main.py
# Sauvegardes auto *.bak_YYYYmmddHHMMSS

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Backup-File($Path) {
  if (Test-Path $Path) {
    $stamp = (Get-Date).ToString("yyyyMMddHHmmss")
    Copy-Item $Path "$Path.bak_$stamp" -Force
  }
}

function Ensure-Dir($Path) {
  if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Force -Path $Path | Out-Null }
}

$repoRoot = (Get-Location).Path
$be = Join-Path $repoRoot "backend"
$app = Join-Path $be "app"
$routers = Join-Path $app "routers"

# 1) auth_utils.py canonique
$authUtilsPath = Join-Path $app "auth_utils.py"
Backup-File $authUtilsPath
$authUtils = @'
from __future__ import annotations

import os
from datetime import datetime, timedelta
from typing import Optional, Dict, Any

from passlib.context import CryptContext
from jose import jwt, JWTError

# --------------------------------------------------------------------------------------
# Password hashing (bcrypt via passlib)
# --------------------------------------------------------------------------------------
_pwd = CryptContext(schemes=["bcrypt"], deprecated="auto")

def get_password_hash(password: str) -> str:
    return _pwd.hash(password)

def verify_password(plain: str, hashed: str) -> bool:
    try:
        return _pwd.verify(plain, hashed)
    except Exception:
        return False

# --------------------------------------------------------------------------------------
# JWT settings (access + public)
# --------------------------------------------------------------------------------------
SECRET = os.getenv("JWT_SECRET") or os.getenv("SECRET_KEY") or "dev_secret_change_me"
ALGO = "HS256"

def create_access_token(sub: str, company_id: int, ttl_seconds: int = 60*60*24) -> str:
    now = datetime.utcnow()
    payload = {
        "sub": sub,
        "company_id": int(company_id),
        "exp": now + timedelta(seconds=ttl_seconds),
    }
    return jwt.encode(payload, SECRET, algorithm=ALGO)

# "Public" signed tokens (aussi en JWT pour rester homogène)
def create_signed_token(kind: str, data: Dict[str, Any], ttl_seconds: int = 900) -> str:
    now = datetime.utcnow()
    payload = {
        "kind": kind,
        "exp": now + timedelta(seconds=ttl_seconds),
        **data,
    }
    return jwt.encode(payload, SECRET, algorithm=ALGO)

def verify_signed_token(token: str, kind: Optional[str] = None) -> Dict[str, Any]:
    """
    Décode et valide le token public. Si 'kind' est fourni, on vérifie aussi ce champ.
    Lève ValueError si invalide/expiré.
    """
    try:
        payload = jwt.decode(token, SECRET, algorithms=[ALGO])
    except JWTError as e:
        raise ValueError(f"invalid token: {e}")  # attrapé par la route public
    if kind is not None and payload.get("kind") != kind:
        raise ValueError("invalid kind")
    return payload
'@
Set-Content -Path $authUtilsPath -Value $authUtils -Encoding UTF8
Write-Host "✓ backend/app/auth_utils.py écrit"

# 2) invoices.py avec routes complètes (inclut un router public séparé)
$invPath = Join-Path $routers "invoices.py"
Backup-File $invPath
$invoices = @'
from __future__ import annotations

from datetime import date
import io
import os
from typing import Dict, Any

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from fastapi.responses import StreamingResponse
from sqlalchemy import select, and_

from app.db import database
from app import models
from app.deps import get_current_user
from app.auth_utils import create_signed_token, verify_signed_token
from weasyprint import HTML

router = APIRouter(prefix="/invoices", tags=["invoices"])
public_router = APIRouter(tags=["public"])

def _rec_to_dict(rec) -> Dict[str, Any]:
    try:
        return dict(rec._mapping)
    except Exception:
        return dict(rec)

# --------- List / Get by id ---------------------------------------------------

@router.get("/_list")
async def list_invoices(
    limit: int = Query(50, ge=1, le=500),
    offset: int = Query(0, ge=0),
    user: dict = Depends(get_current_user),
):
    itbl = models.Invoice.__table__
    q = (
        select(
            itbl.c.id,
            itbl.c.number,
            itbl.c.title,
            itbl.c.status,
            itbl.c.currency,
            itbl.c.total_cents,
            itbl.c.issued_date,
            itbl.c.due_date,
            itbl.c.client_id,
        )
        .where(itbl.c.company_id == user["company_id"])
        .order_by(itbl.c.id.desc())
        .limit(limit)
        .offset(offset)
    )
    rows = await database.fetch_all(q)
    return [_rec_to_dict(r) for r in rows]

@router.get("/list")
async def list_invoices_alias(
    limit: int = Query(50, ge=1, le=500),
    offset: int = Query(0, ge=0),
    user: dict = Depends(get_current_user),
):
    return await list_invoices(limit=limit, offset=offset, user=user)

@router.get("/by-id/{invoice_id:int}")
async def get_invoice_by_id(invoice_id: int, user: dict = Depends(get_current_user)):
    itbl = models.Invoice.__table__
    q = select(itbl).where(
        and_(itbl.c.id == invoice_id, itbl.c.company_id == user["company_id"])
    )
    rec = await database.fetch_one(q)
    if not rec:
        raise HTTPException(status_code=404, detail="Invoice not found")
    return _rec_to_dict(rec)

# --------- PDF rendering -------------------------------------------------------

def _render_invoice_pdf(inv: Dict[str, Any], lines: list[Dict[str, Any]]) -> bytes:
    total_cents = inv.get("total_cents") or 0
    rows_html = "".join(
        f"<tr><td>{l.get('description','')}</td>"
        f"<td style='text-align:right'>{l.get('qty') or 0}</td>"
        f"<td style='text-align:right'>{(l.get('unit_price_cents') or 0)/100:.2f}</td>"
        f"<td style='text-align:right'>{(l.get('total_cents') or 0)/100:.2f}</td></tr>"
        for l in lines
    )
    html = f"""
<!doctype html>
<html>
<head>
<meta charset="utf-8"/>
<title>Invoice {inv.get('number') or inv.get('id')}</title>
<style>
body {{ font-family: Arial, sans-serif; font-size: 12px; }}
h1 {{ margin-bottom: 0; }}
table {{ width:100%; border-collapse: collapse; margin-top: 12px; }}
td, th {{ border: 1px solid #ccc; padding: 6px; }}
tfoot td {{ font-weight: bold; }}
.small {{ color: #666; font-size: 10px; }}
</style>
</head>
<body>
  <h1>Facture {inv.get('number') or inv.get('id')}</h1>
  <div class="small">Émise le {inv.get('issued_date') or ''}</div>
  <table>
    <thead>
      <tr><th>Description</th><th>Qté</th><th>PU</th><th>Total</th></tr>
    </thead>
    <tbody>
      {rows_html or "<tr><td colspan='4' style='text-align:center'>Aucune ligne</td></tr>"}
    </tbody>
    <tfoot>
      <tr><td colspan="3" style="text-align:right">Total</td><td style="text-align:right">{total_cents/100:.2f} {inv.get('currency') or 'EUR'}</td></tr>
    </tfoot>
  </table>
</body>
</html>
""".strip()
    return HTML(string=html, base_url=".").write_pdf()

@router.get("/by-id/{invoice_id:int}/download.pdf")
async def download_invoice_pdf(invoice_id: int, user: dict = Depends(get_current_user)):
    itbl = models.Invoice.__table__
    ltbl = models.InvoiceLine.__table__

    inv_rec = await database.fetch_one(
        select(itbl).where(and_(itbl.c.id == invoice_id, itbl.c.company_id == user["company_id"]))
    )
    if not inv_rec:
        raise HTTPException(status_code=404, detail="Invoice not found")
    inv = _rec_to_dict(inv_rec)

    lines = await database.fetch_all(
        select(ltbl).where(ltbl.c.invoice_id == invoice_id).order_by(ltbl.c.id.asc())
    )
    lines = [_rec_to_dict(l) for l in lines]

    pdf_bytes = _render_invoice_pdf(inv, lines)
    fname = f"invoice_{inv.get('number') or inv.get('id')}.pdf"
    return StreamingResponse(
        io.BytesIO(pdf_bytes),
        media_type="application/pdf",
        headers={"Content-Disposition": f'attachment; filename="{fname}"'},
    )

# --------- Public URL ----------------------------------------------------------

@router.get("/by-id/{invoice_id:int}/public_url")
async def public_url_by_id(invoice_id: int, user: dict = Depends(get_current_user)):
    itbl = models.Invoice.__table__
    inv = await database.fetch_one(
        select(itbl).where(and_(itbl.c.id == invoice_id, itbl.c.company_id == user["company_id"]))
    )
    if not inv:
        raise HTTPException(status_code=404, detail="Invoice not found")
    inv = _rec_to_dict(inv)

    token = create_signed_token(
        kind="invoice_pdf",
        data={"invoice_id": int(inv["id"]), "company_id": int(inv["company_id"])},
        ttl_seconds=900,
    )
    base = os.getenv("PUBLIC_BASE_URL") or os.getenv("BASE_URL") or "http://localhost:8000"
    url = f"{base}/public/{int(inv['id'])}/download.pdf?token={token}"
    return {"url": url}

# --------- Public download (no auth) ------------------------------------------

@public_router.get("/public/{invoice_id:int}/download.pdf")
async def public_download_invoice_pdf(invoice_id: int, token: str):
    # 1) valide token
    try:
        data = verify_signed_token(token, kind="invoice_pdf")
    except ValueError:
        raise HTTPException(status_code=401, detail="invalid or expired token")

    if int(data.get("invoice_id", -1)) != int(invoice_id):
        raise HTTPException(status_code=403, detail="token/invoice mismatch")

    # 2) charge facture & lignes (on checke le company_id issu du token)
    itbl = models.Invoice.__table__
    ltbl = models.InvoiceLine.__table__

    inv_rec = await database.fetch_one(
        select(itbl).where(and_(itbl.c.id == invoice_id, itbl.c.company_id == int(data.get("company_id", -1))))
    )
    if not inv_rec:
        raise HTTPException(status_code=404, detail="Invoice not found")
    inv = _rec_to_dict(inv_rec)

    lines = await database.fetch_all(
        select(ltbl).where(ltbl.c.invoice_id == invoice_id).order_by(ltbl.c.id.asc())
    )
    lines = [_rec_to_dict(l) for l in lines]

    # 3) rend PDF
    pdf_bytes = _render_invoice_pdf(inv, lines)
    fname = f"invoice_{inv.get('number') or inv.get('id')}.pdf"
    return StreamingResponse(
        io.BytesIO(pdf_bytes),
        media_type="application/pdf",
        headers={"Content-Disposition": f'attachment; filename="{fname}"'},
    )
'@
Set-Content -Path $invPath -Value $invoices -Encoding UTF8
Write-Host "✓ backend/app/routers/invoices.py écrit"

# 3) main.py : inclure le public_router et nettoyer les doublons éventuels
$mainPath = Join-Path $app "main.py"
Backup-File $mainPath
$main = Get-Content $mainPath -Raw -ErrorAction SilentlyContinue
if (-not $main) {
  throw "backend/app/main.py introuvable"
}

# a) s'assurer que l'import 'from app.routers import invoices' existe
if ($main -notmatch 'from app\.routers import invoices') {
  $main = $main -replace '(\nfrom app\.routers import[^\n]*\n)', "`$1from app.routers import invoices`n"
}

# b) ajouter include public_router si absent
if ($main -notmatch 'include_router\(invoices\.public_router\)') {
  # essayer d'ajouter juste après include_router(invoices.router)
  if ($main -match 'app\.include_router\(invoices\.router\)') {
    $main = $main -replace 'app\.include_router\(invoices\.router\)', "app.include_router(invoices.router)`napp.include_router(invoices.public_router)"
  } else {
    # sinon, ajouter à la fin
    $main = $main.TrimEnd() + "`napp.include_router(invoices.public_router)`n"
  }
}

# c) petit fix d’encodage possible dans le titre (remplacer caractères bizarres)
$main = $main -replace 'CapTech ERP.*', 'CapTech ERP — Auth + Clients + Quotes + Invoices + Payments (+ Reports)")'

Set-Content -Path $mainPath -Value $main -Encoding UTF8
Write-Host "✓ backend/app/main.py patché"

Write-Host ""
Write-Host "Tout est écrit. Commandes suggérées :" -ForegroundColor Cyan
Write-Host "  docker compose build --no-cache api"
Write-Host "  docker compose up -d"
Write-Host "  # Optionnel: tests rapides publics (si présents)"
Write-Host "  docker compose exec -T api pytest -q /app/tests/test_public_url.py"
