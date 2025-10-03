#!/usr/bin/env bash
set -euo pipefail

ts(){ date +"[%F %T]"; }

# 1) Refactor main.py -> lifespan (supprime les warnings FastAPI on_event)
echo "$(ts) Patch backend/app/main.py -> lifespan"
python3 - <<'PY'
from pathlib import Path
p = Path("backend/app/main.py")
src = p.read_text(encoding="utf-8")

# Construit une version avec lifespan si pas déjà présent
if "lifespan=" not in src:
    # on garde en mémoire les include_router existants
    # et on remplace les blocs on_event par un lifespan unique
    import re

    # Récupère le titre passé à FastAPI pour le réinjecter
    m_title = re.search(r'app\s*=\s*FastAPI\s*\((.*?)\)', src, re.S)
    params = m_title.group(1) if m_title else 'title="CapTech ERP"'

    # supprime les décorateurs on_event et fonctions associées
    src = re.sub(r'@app\.on_event\("startup"\)[\s\S]*?^\s*async def shutdown\(\):[\s\S]*?^\s*await database\.disconnect\(\)\s*$', '', src, flags=re.M)

    # assure les imports
    if "from contextlib import asynccontextmanager" not in src:
        src = "from contextlib import asynccontextmanager\n" + src

    # injecte lifespan, puis re-déclare app = FastAPI(..., lifespan=lifespan)
    lifespan_block = '''
@asynccontextmanager
async def lifespan(app: FastAPI):
    # Démarrage
    models.Base.metadata.create_all(bind=engine)
    await database.connect()
    if HAS_MV:
        try:
            await ensure_matviews()
        except Exception:
            pass
    yield
    # Arrêt
    await database.disconnect()
'''.lstrip('\n')

    # remplace la création de l'app
    src = re.sub(r'app\s*=\s*FastAPI\s*\((.*?)\)', f'app = FastAPI({params}, lifespan=lifespan)', src, count=1, flags=re.S)

    # insère le block lifespan juste après les imports app/models/db (en gros après le bloc import du fichier)
    # simple heuristique : après la dernière ligne d'import
    lines = src.splitlines(True)
    last_import_idx = 0
    for i, line in enumerate(lines):
        if line.startswith("from ") or line.startswith("import "):
            last_import_idx = i
    lines.insert(last_import_idx+1, lifespan_block)
    src = "".join(lines)

    p.write_text(src, encoding="utf-8")
    print("OK (lifespan ajouté)")
else:
    print("Déjà en lifespan, skip.")
PY

# 2) Ajoute un pytest.ini pour filtrer warnings Pydantic v2 et passlib
echo "$(ts) Écrit backend/pytest.ini (filters warnings)"
mkdir -p backend
cat > backend/pytest.ini <<'INI'
[pytest]
filterwarnings =
    ignore:PydanticDeprecatedSince20:DeprecationWarning
    ignore:'crypt' is deprecated:DeprecationWarning:passlib.utils
INI

# 3) Restart API + lancer les tests
echo "$(ts) Restart API"
docker compose restart api >/dev/null

echo "$(ts) Lance tests"
docker compose exec -T api pytest -q \
  /app/tests/test_routes_invoices.py \
  /app/tests/test_public_url.py \
  /app/tests/test_invoice_public_pdf.py
