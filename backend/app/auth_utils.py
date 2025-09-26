import os
from datetime import datetime, timedelta
from jose import jwt
from passlib.context import CryptContext

SECRET_KEY = os.getenv("SECRET_KEY", "dev_change_me")
ALGO = "HS256"
ACCESS_TOKEN_EXPIRE_MINUTES = 60 * 24 * 7

# why: bcrypt_sha256 Ã©vite la limite 72 octets; fallback bcrypt pour compat
_pwd = CryptContext(schemes=["bcrypt_sha256", "bcrypt"], deprecated="auto")

def get_password_hash(password: str) -> str:
    return _pwd.hash(password)

def verify_password(plain: str, hashed: str) -> bool:
    try:
        return _pwd.verify(plain, hashed)
    except ValueError:
        # why: Ã©viter un 500 si mot de passe >72 octets
        return False

def create_access_token(sub: str, company_id: int) -> str:
    exp = datetime.utcnow() + timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES)
    payload = {"sub": sub, "company_id": company_id, "exp": exp}
    return jwt.encode(payload, SECRET_KEY, algorithm=ALGO)