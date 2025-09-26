from fastapi import APIRouter, HTTPException, Depends
from app import schemas
from app.db import database
from app import models
from app.auth_utils import get_password_hash, verify_password, create_access_token
from app.deps import get_current_user

router = APIRouter(prefix="/auth", tags=["auth"])

@router.post("/register", response_model=schemas.Token)
async def register(payload: schemas.UserCreate):
    company_tbl = models.Company.__table__
    user_tbl = models.User.__table__

    company_row = await database.fetch_one(
        company_tbl.select().where(company_tbl.c.name == payload.company_name)
    )
    if company_row:
        company_id = company_row["id"]
    else:
        company_id = await database.execute(
            company_tbl.insert().values(name=payload.company_name)
        )

    existing = await database.fetch_one(
        user_tbl.select().where(user_tbl.c.email == payload.email)
    )
    if existing:
        raise HTTPException(status_code=400, detail="Email already registered")

    hashed = get_password_hash(payload.password)
    await database.execute(
        user_tbl.insert().values(email=payload.email, hashed_password=hashed, company_id=company_id)
    )
    token = create_access_token(sub=payload.email, company_id=company_id)
    return {"access_token": token}

@router.post("/login", response_model=schemas.Token)
async def login(payload: schemas.UserLogin):
    user_tbl = models.User.__table__
    row = await database.fetch_one(
        user_tbl.select().where(user_tbl.c.email == payload.email)
    )
    if not row or not verify_password(payload.password, row["hashed_password"]):
        raise HTTPException(status_code=400, detail="Invalid credentials")
    token = create_access_token(sub=row["email"], company_id=row["company_id"])
    return {"access_token": token}

@router.get("/me", response_model=schemas.MeOut)
async def me(user=Depends(get_current_user)):
    return {"email": user["email"], "company_id": user["company_id"]}