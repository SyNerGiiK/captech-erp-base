from __future__ import annotations

import os
from datetime import datetime, timedelta
from typing import Optional, Dict, Any

from passlib.context import CryptContext
from jose import jwt, JWTError

# --- Password hashing ---
_pwd = CryptContext(schemes=["bcrypt"], deprecated="auto")

def get_password_hash(password: str) -> str:
    return _pwd.hash(password)

def verify_password(plain: str, hashed: str) -> bool:
    try:
        return _pwd.verify(plain, hashed)
    except Exception:
        return False

# --- JWT ---
SECRET = os.getenv("JWT_SECRET") or os.getenv("SECRET_KEY") or "dev_secret_change_me"
ALGO = "HS256"

def create_access_token(sub: str, company_id: int, ttl_seconds: int = 60*60*24) -> str:
    now = datetime.utcnow()
    exp = int((datetime.utcnow() + timedelta(seconds=ttl_seconds)).timestamp())
    payload = {"sub": sub, "company_id": int(company_id), "exp": exp}
    return jwt.encode(payload, SECRET, algorithm=ALGO)

def create_signed_token(kind: str, data: Dict[str, Any], ttl_seconds: int = 900) -> str:
    now = datetime.utcnow()
    exp = int((datetime.utcnow() + timedelta(seconds=ttl_seconds)).timestamp())
    payload = {"kind": kind, "exp": exp, **data}
    return jwt.encode(payload, SECRET, algorithm=ALGO)

def verify_signed_token(token: str, expected_kind: Optional[str] = None) -> Dict[str, Any]:
    try:
        payload = jwt.decode(token, SECRET, algorithms=[ALGO])
    except JWTError as e:
        raise ValueError(f"invalid token: {e}")
    if expected_kind is not None:
        k = payload.get('kind')
        if k is not None and k != expected_kind:
            raise ValueError('invalid kind')
    return payload

# --- Dépendance d'auth minimale pour les routes factures ---
from fastapi import Depends, HTTPException  # noqa: E402
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials  # noqa: E402
from sqlalchemy import select  # noqa: E402
from app.db import database  # noqa: E402
from app import models  # noqa: E402

_auth_scheme = HTTPBearer(auto_error=False)

def _rec_get(rec, key, default=None):
    """Accès sûr aux colonnes d'un Record/dataclass/dict."""
    try:
        if hasattr(rec, "_mapping"):
            return dict(rec._mapping).get(key, default)
        return rec[key]
    except Exception:
        return default

async def get_current_user(
    credentials: Optional[HTTPAuthorizationCredentials] = Depends(_auth_scheme),
):
    """
    Fallback DEV : on prend le premier utilisateur.
    (Pas de connect() ici pour éviter les soucis d'event loop en tests ;
    on suppose que soit l'app a connecté au startup, soit le test a fait connect().)
    """
    utbl = models.User.__table__
    try:
        row = await database.fetch_one(select(utbl).limit(1))
    except Exception:
        # DB pas connectée -> 503 (les tests connectent explicitement avant d'appeler les endpoints)
        raise HTTPException(status_code=503, detail="Database not connected")
    if not row:
        raise HTTPException(status_code=401, detail="Not authenticated")

    return {
        "id": int(_rec_get(row, "id", 0)),
        "email": _rec_get(row, "email"),
        "company_id": int(_rec_get(row, "company_id", 0)),
    }
