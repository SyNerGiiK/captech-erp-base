from __future__ import annotations

from datetime import date
import os
import io

from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import StreamingResponse
from sqlalchemy import select, and_

from app.db import database
from app import models
from app.auth_utils import (
    get_current_user,
    create_signed_token,
    verify_signed_token,
)
from weasyprint import HTML


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
def _rec_to_dict(rec) -> dict:
    """Compat dict(record) pour asyncpg / SQLAlchemy rows"""
    try:
        return dict(rec._mapping)
    except AttributeError:
        return dict(rec)


def _render_invoice_pdf_bytes(inv: dict, lines: list[dict]) -> bytes:
    """Construit un petit HTML et renvoie le PDF en bytes."""
    rows_html = "".join(
        f"<tr>"
        f"<td>{l.get('description','')}</td>"
        f"<td style='text-align:right'>{l.get('qty', 0)}</td>"
        f"<td style='text-align:right'>{(l.get('unit_price_cents') or 0)/100:.2f}</td>"
        f"<td style='text-align:right'>{(l.get('total_cents') or 0)/100:.2f}</td>"
        f"</tr>"
        for l in lines
    )
    total_cents = inv.get("total_cents") or 0
    number_or_id = inv.get("number") or inv.get("id")

    html = f"""
<!doctype html>
<html>
<head>
<meta charset="utf-8"/>
<title>Invoice {number_or_id}</title>
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
  <h1>Facture {number_or_id}</h1>
  <div class="small">Émise le {inv.get('issued_date') or ''}</div>
  <table>
    <thead>
      <tr><th>Description</th><th>Qté</th><th>PU</th><th>Total</th></tr>
    </thead>
    <tbody>
      {rows_html or "<tr><td colspan='4' style='text-align:center'>Aucune ligne</td></tr>"}
    </tbody>
    <tfoot>
      <tr>
        <td colspan="3" style="text-align:right">Total</td>
        <td style="text-align:right">{total_cents/100:.2f} {inv.get('currency') or 'EUR'}</td>
      </tr>
    </tfoot>
  </table>
</body>
</html>
""".strip()

    return HTML(string=html, base_url=".").write_pdf()


# -----------------------------------------------------------------------------
# Router privé /invoices  (auth requis)
# -----------------------------------------------------------------------------
router = APIRouter(prefix="/invoices", tags=["invoices"])


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


@router.get("/by-id/{invoice_id:int}/download.pdf")
async def download_invoice_pdf(
    invoice_id: int,
    user: dict = Depends(get_current_user),
):
    itbl = models.Invoice.__table__
    ltbl = models.InvoiceLine.__table__

    inv_row = await database.fetch_one(
        select(itbl).where(
            and_(
                itbl.c.id == invoice_id,
                itbl.c.company_id == user["company_id"],
            )
        )
    )
    if not inv_row:
        raise HTTPException(status_code=404, detail="Invoice not found")

    inv = _rec_to_dict(inv_row)
    lines = await database.fetch_all(
        select(ltbl).where(ltbl.c.invoice_id == invoice_id).order_by(ltbl.c.id.asc())
    )
    line_dicts = [_rec_to_dict(l) for l in lines]

    pdf_bytes = _render_invoice_pdf_bytes(inv, line_dicts)
    fname = f"invoice_{inv.get('number') or inv.get('id')}.pdf"
    return StreamingResponse(
        io.BytesIO(pdf_bytes),
        media_type="application/pdf",
        headers={"Content-Disposition": f'attachment; filename="{fname}"'},
    )


@router.get("/by-id/{invoice_id:int}/public_url")
async def public_url_by_id(
    invoice_id: int,
    user: dict = Depends(get_current_user),
):
    """
    Retourne une URL publique signée pour télécharger le PDF.
    """
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

    base = (
        os.getenv("PUBLIC_BASE_URL") or os.getenv("BASE_URL") or "http://localhost:8000"
    )
    return {"url": f"{base}/public/{int(inv['id'])}/download.pdf?token={token}"}


# -----------------------------------------------------------------------------
# Router public (pas d'auth) pour /public/{invoice_id}/download.pdf
# -----------------------------------------------------------------------------
public_router = APIRouter(tags=["invoices-public"])


@public_router.get("/public/{invoice_id:int}/download.pdf")
async def public_download_invoice_pdf(invoice_id: int, token: str):
    """
    Téléchargement public via token signé.
    """
    # 1) Vérifie / décode le token
    try:
        data = verify_signed_token(token, expected_kind="invoice_pdf")
    except Exception:
        raise HTTPException(status_code=401, detail="Invalid or expired token")

    # 2) Anti-confusion d'ID
    if int(data.get("invoice_id", 0)) != int(invoice_id):
        raise HTTPException(status_code=400, detail="Token/invoice mismatch")

    # 3) Récupère la facture dans la bonne société
    itbl = models.Invoice.__table__
    ltbl = models.InvoiceLine.__table__

    inv_row = await database.fetch_one(
        select(itbl).where(
            and_(
                itbl.c.id == invoice_id,
                itbl.c.company_id == int(data.get("company_id", 0)),
            )
        )
    )
    if not inv_row:
        raise HTTPException(status_code=404, detail="Invoice not found")

    inv = _rec_to_dict(inv_row)
    lines = await database.fetch_all(
        select(ltbl).where(ltbl.c.invoice_id == invoice_id).order_by(ltbl.c.id.asc())
    )
    line_dicts = [_rec_to_dict(l) for l in lines]

    pdf_bytes = _render_invoice_pdf_bytes(inv, line_dicts)
    fname = f"invoice_{inv.get('number') or inv.get('id')}.pdf"
    return StreamingResponse(
        io.BytesIO(pdf_bytes),
        media_type="application/pdf",
        headers={"Content-Disposition": f'attachment; filename="{fname}"'},
    )
