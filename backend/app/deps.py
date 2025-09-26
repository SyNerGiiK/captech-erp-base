import os
from fastapi import Depends, HTTPException
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from jose import jwt, JWTError

SECRET_KEY = os.getenv("SECRET_KEY", "dev_change_me")
ALGO = "HS256"
_bearer = HTTPBearer()

async def get_current_user(creds: HTTPAuthorizationCredentials = Depends(_bearer)):
    token = creds.credentials
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGO])
        email = payload.get("sub")
        company_id = payload.get("company_id")
        if not email or company_id is None:
            raise HTTPException(status_code=401, detail="Invalid token payload")
        return {"email": email, "company_id": int(company_id)}
    except JWTError:
        raise HTTPException(status_code=401, detail="Invalid token")