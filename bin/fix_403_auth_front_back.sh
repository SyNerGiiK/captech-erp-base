# bin/fix_403_auth_front_back.sh  (WSL/Ubuntu, à créer à la racine du repo)
#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"

# ---------- Backend patch: 401 clair si pas de token ----------
AUTH="$root/backend/app/auth_utils.py"
[[ -f "$AUTH" ]] || { echo "[ERR] introuvable: $AUTH"; exit 1; }
cp -a "$AUTH" "${AUTH}.bak_$(date +%Y%m%d_%H%M%S)"

# imports idempotents
grep -q "from fastapi.security import HTTPBearer" "$AUTH" || sed -i '1i from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials' "$AUTH"
grep -q "from fastapi import Depends" "$AUTH" || sed -i '1i from fastapi import Depends, HTTPException, status' "$AUTH"

# _auth_scheme = HTTPBearer(auto_error=False)
if grep -q "_auth_scheme = HTTPBearer" "$AUTH"; then
  sed -i 's/_auth_scheme = HTTPBearer(.*)/_auth_scheme = HTTPBearer(auto_error=false)/I' "$AUTH" || true
  # En cas de regex capricieuse, enforce proprement:
  perl -0777 -pe 's/_auth_scheme\s*=\s*HTTPBearer\s*\(\s*auto_error\s*=\s*True\s*\)/_auth_scheme = HTTPBearer(auto_error=False)/igs' -i "$AUTH"
  perl -0777 -pe 's/_auth_scheme\s*=\s*HTTPBearer\s*\(\s*\)/_auth_scheme = HTTPBearer(auto_error=False)/igs' -i "$AUTH"
else
  # insérer juste avant get_current_user si besoin
  if ! grep -q "_auth_scheme = HTTPBearer(auto_error=False)" "$AUTH"; then
    awk '
      BEGIN{printed=0}
      /def get_current_user/ && !printed {
        print "_auth_scheme = HTTPBearer(auto_error=False)\n";
        printed=1
      }
      {print}
    ' "$AUTH" > "$AUTH.tmp" && mv "$AUTH.tmp" "$AUTH"
  fi
fi

# dans get_current_user: si pas de credentials => 401
perl -0777 -pe 's/def\s+get_current_user\s*\(.*\):\s*?\n\s*token\s*=\s*credentials\.credentials.*?\n/def get_current_user(credentials: HTTPAuthorizationCredentials = Depends(_auth_scheme)) -> dict:\n    if not credentials or not credentials.credentials:\n        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Not authenticated")\n    token = credentials.credentials\n/ims' -i "$AUTH"

# ---------- Front patch: token robuste + garde anti-fetch ----------
FX="$root/frontend/src/Invoices.jsx"
[[ -f "$FX" ]] || { echo "[ERR] introuvable: $FX"; exit 1; }
cp -a "$FX" "${FX}.bak_$(date +%Y%m%d_%H%M%S)"

# Remplace bloc token + refresh par une version robuste
perl -0777 -pe '
  s/const session = \(\(\) => \{\s*try \{ return JSON\.parse\(localStorage\.getItem\("session"\) \|\| "null"\);\s*\}\s*catch \{ return null; \}\s*\}\)\(\);\s*const token = session\?\.token \?\? "";/const session = (()=>{
  try { return JSON.parse(localStorage.getItem("session") || "null"); } catch { return null; }
})();
const auth = (()=>{
  try { return JSON.parse(localStorage.getItem("auth") || "null"); } catch { return null; }
})();
const token = (session?.token) || (auth?.token) || (localStorage.getItem("token") || "");
/s' -i "$FX"

# Injecte une garde au début de refresh()
perl -0777 -pe '
  s/async function refresh\(\) \{\s*setLoading\(true\);/async function refresh() {\n    if (!token) { setItems([]); alert("Connecte-toi dans l\\u2019onglet Auth, puis reviens ici."); return; }\n    setLoading(true);/s
' -i "$FX"

# Vérifie que l’endpoint /invoices/list est bien utilisé
sed -i -E 's#/invoices/\?limit=50&offset=0#/invoices/list?limit=50\&offset=0#g' "$FX"

# ---------- Restart ----------
echo "[STEP] docker compose restart api web"
docker compose restart api web

echo "✅ OK. Front: http://localhost:3000 (Factures → Rafraîchir). API: http://localhost:8000/docs"

# ---------- (facultatif) test CLI ----------
echo
echo "Test CLI (facultatif) :"
echo "  1) Obtiens un token : curl -s -X POST http://localhost:8000/auth/login -H 'Content-Type: application/json' -d '{\"email\":\"contact@captech-entretien-renovation.fr\",\"password\":\"Charlotte@2509\"}'"
echo "  2) Puis: TOKEN=... ; curl -i http://localhost:8000/invoices/list?limit=5 -H \"Authorization: Bearer \$TOKEN\""
