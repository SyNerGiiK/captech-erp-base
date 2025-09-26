from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import select, and_
from app.db import database
from app import models, schemas
from app.deps import get_current_user

router = APIRouter(prefix="/clients", tags=["clients"])

@router.post("/", response_model=schemas.ClientOut)
async def create_client(payload: schemas.ClientCreate, user=Depends(get_current_user)):
    tbl = models.Client.__table__
    # why: éviter doublon (company_id, name)
    exists = await database.fetch_one(
        select(tbl.c.id).where(and_(tbl.c.company_id == user["company_id"], tbl.c.name == payload.name))
    )
    if exists:
        raise HTTPException(status_code=400, detail="Client name already exists in your company")
    cid = await database.execute(
        tbl.insert().values(
            name=payload.name, email=payload.email, phone=payload.phone, company_id=user["company_id"]
        )
    )
    row = await database.fetch_one(select(tbl).where(tbl.c.id == cid))
    return dict(row)

@router.get("/", response_model=list[schemas.ClientOut])
async def list_clients(
    q: str | None = Query(default=None, description="Filter by name contains"),
    limit: int = 50,
    offset: int = 0,
    user=Depends(get_current_user),
):
    tbl = models.Client.__table__
    stmt = select(tbl).where(tbl.c.company_id == user["company_id"]).order_by(tbl.c.name).limit(limit).offset(offset)
    if q:
        stmt = select(tbl).where(
            and_(tbl.c.company_id == user["company_id"], tbl.c.name.ilike(f"%{q}%"))
        ).order_by(tbl.c.name).limit(limit).offset(offset)
    rows = await database.fetch_all(stmt)
    return [dict(r) for r in rows]

@router.get("/{client_id}", response_model=schemas.ClientOut)
async def get_client(client_id: int, user=Depends(get_current_user)):
    tbl = models.Client.__table__
    row = await database.fetch_one(
        select(tbl).where(and_(tbl.c.id == client_id, tbl.c.company_id == user["company_id"]))
    )
    if not row:
        raise HTTPException(status_code=404, detail="Client not found")
    return dict(row)

@router.patch("/{client_id}", response_model=schemas.ClientOut)
async def update_client(client_id: int, payload: schemas.ClientUpdate, user=Depends(get_current_user)):
    tbl = models.Client.__table__
    existing = await database.fetch_one(
        select(tbl).where(and_(tbl.c.id == client_id, tbl.c.company_id == user["company_id"]))
    )
    if not existing:
        raise HTTPException(status_code=404, detail="Client not found")
    data = existing._mapping.copy()
    for k, v in payload.model_dump(exclude_unset=True).items():
        data[k] = v
    await database.execute(
        tbl.update().where(tbl.c.id == client_id).values(
            name=data["name"], email=data["email"], phone=data["phone"]
        )
    )
    row = await database.fetch_one(select(tbl).where(tbl.c.id == client_id))
    return dict(row)

@router.delete("/{client_id}", status_code=204)
async def delete_client(client_id: int, user=Depends(get_current_user)):
    ctbl = models.Client.__table__
    qtbl = models.Quote.__table__
    owned = await database.fetch_one(
        select(ctbl.c.id).where(and_(ctbl.c.id == client_id, ctbl.c.company_id == user["company_id"]))
    )
    if not owned:
        raise HTTPException(status_code=404, detail="Client not found")
    # why: intégrité fonctionnelle simple
    await database.execute(qtbl.delete().where(qtbl.c.client_id == client_id))
    await database.execute(ctbl.delete().where(ctbl.c.id == client_id))
    return None