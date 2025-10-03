#!/usr/bin/env bash
set -euo pipefail

# Va à la racine du repo
cd "$(dirname "$0")/.."

TARGET="backend/app/routers/invoices.py"
BACKUP="${TARGET}.bak_$(date +%Y%m%d_%H%M%S)"

echo "[BACKUP] $TARGET -> $BACKUP"
cp "$TARGET" "$BACKUP"

echo "[WRITE] $TARGET"
cat > "$TARGET" <<'PY'
from __future__ import annotations

from datetime import date
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import StreamingResponse
from sqlalchemy import and_, select

from app import models
from app.auth_utils import get_current_user, verify_signed_token
from app.db import database

# Un seul router, préfixé /invoices (évite les doublons et 404)
router = APIRouter(prefix="/invoices", tags=["invoices"])


def _rec_to_dict(rec) -> dict:
    """Compat pour Row/Record 'databases' / SQLAlchemy 2."""
    try:
        return dict(rec._mapping)
    except AttributeError:
        return dict(rec)


# =========================
# LIST & GET BY ID (privé)
# =========================

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
    # alias pour compat UI
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


# =========================
# RENDER PDF (helper)
# =========================

def _render_invoice_html(inv: dict, lines: list[dict], vat_percent: float = 0.0) -> str:
    total_cents = inv.get("total_cents") or 0
    total_eur = total_cents / 100.0
    vat = round(total_eur * (vat_percent / 100.0), 2) if vat_percent else 0.0
    grand_total = round(total_eur + vat, 2)

    rows_html = "".join(
        f"<tr><td>{l.get('description','')}</td>"
        f"<td style='text-align:right'>{l.get('qty',0)}</td>"
        f"<td style='text-align:right'>{(l.get('unit_price_cents') or 0)/100:.2f}</td>"
        f"<td style='text-align:right'>{(l.get('total_cents') or 0)/100:.2f}</td></tr>"
        for l in lines
    )
    rows_html = rows_html or "<tr><td colspan='4' style='text-align:center'>Aucune ligne</td></tr>"

    return f"""
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
.right {{ text-align: right; }}
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
      {rows_html}
    </tbody>
    <tfoot>
      <tr><td colspan="3" class="right">Sous-total</td><td class="right">{total_eur:.2f} {inv.get('currency') or 'EUR'}</td></tr>
      <tr><td colspan="3" class="right">TVA {vat_percent:.0f}%</td><td class="right">{vat:.2f} {inv.get('currency') or 'EUR'}</td></tr>
      <tr><td colspan="3" class="right">Total TTC</td><td class="right">{grand_total:.2f} {inv.get('currency') or 'EUR'}</td></tr>
    </tfoot>
  </table>
</body>
</html>
""".strip()


async def _build_invoice_pdf(invoice_id: int, company_id: int, vat_percent: float) -> bytes:
    itbl = models.Invoice.__table__
    ltbl = models.InvoiceLine.__table__

    inv_rec = await database.fetch_one(
        select(itbl).where(and_(itbl.c.id == invoice_id, itbl.c.company_id == company_id))
    )
    if not inv_rec:
        raise HTTPException(status_code=404, detail="Invoice not found")

    inv = _rec_to_dict(inv_rec)
    line_recs = await database.fetch_all(
        select(ltbl).where(ltbl.c.invoice_id == invoice_id).order_by(ltbl.c.id.asc())
    )
    lines = [_rec_to_dict(l) for l in line_recs]

    html = _render_invoice_html(inv, lines, vat_percent)
    from weasyprint import HTML
    pdf_bytes = HTML(string=html, base_url=".").write_pdf()
    return pdf_bytes


# =========================
# DOWNLOAD PDF (privé)
# =========================

@router.get("/by-id/{invoice_id:int}/download.pdf")
async def download_invoice_pdf(
    invoice_id: int,
    user: dict = Depends(get_current_user),
    vat_percent: float = Query(0.0, ge=0.0, le=100.0),
):
    pdf_bytes = await _build_invoice_pdf(invoice_id, int(user["company_id"]), vat_percent)
    fname = f"invoice_{invoice_id}.pdf"
    return StreamingResponse(
        iter([pdf_bytes]),
        media_type="application/pdf",
        headers={"Content-Disposition": f'attachment; filename="{fname}"'},
    )


# ==============================================
# DOWNLOAD PDF (public via token signé)  **⇦**
#  - chemin attendu par les tests:
#    GET /invoices/public/{invoice_id}/download.pdf?token=...&vat_percent=...
#  - 401 si token invalide/expiré
#  - 404 si facture absente
# ==============================================

@router.get("/public/{invoice_id:int}/download.pdf")
async def public_download_invoice_pdf(
    invoice_id: int,
    token: str = Query(..., description="Jeton signé"),
    vat_percent: float = Query(0.0, ge=0.0, le=100.0),
):
    data: Optional[dict] = verify_signed_token(token)
    # Token invalide / expiré
    if not data or "company_id" not in data or "invoice_id" not in data:
        raise HTTPException(status_code=401, detail="Invalid or expired token")

    # Le token doit viser cette facture précise
    if int(data["invoice_id"]) != int(invoice_id):
        raise HTTPException(status_code=401, detail="Invalid token for this invoice")

    company_id = int(data["company_id"])

    pdf_bytes = await _build_invoice_pdf(invoice_id, company_id, vat_percent)
    fname = f"invoice_{invoice_id}.pdf"
    return StreamingResponse(
        iter([pdf_bytes]),
        media_type="application/pdf",
        headers={"Content-Disposition": f'attachment; filename="{fname}"'},
    )
PY

echo "[RESTART] docker compose restart api"
docker compose restart api

echo "[TEST] pytest ciblé (public PDF)"
docker compose exec -T api pytest -q /app/tests/test_invoice_public_pdf.py
