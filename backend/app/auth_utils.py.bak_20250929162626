import os
from app import models
from app.db import database
from sqlalchemy import select
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from fastapi import Depends, HTTPException, status
import os
from datetime import datetime, timedelta
from jose import jwt
from passlib.context import CryptContext
import base64
import hashlib
import hmac
import json
import time
from typing import Any, Dict

SECRET_KEY = os.getenv("SECRET_KEY", "dev_change_me")
ALGO = "HS256"
ACCESS_TOKEN_EXPIRE_MINUTES = 60 * 24 * 7

# why: bcrypt_sha256 ÃƒÂ©vite la limite 72 octets; fallback bcrypt pour compat
_pwd = CryptContext(schemes=["bcrypt_sha256", "bcrypt"], deprecated="auto")


def get_password_hash(password: str) -> str:
    return _pwd.hash(password)


def verify_password(plain: str, hashed: str) -> bool:
    try:
        return _pwd.verify(plain, hashed)
    except ValueError:
        # why: ÃƒÂ©viter un 500 si mot de passe >72 octets
        return False


def create_access_token(sub: str, company_id: int) -> str:
    exp = datetime.utcnow() + timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES)
    payload = {"sub": sub, "company_id": company_id, "exp": exp}
    return jwt.encode(payload, SECRET_KEY, algorithm=ALGO)


# Pourquoi: dÃ©pendance d'auth centralisÃ©e pour protÃ©ger les routes
_auth_scheme = HTTPBearer(auto_error=False)


async def get_current_user(
    credentials: HTTPAuthorizationCredentials = Depends(_auth_scheme),
) -> dict:
    token = credentials.credentials if credentials else None
    if not token:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="Not authenticated"
        )
    secret = os.getenv("SECRET_KEY", "dev-insecure")
    try:
        payload = jwt.decode(token, secret, algorithms=["HS256"])
    except JWTError:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token"
        )

    sub = payload.get("sub")
    company_id = payload.get("company_id")
    if sub is None or company_id is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token payload"
        )

    utbl = models.User.__table__
    cond = (utbl.c.id == int(sub)) if str(sub).isdigit() else (utbl.c.email == str(sub))
    user = await database.fetch_one(select(utbl).where(cond))
    if not user or int(user["company_id"]) != int(company_id):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="User mismatch"
        )

    return {
        "id": int(user["id"]),
        "email": user["email"],
        "company_id": int(user["company_id"]),
    }


# --- Signed token (HMAC-SHA256) helpers: no external deps ---
# Pourquoi: lien public PDF court-vivant sans JWT, simple & suffisant.
def _b64u_encode(b: bytes) -> str:
    import base64

    return base64.urlsafe_b64encode(b).decode("utf-8").rstrip("=")


def _b64u_decode(s: str) -> bytes:
    import base64

    pad = "=" * (-len(s) % 4)
    return base64.urlsafe_b64decode(s + pad)


# --- tokens signés pour liens publics de facture ---
import os
from typing import Optional, Dict, Any
from datetime import datetime, timedelta, timezone

# On tente PyJWT d'abord, puis python-jose en fallback
try:
    import jwt  # PyJWT

    _JWT_LIB = "pyjwt"
except ImportError:  # pragma: no cover
    from jose import jwt  # type: ignore

    _JWT_LIB = "jose"

JWT_SECRET = os.getenv("SECRET_KEY", "change-me")
JWT_ALGO = os.getenv("JWT_ALGO", "HS256")


def create_signed_token(kind: str, data: Dict[str, Any], ttl_seconds: int = 900) -> str:
    """
    Crée un JWT court-living pour un usage précis (ex: 'invoice_pdf').
    Le claim 'scope' doit matcher 'kind' lors de la vérification.
    """
    now = datetime.now(tz=timezone.utc)
    payload = {
        "scope": kind,
        "iat": int(now.timestamp()),
        "exp": int((now + timedelta(seconds=ttl_seconds)).timestamp()),
        **data,
    }
    return jwt.encode(payload, JWT_SECRET, algorithm=JWT_ALGO)


def verify_signed_token(kind: str, token: str) -> Optional[Dict[str, Any]]:
    """
    Vérifie le JWT signé et que scope == kind.
    Retourne le payload (dict) si ok, sinon None.
    """
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGO])
        if payload.get("scope") != kind:
            return None
        return payload
    except Exception:
        return None
