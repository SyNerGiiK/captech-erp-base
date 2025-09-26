# file: enforce_pdf_only_v2.ps1
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\enforce_pdf_only_v2.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath
Set-Location $root

function Backup($p){
  if(Test-Path $p){
    $b = "$p.bak_$(Get-Date -Format yyyyMMdd_HHmmss)"
    Copy-Item $p $b -Force
    Write-Host "[BACKUP] $p -> $b"
  }
}

function Write-Utf8NoBom([string]$Path,[string]$Content){
  $enc = New-Object System.Text.UTF8Encoding($false)
  [IO.File]::WriteAllText($Path,$Content,$enc)
}

# -------------------------------
# 1) BACKEND: invoices.py (PDF only)
# -------------------------------
$invPy = Join-Path $root "backend/app/routers/invoices.py"
if(!(Test-Path $invPy)){ throw "Missing: $invPy" }
Backup $invPy

$invoicesPdfOnly = @'
from fastapi import APIRouter, Depends, HTTPException, Query
from starlette.responses import StreamingResponse
from starlette.responses import HTMLResponse  # kept for simple error output if needed
from sqlalchemy import select, and_, func
from datetime import datetime, date, timedelta
from typing import Literal
import csv, io, os

from jinja2 import Environment, FileSystemLoader, select_autoescape
from weasyprint import HTML

from app.db import database
from app import models, schemas
from app.deps import get_current_user
from app.link_utils import create_signed_token, verify_signed_token

router = APIRouter(prefix="/invoices", tags=["invoices"])

# -------- utils --------
def _make_number(seq: int) -> str:
    y = datetime.utcnow().year
    return f"F-{y}-{seq:04d}"

async def _owned_invoice(invoice_id: int, company_id: int):
    itbl = models.Invoice.__table__
    row = await database.fetch_one(
        select(itbl).where(and_(itbl.c.id == invoice_id, itbl.c.company_id == company_id))
    )
    if not row:
        raise HTTPException(status_code=404, detail="Invoice not found")
    return row

async def _ensure_client(cid: int, company_id: int):
    ctbl = models.Client.__table__
    row = await database.fetch_one(
        select(ctbl.c.id).where(and_(ctbl.c.id == cid, ctbl.c.company_id == company_id))
    )
    if not row:
        raise HTTPException(status_code=400, detail="Client not in your company")

async def _recalc_invoice(invoice_id: int, company_id: int) -> int:
    ltbl = models.InvoiceLine.__table__
    itbl = models.Invoice.__table__
    total = await database.fetch_val(
        select(func.coalesce(func.sum(ltbl.c.total_cents), 0)).where(ltbl.c.invoice_id == invoice_id)
    )
    await database.execute(
        itbl.update()
        .where(and_(itbl.c.id == invoice_id, itbl.c.company_id == company_id))
        .values(total_cents=int(total or 0))
    )
    return int(total or 0)

async def _render_invoice_html(invoice_id: int, company_id: int, vat_percent: int) -> str:
    inv = await _owned_invoice(invoice_id, company_id)
    ltbl, ctbl, comp = models.InvoiceLine.__table__, models.Client.__table__, models.Company.__table__
    lines = await database.fetch_all(
        select(ltbl).where(ltbl.c.invoice_id == invoice_id).order_by(ltbl.c.id.asc())
    )
    client = await database.fetch_one(select(ctbl).where(ctbl.c.id == inv["client_id"]))
    company = await database.fetch_one(select(comp).where(comp.c.id == company_id))

    ptbl = models.Payment.__table__
    subtotal = await database.fetch_val(
        select(func.coalesce(func.sum(ltbl.c.total_cents), 0)).where(ltbl.c.invoice_id == invoice_id)
    ) or 0
    paid = await database.fetch_val(
        select(func.coalesce(func.sum(ptbl.c.amount_cents), 0)).where(ptbl.c.invoice_id == invoice_id)
    ) or 0
    vat = round(int(subtotal) * (vat_percent / 100.0))
    total = int(subtotal) + int(vat)
    due = max(0, total - int(paid))
    summary = {
        "vat_percent": vat_percent,
        "subtotal_cents": int(subtotal),
        "vat_cents": int(vat),
        "total_cents": int(total),
        "paid_cents": int(paid),
        "due_cents": int(due),
    }

    base_dir = os.path.dirname(os.path.dirname(__file__))  # app/
    tpl_dir = os.path.join(base_dir, "templates")
    env = Environment(loader=FileSystemLoader(tpl_dir), autoescape=select_autoescape())
    tpl = env.get_template("invoice.html")
    return tpl.render(
        invoice=inv._mapping,
        lines=[dict(r) for r in lines],
        client=dict(client),
        company=dict(company),
        summary=summary,
    )

# -------- CRUD ----------
@router.post("/", response_model=schemas.InvoiceOut)
async def create_invoice(payload: schemas.InvoiceCreate, user=Depends(get_current_user)):
    await _ensure_client(payload.client_id, user["company_id"])
    itbl = models.Invoice.__table__
    count = await database.fetch_val(
        select(func.count()).select_from(itbl).where(itbl.c.company_id == user["company_id"])
    )
    number = _make_number(int(count) + 1)
    iid = await database.execute(
        itbl.insert().values(
            number=number,
            title=payload.title,
            status="draft",
            currency=payload.currency or "EUR",
            total_cents=0,
            issued_date=payload.issued_date,
            due_date=payload.due_date,
            client_id=payload.client_id,
            company_id=user["company_id"],
        )
    )
    row = await database.fetch_one(select(itbl).where(itbl.c.id == iid))
    return dict(row)

@router.get("/", response_model=list[schemas.InvoiceOut])
async def list_invoices(
    status: str | None = None,
    q: str | None = None,
    limit: int = 50,
    offset: int = 0,
    user=Depends(get_current_user),
):
    itbl = models.Invoice.__table__
    cond = [itbl.c.company_id == user["company_id"]]
    if status:
        cond.append(itbl.c.status == status)
    if q:
        cond.append(itbl.c.title.ilike(f"%{q}%"))
    rows = await database.fetch_all(
        select(itbl)
        .where(and_(*cond))
        .order_by(itbl.c.id.desc())
        .limit(limit)
        .offset(offset)
    )
    return [dict(r) for r in rows]

@router.get("/{invoice_id}", response_model=schemas.InvoiceOut)
async def get_invoice(invoice_id: int, user=Depends(get_current_user)):
    itbl = models.Invoice.__table__
    row = await database.fetch_one(
        select(itbl).where(and_(itbl.c.id == invoice_id, itbl.c.company_id == user["company_id"]))
    )
    if not row:
        raise HTTPException(status_code=404, detail="Invoice not found")
    return dict(row)

@router.patch("/{invoice_id}", response_model=schemas.InvoiceOut)
async def update_invoice(invoice_id: int, payload: schemas.InvoiceUpdate, user=Depends(get_current_user)):
    itbl = models.Invoice.__table__
    existing = await _owned_invoice(invoice_id, user["company_id"])
    if existing["status"] not in ("draft", "sent"):
        raise HTTPException(status_code=400, detail="Only draft/sent can be updated")
    data = existing._mapping.copy()
    for k, v in payload.model_dump(exclude_unset=True).items():
        data[k] = v
    await database.execute(
        itbl.update()
        .where(itbl.c.id == invoice_id)
        .values(
            title=data["title"],
            status=data["status"],
            issued_date=data["issued_date"],
            due_date=data["due_date"],
            currency=data["currency"],
        )
    )
    row = await database.fetch_one(select(itbl).where(itbl.c.id == invoice_id))
    return dict(row)

# -------- Lines ----------
@router.get("/{invoice_id}/lines", response_model=list[schemas.InvoiceLineOut])
async def list_lines(invoice_id: int, user=Depends(get_current_user)):
    await _owned_invoice(invoice_id, user["company_id"])
    ltbl = models.InvoiceLine.__table__
    rows = await database.fetch_all(
        select(ltbl).where(ltbl.c.invoice_id == invoice_id).order_by(ltbl.c.id.asc())
    )
    return [dict(r) for r in rows]

@router.post("/{invoice_id}/lines", response_model=schemas.InvoiceLineOut)
async def add_line(invoice_id: int, payload: schemas.InvoiceLineCreate, user=Depends(get_current_user)):
    inv = await _owned_invoice(invoice_id, user["company_id"])
    if inv["status"] not in ("draft", "sent"):
        raise HTTPException(status_code=400, detail="Cannot add line on this status")
    ltbl = models.InvoiceLine.__table__
    total = int(payload.qty) * int(payload.unit_price_cents)
    lid = await database.execute(
        ltbl.insert().values(
            invoice_id=invoice_id,
            description=payload.description,
            qty=int(payload.qty),
            unit_price_cents=int(payload.unit_price_cents),
            total_cents=total,
        )
    )
    await _recalc_invoice(invoice_id, user["company_id"])
    row = await database.fetch_one(select(ltbl).where(ltbl.c.id == lid))
    return dict(row)

@router.delete("/{invoice_id}/lines/{line_id}", status_code=204)
async def delete_line(invoice_id: int, line_id: int, user=Depends(get_current_user)):
    inv = await _owned_invoice(invoice_id, user["company_id"])
    if inv["status"] not in ("draft", "sent"):
        raise HTTPException(status_code=400, detail="Cannot delete line on this status")
    ltbl = models.InvoiceLine.__table__
    await database.execute(
        ltbl.delete().where(and_(ltbl.c.id == line_id, ltbl.c.invoice_id == invoice_id))
    )
    await _recalc_invoice(invoice_id, user["company_id"])
    return None

@router.post("/{invoice_id}/recalc")
async def recalc(invoice_id: int, user=Depends(get_current_user)):
    await _owned_invoice(invoice_id, user["company_id"])
    total = await _recalc_invoice(invoice_id, user["company_id"])
    return {"invoice_id": invoice_id, "total_cents": total}

# -------- From quote ----------
@router.post("/from_quote/{quote_id}", response_model=schemas.InvoiceOut)
async def create_from_quote(quote_id: int, user=Depends(get_current_user)):
    qtbl = models.Quote.__table__
    itbl = models.Invoice.__table__
    ltbl = models.InvoiceLine.__table__
    q = await database.fetch_one(
        select(qtbl).where(and_(qtbl.c.id == quote_id, qtbl.c.company_id == user["company_id"]))
    )
    if not q:
        raise HTTPException(status_code=404, detail="Quote not found")
    count = await database.fetch_val(
        select(func.count()).select_from(itbl).where(itbl.c.company_id == user["company_id"])
    )
    number = _make_number(int(count) + 1)
    iid = await database.execute(
        itbl.insert().values(
            number=number,
            title=str(q["title"]),
            status="draft",
            currency="EUR",
            total_cents=0,
            issued_date=None,
            due_date=None,
            client_id=int(q["client_id"]),
            company_id=user["company_id"],
        )
    )
    await database.execute(
        ltbl.insert().values(
            invoice_id=iid,
            description=f"Devis {q['number']}",
            qty=1,
            unit_price_cents=int(q["amount_cents"]),
            total_cents=int(q["amount_cents"]),
        )
    )
    await _recalc_invoice(iid, user["company_id"])
    row = await database.fetch_one(select(itbl).where(itbl.c.id == iid))
    return dict(row)

# -------- Status transitions ----------
@router.post("/{invoice_id}/status")
async def change_status(
    invoice_id: int, status: Literal["draft", "sent", "paid", "cancelled"], user=Depends(get_current_user)
):
    itbl = models.Invoice.__table__
    inv = await _owned_invoice(invoice_id, user["company_id"])
    allowed = {
        "draft": {"sent", "cancelled"},
        "sent": {"draft", "paid", "cancelled"},
        "paid": set(),
        "cancelled": set(),
    }
    cur = inv["status"]
    if status == cur:
        return {"invoice_id": invoice_id, "status": cur}
    if status not in allowed.get(cur, set()):
        raise HTTPException(status_code=400, detail=f"Cannot go {cur} -> {status}")
    values = {"status": status}
    if status == "sent" and not inv["issued_date"]:
        values["issued_date"] = date.today()
        if not inv["due_date"]:
            values["due_date"] = date.today() + timedelta(days=30)
    if status in ("draft", "sent"):
        total = await _recalc_invoice(invoice_id, user["company_id"])
        ptbl = models.Payment.__table__
        paid = await database.fetch_val(
            select(func.coalesce(func.sum(ptbl.c.amount_cents), 0)).where(ptbl.c.invoice_id == invoice_id)
        )
        if int(paid or 0) >= int(total or 0) and int(total or 0) > 0:
            values["status"] = "paid"
    await database.execute(itbl.update().where(itbl.c.id == invoice_id).values(**values))
    row = await database.fetch_one(select(itbl).where(itbl.c.id == invoice_id))
    return dict(row)

# -------- Summary ----------
@router.get("/{invoice_id}/summary")
async def invoice_summary(
    invoice_id: int, vat_percent: int = Query(20, ge=0, le=100), user=Depends(get_current_user)
):
    await _owned_invoice(invoice_id, user["company_id"])
    ltbl = models.InvoiceLine.__table__
    ptbl = models.Payment.__table__
    subtotal = await database.fetch_val(
        select(func.coalesce(func.sum(ltbl.c.total_cents), 0)).where(ltbl.c.invoice_id == invoice_id)
    ) or 0
    paid = await database.fetch_val(
        select(func.coalesce(func.sum(ptbl.c.amount_cents), 0)).where(ptbl.c.invoice_id == invoice_id)
    ) or 0
    vat = round(int(subtotal) * (vat_percent / 100.0))
    total = int(subtotal) + int(vat)
    due = max(0, total - int(paid))
    return {
        "invoice_id": invoice_id,
        "vat_percent": vat_percent,
        "subtotal_cents": int(subtotal),
        "vat_cents": int(vat),
        "total_cents": int(total),
        "paid_cents": int(paid),
        "due_cents": int(due),
    }

# -------- CSV exports ----------
@router.get("/export.csv")
async def export_invoices_csv(user=Depends(get_current_user)):
    itbl = models.Invoice.__table__
    rows = await database.fetch_all(
        select(itbl).where(itbl.c.company_id == user["company_id"]).order_by(itbl.c.id.desc())
    )
    buf = io.StringIO()
    w = csv.writer(buf)
    w.writerow(["id","number","title","status","client_id","issued_date","due_date","currency","total_cents"])
    for r in rows:
        w.writerow([r["id"], r["number"], r["title"], r["status"], r["client_id"], r["issued_date"], r["due_date"], r["currency"], r["total_cents"]])
    buf.seek(0)
    return StreamingResponse(iter([buf.getvalue()]), media_type="text/csv", headers={"Content-Disposition":"attachment; filename=invoices.csv"})

@router.get("/payments/export.csv")
async def export_payments_csv(invoice_id: int | None = None, user=Depends(get_current_user)):
    ptbl = models.Payment.__table__
    itbl = models.Invoice.__table__
    if invoice_id:
        await _owned_invoice(invoice_id, user["company_id"])
        rows = await database.fetch_all(select(ptbl).where(ptbl.c.invoice_id == invoice_id).order_by(ptbl.c.id.desc()))
    else:
        rows = await database.fetch_all(
            select(ptbl).select_from(ptbl.join(itbl, ptbl.c.invoice_id == itbl.c.id))
            .where(itbl.c.company_id == user["company_id"])
            .order_by(ptbl.c.id.desc())
        )
    buf = io.StringIO()
    w = csv.writer(buf)
    w.writerow(["id","invoice_id","amount_cents","method","paid_at","note"])
    for r in rows:
        w.writerow([r["id"], r["invoice_id"], r["amount_cents"], r["method"], r["paid_at"], r["note"]])
    buf.seek(0)
    return StreamingResponse(iter([buf.getvalue()]), media_type="text/csv", headers={"Content-Disposition":"attachment; filename=payments.csv"})

# -------- Signed links (PDF ONLY) ----------
@router.post("/{invoice_id}/signed_link")
async def create_signed_download_link(
    invoice_id: int,
    ttl: int = Query(300, ge=60, le=3600),
    user=Depends(get_current_user),
):
    await _owned_invoice(invoice_id, user["company_id"])
    token = create_signed_token(
        kind="invoice_pdf",
        data={"invoice_id": int(invoice_id), "company_id": int(user["company_id"])},
        ttl_seconds=int(ttl),
    )
    path = f"/invoices/public/{invoice_id}/download.pdf?token={token}"
    return {"path": path, "ttl": ttl, "kind": "pdf"}

@router.get("/public/{invoice_id}/download.pdf")
async def public_download_invoice_pdf(
    invoice_id: int,
    token: str,
    vat_percent: int = Query(20, ge=0, le=100),
):
    try:
        data = verify_signed_token(token, "invoice_pdf")
    except Exception:
        raise HTTPException(status_code=401, detail="Invalid or expired token")
    if int(data.get("invoice_id", -1)) != int(invoice_id):
        raise HTTPException(status_code=401, detail="Token/invoice mismatch")
    company_id = int(data.get("company_id", -1))
    html = await _render_invoice_html(invoice_id, company_id, vat_percent)
    base_dir = os.path.dirname(os.path.dirname(__file__))  # app/
    pdf_bytes = HTML(string=html, base_url=base_dir).write_pdf()
    itbl = models.Invoice.__table__
    inv = await database.fetch_one(
        select(itbl).where(and_(itbl.c.id == invoice_id, itbl.c.company_id == company_id))
    )
    fname = f"invoice_{inv['number']}.pdf" if inv and inv.get("number") else f"invoice_{invoice_id}.pdf"
    return StreamingResponse(io.BytesIO(pdf_bytes), media_type="application/pdf",
                             headers={"Content-Disposition": f'inline; filename="{fname}"'})
'@

Write-Utf8NoBom $invPy $invoicesPdfOnly
Write-Host "[OK] backend/app/routers/invoices.py rewritten (PDF only)"

# -------------------------------
# 2) FRONTEND: Invoices.jsx -> keep ONE PDF button
# -------------------------------
$invJs = Join-Path $root "frontend/src/Invoices.jsx"
if(!(Test-Path $invJs)){ throw "Missing: $invJs" }
Backup $invJs
$js = Get-Content $invJs -Raw

# remove any previous (HTML) or (PDF) buttons to avoid parser issues
$reBtnHtml = [regex]'(?is)<button\b[^>]*>[\s\S]*?\(HTML\)[\s\S]*?<\/button>'
$reBtnPdf  = [regex]'(?is)<button\b[^>]*>[\s\S]*?\(PDF\)[\s\S]*?<\/button>'
$js = $reBtnHtml.Replace($js, '', 0)
$js = $reBtnPdf.Replace($js, '', 0)

# also remove any lingering downloadHTML function
$reFn = [regex]'(?is)const\s+downloadHTML\s*=\s*async\s*\([^)]*\)\s*=>\s*\{[\s\S]*?\};'
$js = $reFn.Replace($js, '', 1)

# inject a single clean PDF button next to the action toolbar (flex gap:8)
$anchors = @(
  'style={{ marginLeft:"auto", display:"flex", gap:8 }}',
  'style={{ marginLeft:"auto", display:"flex", gap: 8 }}'
)
$anchorIdx = -1
foreach($a in $anchors){
  $i = $js.IndexOf($a)
  if($i -ge 0){ $anchorIdx = $i; break }
}
if($anchorIdx -lt 0){
  throw "Cannot find action toolbar anchor in Invoices.jsx"
}
$after = $js.IndexOf("</div>", $anchorIdx)
if($after -le $anchorIdx){
  throw "Cannot find action toolbar closing </div> in Invoices.jsx"
}

$btnPdf = @'
<button onClick={async () => {
  if (!sel || !sel.id) { alert("Selectionne une facture"); return; }
  const base = (import.meta.env.VITE_USE_PROXY==="1"?"/api":(import.meta.env.VITE_API_URL??"http://localhost:8000"));
  try {
    const token = localStorage.getItem("token") || "";
    const resp = await fetch(base + "/invoices/" + sel.id + "/signed_link", {
      method: "POST",
      headers: { "Authorization": "Bearer " + token }
    });
    if (!resp.ok) throw new Error("link failed " + resp.status);
    const data = await resp.json();
    const url = base + data.path;
    window.open(url, "_blank");
  } catch(e) { alert("Lien PDF impossible: " + e.message); }
}}>Telecharger (PDF)</button>
'@

$js = $js.Insert($after, "`n          " + $btnPdf + "`n")
Write-Utf8NoBom $invJs $js
Write-Host "[OK] frontend/src/Invoices.jsx updated (PDF button only)"

# -------------------------------
# 3) Rebuild & restart
# -------------------------------
Write-Host "`n[STEP] docker compose build --no-cache api"
docker compose build --no-cache api | Out-Host

Write-Host "`n[STEP] docker compose restart api"
docker compose restart api | Out-Host

Write-Host "`n[STEP] docker compose restart web"
docker compose restart web | Out-Host

Write-Host "`nDone. Front: http://localhost:3000  | API: http://localhost:8000/docs"
Write-Host "In UI: select an invoice -> Telecharger (PDF)"
