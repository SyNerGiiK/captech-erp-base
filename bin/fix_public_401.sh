#!/usr/bin/env bash
set -euo pipefail

ts(){ date +"[%F %T]"; }

echo "$(ts) Patch auth_utils.py (exp en timestamp + clean)"
python3 - <<'PY'
from pathlib import Path
p = Path("backend/app/auth_utils.py")
src = p.read_text(encoding="utf-8")

# 1) force exp en timestamp (int) pour create_access_token et create_signed_token
src = src.replace(
    "def create_access_token(sub: str, company_id: int, ttl_seconds: int = 60*60*24) -> str:",
    "def create_access_token(sub: str, company_id: int, ttl_seconds: int = 60*60*24) -> str:"
).replace(
    "payload = {\"sub\": sub, \"company_id\": int(company_id), \"exp\": now + timedelta(seconds=ttl_seconds)}",
    "exp = int((datetime.utcnow() + timedelta(seconds=ttl_seconds)).timestamp())\n    payload = {\"sub\": sub, \"company_id\": int(company_id), \"exp\": exp}"
)

src = src.replace(
    "def create_signed_token(kind: str, data: Dict[str, Any], ttl_seconds: int = 900) -> str:",
    "def create_signed_token(kind: str, data: Dict[str, Any], ttl_seconds: int = 900) -> str:"
).replace(
    "payload = {\"kind\": kind, \"exp\": now + timedelta(seconds=ttl_seconds), **data}",
    "exp = int((datetime.utcnow() + timedelta(seconds=ttl_seconds)).timestamp())\n    payload = {\"kind\": kind, \"exp\": exp, **data}"
)

# 2) petite fonction utilitaire _rec_get déjà présente : on la garde
# 3) ne rien changer à verify_signed_token (il accepte expected_kind)

p.write_text(src, encoding="utf-8")
print("OK")
PY

echo "$(ts) Ré-écrit l’endpoint public (sans Depends auth, vérif stricte token)"
python3 - <<'PY'
from pathlib import Path
import re

p = Path("backend/app/routers/invoices.py")
src = p.read_text(encoding="utf-8")

# Assure qu'on a bien un public_router séparé et un seul endpoint /public/{invoice_id}/download.pdf
# On remplace/insère une implémentation connue-bonne.

# 1) S'il n'y a pas de public_router, on l'ajoute après le router principal
if "public_router = APIRouter(" not in src:
    src = src.replace(
        "router = APIRouter(prefix=\"/invoices\", tags=[\"invoices\"])",
        "router = APIRouter(prefix=\"/invoices\", tags=[\"invoices\"])\\npublic_router = APIRouter(tags=[\"public-invoices\"])"
    )

# 2) Supprime toute ancienne définition de /public/... dans ce fichier pour éviter les doublons
src = re.sub(
    r"@(?:router|public_router)\.get\(\"/public/\{invoice_id.*?download\.pdf\"[\s\S]*?def [\s\S]*?\n\)",
    "",
    src,
    flags=re.M
)

# 3) Ajoute une version robuste de l’endpoint public
public_impl = r'''
@public_router.get("/public/{invoice_id}/download.pdf")
async def public_download_invoice_pdf(
    invoice_id: int,
    token: str = Query(..., description="JWT signé retour de /invoices/.../public_url"),
    vat_percent: float | None = Query(None, ge=0, le=100),
):
    """
    Endpoint *public* (pas d'auth) qui vérifie un JWT court et renvoie le PDF.
    - `token` doit être signé par `create_signed_token(kind="invoice_pdf", ...)`
    - vérifie correspondance invoice_id + company_id
    """
    from fastapi import HTTPException
    from sqlalchemy import select, and_
    from app.auth_utils import verify_signed_token
    from app.db import database
    from app import models

    # 1) Vérification du token
    try:
        payload = verify_signed_token(token, expected_kind="invoice_pdf")
    except Exception:
        raise HTTPException(status_code=401, detail="Invalid or expired token")

    try:
        tok_invoice_id = int(payload.get("invoice_id"))
        tok_company_id = int(payload.get("company_id"))
    except Exception:
        raise HTTPException(status_code=401, detail="Invalid token payload")

    if tok_invoice_id != int(invoice_id):
        raise HTTPException(status_code=401, detail="Token / invoice mismatch")

    # 2) Charge facture + lignes, et vérifie l'appartenance à la bonne société
    itbl = models.Invoice.__table__
    ltbl = models.InvoiceLine.__table__

    inv = await database.fetch_one(
        select(itbl).where(and_(itbl.c.id == invoice_id, itbl.c.company_id == tok_company_id))
    )
    if not inv:
        # soit pas trouvé, soit appartient à une autre société -> 404
        raise HTTPException(status_code=404, detail="Invoice not found")

    lines = await database.fetch_all(
        select(ltbl).where(ltbl.c.invoice_id == invoice_id).order_by(ltbl.c.id.asc())
    )

    def _rec_to_dict(rec):
        try:
            return dict(rec._mapping)
        except AttributeError:
            try:
                return dict(rec)
            except Exception:
                return {}

    total_cents = (inv["total_cents"] or 0) if inv else 0
    rows_html = "".join(
        f"<tr><td>{_rec_to_dict(l).get('description','')}</td>"
        f"<td style='text-align:right'>{_rec_to_dict(l).get('qty',0)}</td>"
        f"<td style='text-align:right'>{((_rec_to_dict(l).get('unit_price_cents',0) or 0)/100):.2f}</td>"
        f"<td style='text-align:right'>{((_rec_to_dict(l).get('total_cents',0) or 0)/100):.2f}</td></tr>"
        for l in lines
    )

    total_display = total_cents / 100.0
    if vat_percent:
        total_display = total_display * (1 + float(vat_percent)/100.0)

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
      <tr><td colspan="3" style="text-align:right">Total</td>
          <td style="text-align:right">{total_display:.2f} {inv['currency'] or 'EUR'}</td></tr>
    </tfoot>
  </table>
</body>
</html>
""".strip()

    # 3) Génère le PDF
    try:
        from weasyprint import HTML
        pdf_bytes = HTML(string=html, base_url=".").write_pdf()
    except Exception as e:
        # Si weasyprint indispo, renvoie HTML en attendant (utile en dev)
        return HTMLResponse(content=html, status_code=200, media_type="text/html")

    import io
    fname = f"invoice_{inv['number'] or inv['id']}.pdf"
    return StreamingResponse(
        io.BytesIO(pdf_bytes),
        media_type="application/pdf",
        headers={"Content-Disposition": f'attachment; filename="{fname}"'},
    )
'''.lstrip()

# Imports sûrs pour cette implémentation
imports = """
from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import StreamingResponse, HTMLResponse
from sqlalchemy import select, and_
from app.db import database
from app import models
"""

# S'assurer que HTMLResponse est importé et Query disponible
if "HTMLResponse" not in src:
    src = src.replace("from fastapi.responses import StreamingResponse",
                      "from fastapi.responses import StreamingResponse, HTMLResponse")

if " Query" not in src and "from fastapi import APIRouter, Depends, HTTPException, Query" not in src:
    src = src.replace("from fastapi import APIRouter, Depends, HTTPException",
                      "from fastapi import APIRouter, Depends, HTTPException, Query")

# Injecte/append l'implémentation publique
if 'def public_download_invoice_pdf(' not in src:
    src = src.rstrip() + "\n\n" + public_impl + "\n"

Path("backend/app/routers/invoices.py").write_text(src, encoding="utf-8")
print("OK")
PY

echo "$(ts) Vérifie que main.py inclut public_router"
python3 - <<'PY'
from pathlib import Path
p = Path("backend/app/main.py")
src = p.read_text(encoding="utf-8")
if "from app.routers import invoices" not in src:
    print("ERREUR: import invoices manquant dans main.py", flush=True)
if "app.include_router(invoices.public_router)" not in src:
    src = src.replace(
        "app.include_router(invoices.router)",
        "app.include_router(invoices.router)\napp.include_router(invoices.public_router)"
    )
    p.write_text(src, encoding="utf-8")
    print("Ajout public_router -> main.py")
else:
    print("public_router déjà inclus")
PY

echo "$(ts) Restart API"
docker compose restart api >/dev/null

echo "$(ts) Run tests"
docker compose exec -T api pytest -q \
  /app/tests/test_routes_invoices.py \
  /app/tests/test_public_url.py \
  /app/tests/test_invoice_public_pdf.py
