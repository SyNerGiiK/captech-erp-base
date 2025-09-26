from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select, and_, func
from app.db import database
from app import models, schemas
from app.deps import get_current_user

router = APIRouter(prefix="/payments", tags=["payments"])

async def _invoice_owned(invoice_id: int, company_id: int):
    itbl = models.Invoice.__table__
    row = await database.fetch_one(select(itbl.c.id, itbl.c.total_cents).where(and_(itbl.c.id==invoice_id, itbl.c.company_id==company_id)))
    if not row:
        raise HTTPException(status_code=404, detail="Invoice not found")
    return row

@router.post("/{invoice_id}", response_model=schemas.PaymentOut)
async def add_payment(invoice_id: int, payload: schemas.PaymentCreate, user=Depends(get_current_user)):
    inv = await _invoice_owned(invoice_id, user["company_id"])
    ptbl = models.Payment.__table__
    itbl = models.Invoice.__table__
    pid = await database.execute(ptbl.insert().values(
        invoice_id=invoice_id,
        amount_cents=int(payload.amount_cents),
        method=payload.method,
        paid_at=payload.paid_at,
        note=payload.note
    ))
    # recalcul statut payÃ© si somme >= total
    paid_sum = await database.fetch_val(select(func.coalesce(func.sum(ptbl.c.amount_cents),0)).where(ptbl.c.invoice_id==invoice_id))
    new_status = "paid" if int(paid_sum or 0) >= int(inv["total_cents"] or 0) and int(inv["total_cents"] or 0) > 0 else None
    if new_status:
        await database.execute(itbl.update().where(itbl.c.id==invoice_id).values(status=new_status))
    row = await database.fetch_one(select(ptbl).where(ptbl.c.id==pid))
    return dict(row)

@router.get("/{invoice_id}", response_model=list[schemas.PaymentOut])
async def list_payments(invoice_id: int, user=Depends(get_current_user)):
    await _invoice_owned(invoice_id, user["company_id"])
    ptbl = models.Payment.__table__
    rows = await database.fetch_all(select(ptbl).where(ptbl.c.invoice_id==invoice_id).order_by(ptbl.c.id.asc()))
    return [dict(r) for r in rows]