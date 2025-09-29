# bin/fix_bool_case_auth_utils.sh
#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
f="$root/backend/app/auth_utils.py"

[[ -f "$f" ]] || { echo "[ERR] Introuvable: $f"; exit 1; }

cp -a "$f" "${f}.bak_$(date +%Y%m%d_%H%M%S)"

# 1) Corriger booléens en Python
#   - 'false' -> 'False' ; 'true' -> 'True' (mots isolés)
perl -0777 -pe 's/\bfalse\b/False/gi; s/\btrue\b/True/gi;' -i "$f"

# 2) Forcer la ligne _auth_scheme correcte
#    Remplace toute variante par la bonne valeur
perl -0777 -pe 's/_auth_scheme\s*=\s*HTTPBearer\s*\([^)]*\)/_auth_scheme = HTTPBearer(auto_error=False)/igs' -i "$f"

# 3) S’assurer des imports requis
grep -q 'from fastapi.security import HTTPBearer' "$f" \
  || sed -i '1i from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials' "$f"

grep -q 'from fastapi import Depends' "$f" \
  || sed -i '1i from fastapi import Depends, HTTPException, status' "$f"

# 4) Redémarrer l’API
echo "[STEP] docker compose restart api"
docker compose restart api

# 5) Pings utiles
echo "[STEP] Healthcheck:"
sleep 1
curl -s http://localhost:8000/healthz || true
echo
echo "✅ Patch appliqué. Ouvre: http://localhost:8000/docs"
echo "Ensuite recharge le front et re-tente Factures."
