# =========================================
# file: bin/patch_invoices_routes_and_tests.sh
# =========================================
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
API_FILE="$ROOT/backend/app/routers/invoices.py"
TEST_FILE="$ROOT/backend/tests/test_routes_invoices.py"

mkdir -p "$(dirname "$API_FILE")" "$(dirname "$TEST_FILE")"

# --- backup ---
TS="$(date +%Y%m%d_%H%M%S)"
[[ -f "$API_FILE"  ]] && cp -a "$API_FILE"  "$API_FILE.bak_$TS"  || true
[[ -f "$TEST_FILE" ]] && cp -a "$TEST_FILE" "$TEST_FILE.bak_$TS" || true

# --- write files ---
cat > "$API_FILE" <<'PYEOF'
from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import StreamingResponse
from sqlalchemy import select, and_
from app.db import database
from app import models
from app.auth_utils import get_current_user  # doit retourner un dict avec company_id
from datetime import datetime
import io

router = APIRouter(prefix="/invoices", tags=["invoices"])

def _rec_to_dict(rec) -> dict:
    try:
        return dict(rec._mapping)
    except AttributeError:
        return dict(rec)

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

@router.get("/by-id/{invoice_id:int}/download.pdf")
async def download_invoice_pdf(invoice_id: int, user: dict = Depends(get_current_user)):
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
        f"<td style='text-align:right'>{(_rec_to_dict(l)['unit_price_cents'] or 0)/100:.2f}</td>"
        f"<td style='text-align:right'>{(_rec_to_dict(l)['total_cents'] or 0)/100:.2f}</td></tr>"
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
    import io
    fname = f"invoice_{inv['number'] or inv['id']}.pdf"
    return StreamingResponse(
        io.BytesIO(pdf_bytes),
        media_type="application/pdf",
        headers={"Content-Disposition": f'attachment; filename="{fname}"'},
    )
PYEOF

cat > "$TEST_FILE" <<'PYEOF'
from fastapi.testclient import TestClient
from starlette.routing import Route
from app.main import app

client = TestClient(app)

def _routes():
    return [r for r in app.routes if isinstance(r, Route)]

def _find(path: str, method: str):
    for r in _routes():
        if r.path == path and method.upper() in (r.methods or set()):
            return r
    return None

def test_has_static_list_route():
    assert _find("/invoices/_list", "GET") is not None

def test_no_legacy_dynamic_root():
    assert all(not r.path.startswith("/invoices/{") for r in _routes())

def test_has_by_id_routes():
    assert any(r.path.startswith("/invoices/by-id/{invoice_id}") for r in _routes())

def test_static_list_not_captured_by_dynamic_returns_not_422():
    resp = client.get("/invoices/_list")
    assert resp.status_code != 422

def test_by_id_path_requires_int():
    resp = client.get("/invoices/by-id/abc")
    assert resp.status_code == 422
PYEOF

echo "[STEP] docker compose restart api"
docker compose restart api

echo "[STEP] docker compose exec -T api pytest -q /app/tests/test_routes_invoices.py"
docker compose exec -T api pytest -q /app/tests/test_routes_invoices.py || {
  echo "Tests échoués — consulte les logs ci-dessus."
  exit 1
}

echo "✅ Routes & tests OK."