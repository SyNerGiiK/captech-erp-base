from __future__ import annotations

from datetime import date
import io
import os

from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import StreamingResponse, HTMLResponse
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
        return dict(rec._mapping)   # SQLAlchemy 2
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
    try:
        if not getattr(database, 'is_connected', False):
            return []
    except Exception:
        return []
    itbl = models.Invoice.__table__
    q = (
        select(
            itbl.c.id, itbl.c.number, itbl.c.title, itbl.c.status,
            itbl.c.currency, itbl.c.total_cents, itbl.c.issued_date,
            itbl.c.due_date, itbl.c.client_id,
        )
        .where(itbl.c.company_id == user["company_id"])
        .order_by(itbl.c.id.desc())
        .limit(limit).offset(offset)
    )
    rows = await database.fetch_all(q)
    return [_rec_to_dict(r) for r in rows]

@router.get("/list")
async def list_invoices_alias(
    limit: int = Query(50, ge=1, le=500),
    offset: int = Query(0, ge=0),
    user: dict = Depends(get_current_user),
):
    try:
        if not getattr(database, 'is_connected', False):
            return []
    except Exception:
        return []
    return await list_invoices(limit=limit, offset=offset, user=user)

@router.get("/by-id/{invoice_id:int}")
async def get_invoice_by_id(
    invoice_id: int,
    user: dict = Depends(get_current_user),
):
    itbl = models.Invoice.__table__
    q = select(itbl).where(
        and_(itbl.c.id == invoice_id, itbl.c.company_id == user["company_id"])
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
        select(itbl).where(and_(itbl.c.id == invoice_id, itbl.c.company_id == user["company_id"]))
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

def _render_pdf(inv, lines):
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
    return fname, pdf_bytes

@router.get("/by-id/{invoice_id:int}/download.pdf")
async def download_invoice_pdf(
    invoice_id: int,
    user: dict = Depends(get_current_user),
):
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

    fname, pdf_bytes = _render_pdf(inv, lines)
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

    # Sécurité : cohérence token/id
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

    fname, pdf_bytes = _render_pdf(inv, lines)
    return StreamingResponse(
        io.BytesIO(pdf_bytes),
        media_type="application/pdf",
        headers={"Content-Disposition": f'attachment; filename="{fname}"'},
    )
