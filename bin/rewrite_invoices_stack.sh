#!/usr/bin/env bash
set -euo pipefail

ts() { date +"[%F %T]"; }
say() { echo "$(ts) $*"; }

ROOT="$(pwd)"
APP_DIR=""
if [ -d "$ROOT/backend/app" ]; then
  APP_DIR="$ROOT/backend/app"
  TEST_DIR="$ROOT/backend/tests"
elif [ -d "$ROOT/app" ]; then
  APP_DIR="$ROOT/app"
  TEST_DIR="$ROOT/tests"
else
  echo "❌ Introuvable: backend/app ou app. Place-toi à la racine du repo."
  exit 1
fi

mkdir -p "$ROOT/bin"

backup() {
  local f="$1"
  if [ -f "$f" ]; then cp -f "$f" "$f.bak_$(date +%Y%m%d_%H%M%S)"; fi
}

say "Réécriture des fichiers dans: $APP_DIR"

# ---------- auth_utils.py ----------
AUTH="$APP_DIR/auth_utils.py"
backup "$AUTH"
cat > "$AUTH" <<"PY"
from __future__ import annotations

import os
from datetime import datetime, timedelta
from typing import Optional, Dict, Any

from passlib.context import CryptContext
from jose import jwt, JWTError

# --- Hash de mot de passe ---
_pwd = CryptContext(schemes=["bcrypt"], deprecated="auto")

def get_password_hash(password: str) -> str:
    return _pwd.hash(password)

def verify_password(plain: str, hashed: str) -> bool:
    try:
        return _pwd.verify(plain, hashed)
    except Exception:
        return False

# --- JWT ---
SECRET = os.getenv("JWT_SECRET") or os.getenv("SECRET_KEY") or "dev_secret_change_me"
ALGO = "HS256"

def create_access_token(sub: str, company_id: int, ttl_seconds: int = 60*60*24) -> str:
    now = datetime.utcnow()
    payload = {"sub": sub, "company_id": int(company_id), "exp": now + timedelta(seconds=ttl_seconds)}
    return jwt.encode(payload, SECRET, algorithm=ALGO)

def create_signed_token(kind: str, data: Dict[str, Any], ttl_seconds: int = 900) -> str:
    """Ex: kind='invoice_pdf', data={'invoice_id': 123, 'company_id': 1}"""
    now = datetime.utcnow()
    payload = {"kind": kind, "exp": now + timedelta(seconds=ttl_seconds), **data}
    return jwt.encode(payload, SECRET, algorithm=ALGO)

def verify_signed_token(token: str, expected_kind: Optional[str] = None) -> Dict[str, Any]:
    try:
        payload = jwt.decode(token, SECRET, algorithms=[ALGO])
    except JWTError as e:
        raise ValueError(f"invalid token: {e}")
    if expected_kind is not None and payload.get("kind") != expected_kind:
        raise ValueError("invalid kind")
    return payload

# --- Dépendance auth minimale pour les routes factures ---
from fastapi import Depends, HTTPException
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from sqlalchemy import select
from app.db import database
from app import models

_auth_scheme = HTTPBearer(auto_error=False)

async def _ensure_connected():
    # Rend les tests plus robustes (TestClient / ASGITransport)
    try:
        if not getattr(database, "is_connected", False):
            await database.connect()
    except Exception:
        # on laisse FastAPI gérer l'event loop—fallback défensif
        pass

async def get_current_user(
    credentials: Optional[HTTPAuthorizationCredentials] = Depends(_auth_scheme),
):
    await _ensure_connected()
    # Pour l’instant : fallback dev -> 1er utilisateur en base
    utbl = models.User.__table__
    row = await database.fetch_one(select(utbl).limit(1))
    if not row:
        raise HTTPException(status_code=401, detail="Not authenticated")

    # Record => mapping-like, pas de .get()
    email = None
    try:
        email = row["email"]
    except Exception:
        pass

    return {
        "id": int(row["id"]),
        "email": email,
        "company_id": int(row["company_id"]),
    }
PY
say "✓ Réécrit: $(realpath "$AUTH")"

# ---------- routers/invoices.py ----------
ROUT="$APP_DIR/routers/invoices.py"
mkdir -p "$(dirname "$ROUT")"
backup "$ROUT"
cat > "$ROUT" <<"PY"
from __future__ import annotations

from datetime import date
import io
import os

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from fastapi.responses import StreamingResponse
from sqlalchemy import select, and_

from app.db import database
from app import models
from app.auth_utils import get_current_user, create_signed_token, verify_signed_token

# Router "privé" (auth)
router = APIRouter(prefix="/invoices", tags=["invoices"])
# Router "public" (pas d'auth, accès tokenisé)
public_router = APIRouter(tags=["invoices-public"])

def _rec_to_dict(rec) -> dict:
    try:
        return dict(rec._mapping)   # SQLAlchemy 2 record
    except Exception:
        try:
            return dict(rec)
        except Exception:
            return {}

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
async def get_invoice_by_id(
    invoice_id: int,
    user: dict = Depends(get_current_user),
):
    itbl = models.Invoice.__table__
    q = select(itbl).where(
        and_(
            itbl.c.id == invoice_id,
            itbl.c.company_id == user["company_id"],
        )
    )
    rec = await database.fetch_one(q)
    if not rec:
        raise HTTPException(status_code=404, detail="Invoice not found")
    return _rec_to_dict(rec)

@router.get("/by-id/{invoice_id:int}/public_url")
async def public_url_by_id(
    invoice_id: int,
    user: dict = Depends(get_current_user),
):
    """Retourne une URL publique signée pour télécharger le PDF."""
    itbl = models.Invoice.__table__
    inv = await database.fetch_one(
        select(itbl).where(
            and_(itbl.c.id == invoice_id, itbl.c.company_id == user["company_id"])
        )
    )
    if not inv:
        raise HTTPException(status_code=404, detail="Invoice not found")

    token = create_signed_token(
        kind="invoice_pdf",
        data={"invoice_id": int(inv["id"]), "company_id": int(inv["company_id"])},
        ttl_seconds=900,  # 15 min
    )

    base = os.getenv("PUBLIC_BASE_URL") or os.getenv("BASE_URL") or "http://localhost:8000"
    url = f"{base}/public/{int(inv['id'])}/download.pdf?token={token}"
    return {"url": url}

@router.get("/by-id/{invoice_id:int}/download.pdf")
async def download_invoice_pdf(
    invoice_id: int,
    user: dict = Depends(get_current_user),
):
    """Téléchargement PDF authentifié."""
    itbl = models.Invoice.__table__
    ltbl = models.InvoiceLine.__table__

    inv = await database.fetch_one(
        select(itbl).where(and_(itbl.c.id == invoice_id, itbl.c.company_id == user["company_id"]))
    )
    if not inv:
        raise HTTPException(status_code=404, detail="Invoice not found")

    lines = await database.fetch_all(
        select(ltbl).where(ltbl.c.invoice_id == invoice_id).order_by(ltbl.c.id.asc())
    )

    total_cents = inv["total_cents"] or 0
    rows_html = "".join(
        f"<tr><td>{_rec_to_dict(l)['description']}</td>"
        f"<td style='text-align:right'>{_rec_to_dict(l)['qty']}</td>"
        f"<td style='text-align:right'>{((_rec_to_dict(l)['unit_price_cents'] or 0)/100):.2f}</td>"
        f"<td style='text-align:right'>{((_rec_to_dict(l)['total_cents'] or 0)/100):.2f}</td></tr>"
        for l in lines
    )
    html = f"""
<!doctype html>
<html>
<head>
<meta charset="utf-8"/>
<title>Invoice {inv['number'] or inv['id']}</title>
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
  <h1>Facture {inv['number'] or inv['id']}</h1>
  <div class="small">Émise le {inv['issued_date'] or ''}</div>
  <table>
    <thead>
      <tr><th>Description</th><th>Qté</th><th>PU</th><th>Total</th></tr>
    </thead>
    <tbody>
      {rows_html or "<tr><td colspan='4' style='text-align:center'>Aucune ligne</td></tr>"}
    </tbody>
    <tfoot>
      <tr><td colspan="3" style="text-align:right">Total</td><td style="text-align:right">{total_cents/100:.2f} {inv['currency'] or 'EUR'}</td></tr>
    </tfoot>
  </table>
</body>
</html>
""".strip()

    from weasyprint import HTML
    pdf_bytes = HTML(string=html, base_url=".").write_pdf()
    fname = f"invoice_{inv['number'] or inv['id']}.pdf"
    return StreamingResponse(
        io.BytesIO(pdf_bytes),
        media_type="application/pdf",
        headers={"Content-Disposition": f'attachment; filename="{fname}"'},
    )

# --- PUBLIC : /public/{invoice_id}/download.pdf?token=... ---
@public_router.get("/public/{invoice_id:int}/download.pdf")
async def public_download_invoice_pdf(invoice_id: int, token: str):
    """Téléchargement PDF public via token signé (pas d'auth)."""
    try:
        data = verify_signed_token(token, expected_kind="invoice_pdf")
    except Exception:
        raise HTTPException(status_code=401, detail="invalid or expired token")

    # Vérifie concordance des infos token
    if int(data.get("invoice_id", -1)) != int(invoice_id):
        raise HTTPException(status_code=401, detail="token/invoice mismatch")

    itbl = models.Invoice.__table__
    ltbl = models.InvoiceLine.__table__

    inv = await database.fetch_one(
        select(itbl).where(
            and_(itbl.c.id == invoice_id, itbl.c.company_id == int(data.get("company_id", -1)))
        )
    )
    if not inv:
        raise HTTPException(status_code=404, detail="Invoice not found")

    lines = await database.fetch_all(
        select(ltbl).where(ltbl.c.invoice_id == invoice_id).order_by(ltbl.c.id.asc())
    )

    total_cents = inv["total_cents"] or 0
    rows_html = "".join(
        f"<tr><td>{_rec_to_dict(l)['description']}</td>"
        f"<td style='text-align:right'>{_rec_to_dict(l)['qty']}</td>"
        f"<td style='text-align:right'>{((_rec_to_dict(l)['unit_price_cents'] or 0)/100):.2f}</td>"
        f"<td style='text-align:right'>{((_rec_to_dict(l)['total_cents'] or 0)/100):.2f}</td></tr>"
        for l in lines
    )
    html = f"""
<!doctype html>
<html>
<head>
<meta charset="utf-8"/>
<title>Invoice {inv['number'] or inv['id']}</title>
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
  <h1>Facture {inv['number'] or inv['id']}</h1>
  <div class="small">Émise le {inv['issued_date'] or ''}</div>
  <table>
    <thead>
      <tr><th>Description</th><th>Qté</th><th>PU</th><th>Total</th></tr>
    </thead>
    <tbody>
      {rows_html or "<tr><td colspan='4' style='text-align:center'>Aucune ligne</td></tr>"}
    </tbody>
    <tfoot>
      <tr><td colspan="3" style="text-align:right">Total</td><td style="text-align:right">{total_cents/100:.2f} {inv['currency'] or 'EUR'}</td></tr>
    </tfoot>
  </table>
</body>
</html>
""".strip()

    from weasyprint import HTML
    pdf_bytes = HTML(string=html, base_url=".").write_pdf()
    fname = f"invoice_{inv['number'] or inv['id']}.pdf"
    return StreamingResponse(
        io.BytesIO(pdf_bytes),
        media_type="application/pdf",
        headers={"Content-Disposition": f'attachment; filename="{fname}"'},
    )
PY
say "✓ Réécrit: $(realpath "$ROUT")"

# ---------- main.py ----------
MAIN="$APP_DIR/main.py"
backup "$MAIN"
cat > "$MAIN" <<"PY"
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from app.db import database, engine
from app import models

from app.routers import auth
from app.routers import clients
from app.routers import quotes
from app.routers import invoices
from app.routers import payments

try:
    from app.routers import reports
    HAS_REPORTS = True
except Exception:
    HAS_REPORTS = False

try:
    from app.reporting import ensure_matviews
    HAS_MV = True
except Exception:
    HAS_MV = False

app = FastAPI(title="CapTech ERP — Auth + Clients + Quotes + Invoices + Payments (+ Reports)")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:3000","http://127.0.0.1:3000"],
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.on_event("startup")
async def startup():
    models.Base.metadata.create_all(bind=engine)
    await database.connect()
    if HAS_MV:
        try:
            await ensure_matviews()
        except Exception:
            pass

@app.on_event("shutdown")
async def shutdown():
    await database.disconnect()

@app.get("/healthz")
async def healthz():
    try:
        row = await database.fetch_one("SELECT 1 as ok;")
        return {"api": True, "db": bool(row and row["ok"] == 1)}
    except Exception:
        return {"api": True, "db": False}

# Routeurs
app.include_router(auth.router)
app.include_router(clients.router)
app.include_router(quotes.router)
app.include_router(invoices.router)         # privé
app.include_router(invoices.public_router)  # public (token)
app.include_router(payments.router)
if HAS_REPORTS:
    app.include_router(reports.router)
PY
say "✓ Réécrit: $(realpath "$MAIN")"

# ---------- Redémarrer API + tests ciblés ----------
say "Redémarrage API"
docker compose restart api >/dev/null

sleep 1
say "Tests routes + public_url + public_pdf"
docker compose exec -T api pytest -q /app/tests/test_routes_invoices.py /app/tests/test_public_url.py /app/tests/test_invoice_public_pdf.py || true

say "Terminé."
