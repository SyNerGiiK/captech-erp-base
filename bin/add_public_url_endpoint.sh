# file: bin/add_public_url_endpoint.sh
# usage (WSL/Ubuntu, depuis la racine du repo):
#   chmod +x bin/add_public_url_endpoint.sh
#   bin/add_public_url_endpoint.sh
set -euo pipefail

FILE="backend/app/routers/invoices.py"
[ -f "$FILE" ] || { echo "Introuvable: $FILE"; exit 1; }

# Sauvegarde
cp -a "$FILE" "${FILE}.bak_$(date +%Y%m%d_%H%M%S)"

python3 - <<'PY'
import re,sys,os,io

path = "backend/app/routers/invoices.py"
with io.open(path, "r", encoding="utf-8") as f:
    src = f.read()

# 1) Ensure Request import
if "from fastapi import Request" not in src:
    # ajoute Request dans une ligne d'import fastapi existante ou en crée une nouvelle
    m = re.search(r'from fastapi import ([^\n]+)\n', src)
    if m and "Request" not in m.group(1):
        # injecte Request dans la liste
        before = m.group(0)
        items = [s.strip() for s in m.group(1).split(",")]
        items.append("Request")
        new = "from fastapi import " + ", ".join(sorted(set(items))) + "\n"
        src = src.replace(before, new, 1)
    elif not m:
        # pas de ligne from fastapi import ... → on ajoute une ligne d'import
        src = 'from fastapi import Request\n' + src

# 2) Ajoute l'endpoint si manquant
if "/by-id/{invoice_id}/public_url" not in src:
    block = r'''
@router.get("/by-id/{invoice_id}/public_url")
async def public_invoice_url(
    invoice_id: int,
    request: Request,
    current_user: dict = Depends(get_current_user),
):
    """
    Génère une URL publique (signée) pour télécharger le PDF de la facture.
    TTL court (10 min). Vérifie l'appartenance de la facture à la société.
    """
    import os
    from sqlalchemy import and_, select
    # tables & DB
    itbl = models.Invoice.__table__
    inv = await database.fetch_one(
        select(itbl.c.id, itbl.c.number).where(
            and_(itbl.c.id == invoice_id, itbl.c.company_id == current_user["company_id"])
        )
    )
    if not inv:
        raise HTTPException(status_code=404, detail="Invoice not found")

    token = create_signed_token(
        kind="invoice_pdf",
        data={"invoice_id": int(invoice_id), "company_id": int(current_user["company_id"])},
        ttl_seconds=600,
    )
    base = os.getenv("PUBLIC_BASE_URL") or str(request.base_url).rstrip("/")
    url = f"{base}/public/{invoice_id}/download.pdf?token={token}"
    return {"url": url}
'''
    # insère à la fin du fichier
    if not src.endswith("\n"):
        src += "\n"
    src += "\n" + block.lstrip("\n")

with io.open(path, "w", encoding="utf-8", newline="\n") as f:
    f.write(src)
print("[OK] invoices.py patché")
PY

echo "[STEP] docker compose build api"
docker compose build api

echo "[STEP] docker compose up -d"
docker compose up -d

echo
echo "✅ Fini. Teste dans l'UI (Factures -> Télécharger PDF),"
echo "ou via curl (remplace 25 par un ID existant) :"
echo '  curl -s "http://localhost:8000/invoices/by-id/25/public_url" -H "Authorization: Bearer <TOKEN>" | jq'
