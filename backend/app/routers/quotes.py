from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import select, and_, func
from datetime import datetime
from app.db import database
from app import models, schemas
from app.deps import get_current_user

router = APIRouter(prefix="/quotes", tags=["quotes"])


async def _ensure_client_in_company(client_id: int, company_id: int):
    ctbl = models.Client.__table__
    row = await database.fetch_one(
        select(ctbl.c.id).where(
            and_(ctbl.c.id == client_id, ctbl.c.company_id == company_id)
        )
    )
    if not row:
        raise HTTPException(status_code=400, detail="Client not in your company")


def _make_number(seq: int) -> str:
    y = datetime.utcnow().year
    return f"Q-{y}-{seq:04d}"


@router.post("/", response_model=schemas.QuoteOut)
async def create_quote(payload: schemas.QuoteCreate, user=Depends(get_current_user)):
    await _ensure_client_in_company(payload.client_id, user["company_id"])
    qtbl = models.Quote.__table__
    # why: numéro lisible et incrémental par company
    count = await database.fetch_val(
        select(func.count())
        .select_from(qtbl)
        .where(qtbl.c.company_id == user["company_id"])
    )
    number = _make_number(int(count) + 1)
    qid = await database.execute(
        qtbl.insert().values(
            number=number,
            title=payload.title,
            amount_cents=payload.amount_cents,
            status=payload.status or "draft",
            client_id=payload.client_id,
            company_id=user["company_id"],
        )
    )
    row = await database.fetch_one(select(qtbl).where(qtbl.c.id == qid))
    return dict(row)


@router.get("/", response_model=list[schemas.QuoteOut])
async def list_quotes(
    status: str | None = None,
    limit: int = 50,
    offset: int = 0,
    user=Depends(get_current_user),
):
    qtbl = models.Quote.__table__
    stmt = (
        select(qtbl)
        .where(qtbl.c.company_id == user["company_id"])
        .order_by(qtbl.c.id.desc())
        .limit(limit)
        .offset(offset)
    )
    if status:
        stmt = (
            select(qtbl)
            .where(
                and_(qtbl.c.company_id == user["company_id"], qtbl.c.status == status)
            )
            .order_by(qtbl.c.id.desc())
            .limit(limit)
            .offset(offset)
        )
    rows = await database.fetch_all(stmt)
    return [dict(r) for r in rows]


@router.get("/{quote_id}", response_model=schemas.QuoteOut)
async def get_quote(quote_id: int, user=Depends(get_current_user)):
    qtbl = models.Quote.__table__
    row = await database.fetch_one(
        select(qtbl).where(
            and_(qtbl.c.id == quote_id, qtbl.c.company_id == user["company_id"])
        )
    )
    if not row:
        raise HTTPException(status_code=404, detail="Quote not found")
    return dict(row)


@router.patch("/{quote_id}", response_model=schemas.QuoteOut)
async def update_quote(
    quote_id: int, payload: schemas.QuoteUpdate, user=Depends(get_current_user)
):
    qtbl = models.Quote.__table__
    existing = await database.fetch_one(
        select(qtbl).where(
            and_(qtbl.c.id == quote_id, qtbl.c.company_id == user["company_id"])
        )
    )
    if not existing:
        raise HTTPException(status_code=404, detail="Quote not found")
    data = existing._mapping.copy()
    update = payload.model_dump(exclude_unset=True)
    if "client_id" in update and update["client_id"] is not None:
        await _ensure_client_in_company(int(update["client_id"]), user["company_id"])
    data.update(update)
    await database.execute(
        qtbl.update()
        .where(qtbl.c.id == quote_id)
        .values(
            title=data["title"],
            amount_cents=data["amount_cents"],
            status=data["status"],
            client_id=data["client_id"],
        )
    )
    row = await database.fetch_one(select(qtbl).where(qtbl.c.id == quote_id))
    return dict(row)


@router.delete("/{quote_id}", status_code=204)
async def delete_quote(quote_id: int, user=Depends(get_current_user)):
    qtbl = models.Quote.__table__
    owned = await database.fetch_one(
        select(qtbl.c.id).where(
            and_(qtbl.c.id == quote_id, qtbl.c.company_id == user["company_id"])
        )
    )
    if not owned:
        raise HTTPException(status_code=404, detail="Quote not found")
    await database.execute(qtbl.delete().where(qtbl.c.id == quote_id))
    return None
