import os, time
from typing import Any, Dict
from jose import jwt, JWTError

SECRET_KEY = os.getenv("SECRET_KEY", "dev_change_me")
ALGO = "HS256"

def _now() -> int:
    return int(time.time())

def create_signed_token(kind: str, data: Dict[str, Any], ttl_seconds: int = 300) -> str:
    payload = dict(data)
    payload["k"] = kind
    payload["exp"] = _now() + int(ttl_seconds)
    return jwt.encode(payload, SECRET_KEY, algorithm=ALGO)

def verify_signed_token(token: str, expected_kind: str) -> Dict[str, Any]:
    try:
        data = jwt.decode(token, SECRET_KEY, algorithms=[ALGO])
        if data.get("k") != expected_kind:
            raise ValueError("wrong kind")
        return data
    except JWTError as e:
        raise ValueError(str(e))