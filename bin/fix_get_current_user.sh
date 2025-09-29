# bin/fix_get_current_user.sh  (à créer dans WSL, à la racine du repo)
#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
file="$root/backend/app/auth_utils.py"

[[ -f "$file" ]] || { echo "[ERR] introuvable: $file"; exit 1; }

cp -a "$file" "${file}.bak_$(date +%Y%m%d_%H%M%S)"

# Imports idempotents
grep -q "from fastapi import Depends" "$file" || sed -i '1i from fastapi import Depends, HTTPException, status' "$file"
grep -q "from fastapi.security import HTTPBearer" "$file" || sed -i '1i from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials' "$file"
grep -q "from jose import jwt" "$file" || sed -i '1i from jose import jwt, JWTError' "$file"
grep -q "from sqlalchemy import select" "$file" || sed -i '1i from sqlalchemy import select' "$file"
grep -q "from app.db import database" "$file" || sed -i '1i from app.db import database' "$file"
grep -q "from app import models" "$file" || sed -i '1i from app import models' "$file"
grep -q "^import os$" "$file" || sed -i '1i import os' "$file"

# Ajouter la dépendance FastAPI si absente
if ! grep -q "def get_current_user" "$file"; then
  cat >> "$file" <<'PYEOF'

# Pourquoi: dépendance d'auth centralisée pour protéger les routes
_auth_scheme = HTTPBearer(auto_error=True)

async def get_current_user(credentials: HTTPAuthorizationCredentials = Depends(_auth_scheme)) -> dict:
    token = credentials.credentials if credentials else None
    if not token:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Not authenticated")
    secret = os.getenv("SECRET_KEY", "dev-insecure")
    try:
        payload = jwt.decode(token, secret, algorithms=["HS256"])
    except JWTError:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token")

    sub = payload.get("sub")
    company_id = payload.get("company_id")
    if sub is None or company_id is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token payload")

    utbl = models.User.__table__
    cond = (utbl.c.id == int(sub)) if str(sub).isdigit() else (utbl.c.email == str(sub))
    user = await database.fetch_one(select(utbl).where(cond))
    if not user or int(user["company_id"]) != int(company_id):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="User mismatch")

    return {"id": int(user["id"]), "email": user["email"], "company_id": int(user["company_id"])}
PYEOF
  echo "[OK] get_current_user ajouté dans app/auth_utils.py"
else
  echo "[SKIP] get_current_user existe déjà"
fi

echo "[STEP] docker compose restart api"
docker compose restart api

echo "✅ Fini. Teste: http://localhost:8000/docs et ton onglet Factures."
