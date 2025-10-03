#!/usr/bin/env bash
set -euo pipefail

echo "[INFO] Upgrade Pydantic v2 + refactor Config -> ConfigDict"

# --- Localisation projet
ROOT="$(pwd)"
REQ=""
if [[ -f "$ROOT/backend/requirements.txt" ]]; then
  REQ="$ROOT/backend/requirements.txt"
elif [[ -f "$ROOT/requirements.txt" ]]; then
  REQ="$ROOT/requirements.txt"
else
  echo "[WARN] requirements.txt introuvable (backend/requirements.txt ou requirements.txt). Skip upgrade lib."
fi

# --- 1) Met à jour la contrainte Pydantic
if [[ -n "$REQ" ]]; then
  cp "$REQ" "$REQ.bak_$(date +%Y%m%d_%H%M%S)"
  # supprime lignes pydantic existantes
  grep -v -i '^pydantic' "$REQ" > "$REQ.tmp" || true
  mv "$REQ.tmp" "$REQ"
  # ajoute contrainte v2.11
  echo 'pydantic>=2.11,<3.0' >> "$REQ"
  # (optionnel) si pydantic-core ou pydantic-settings sont figés, on les laisse; sinon on peut ajouter:
  # echo 'pydantic-settings>=2.6,<3.0' >> "$REQ"
  echo "[OK] $REQ mis à jour -> pydantic>=2.11,<3.0"
fi

# --- 2) Refactor Python: class Config -> model_config = ConfigDict(...)
SRC_DIR="$ROOT/backend/app"
[[ -d "$SRC_DIR" ]] || SRC_DIR="$ROOT/app"
[[ -d "$SRC_DIR" ]] || { echo "[WARN] Dossier des sources introuvable (backend/app ou app). Skip refactor."; SKIP_REFACTOR=1; }

if [[ -z "${SKIP_REFACTOR:-}" ]]; then
  python3 - <<'PY'
import os, re, sys, time
from pathlib import Path

ROOT = Path.cwd()
SRC_DIRS = [ROOT / "backend" / "app", ROOT / "app"]
SRC = None
for d in SRC_DIRS:
    if d.is_dir():
        SRC = d
        break
if SRC is None:
    print("[WARN] SRC introuvable, abandon refactor.")
    sys.exit(0)

backup_dir = ROOT / f".bak_pyd_v2_{time.strftime('%Y%m%d_%H%M%S')}"
backup_dir.mkdir(exist_ok=True)
modified = []
warnings = []

def ensure_configdict_import(text: str) -> str:
    """
    Ajoute 'ConfigDict' dans 'from pydantic import ...' si BaseModel est importé ici.
    Si aucun import pydantic n'existe mais BaseModel est utilisé, ajoute une ligne d'import.
    """
    lines = text.splitlines()
    has_pydantic_import = False
    has_configdict = False
    first_import_idx = None
    uses_basemodel = "BaseModel" in text

    for i, line in enumerate(lines):
        if line.startswith("from pydantic import "):
            has_pydantic_import = True
            if "ConfigDict" in line:
                has_configdict = True
            else:
                # inject ConfigDict dans cette ligne
                lines[i] = line.rstrip() + (", ConfigDict" if line.strip().endswith("import") is False else " ConfigDict")
                has_configdict = True
            break
        if line.startswith("import ") or line.startswith("from "):
            if first_import_idx is None:
                first_import_idx = i

    if not has_pydantic_import and uses_basemodel:
        insert_at = first_import_idx if first_import_idx is not None else 0
        lines.insert(insert_at, "from pydantic import ConfigDict")
        has_configdict = True

    return "\n".join(lines)

def find_docstring_block(lines, start_idx, class_indent):
    """
    Si le premier élément du corps de classe est un docstring triple quotes,
    renvoie l'index de fin de ce bloc (ligne après la fermeture).
    Sinon, renvoie start_idx+1.
    """
    i = start_idx + 1
    # Cherche première ligne non vide, avec indentation > class_indent
    while i < len(lines) and (lines[i].strip() == "" or len(lines[i]) - len(lines[i].lstrip(" ")) <= class_indent):
        i += 1
    if i >= len(lines):
        return start_idx + 1
    s = lines[i].lstrip()
    if s.startswith('"""') or s.startswith("'''"):
        q = s[:3]
        # si le docstring se termine sur la même ligne
        if s.count(q) >= 2:
            return i + 1
        # sinon, parcours jusqu'à fermeture
        i += 1
        while i < len(lines):
            if q in lines[i]:
                return i + 1
            i += 1
        return i
    else:
        return start_idx + 1

def refactor_file(path: Path):
    txt = path.read_text(encoding="utf-8")
    original = txt

    # On ne traite que les fichiers où BaseModel apparaît et où 'class Config:' est présent
    if "BaseModel" not in txt or "class Config" not in txt:
        return None, []

    lines = txt.splitlines()
    i = 0
    file_warnings = []
    changed = False

    while i < len(lines):
        line = lines[i]
        # Match une classe BaseModel
        m = re.match(r'^(\s*)class\s+(\w+)\((.*?)\)\s*:\s*$', line)
        if not m:
            i += 1
            continue

        class_indent = len(m.group(1).expandtabs(4))
        bases = m.group(3)
        if "BaseModel" not in bases:
            i += 1
            continue

        # Délimite les lignes du corps de la classe jusqu'à prochaine classe/def au même ou moindre indent
        j = i + 1
        while j < len(lines):
            l = lines[j]
            indent = len(l) - len(l.lstrip(" "))
            if l.startswith(("class ", "def ")) and indent <= class_indent:
                break
            j += 1

        # Cherche "class Config:" à indent = class_indent + 4 dans [i+1, j)
        k = i + 1
        cfg_start = cfg_end = None
        cfg_indent = class_indent + 4
        while k < j:
            lk = lines[k]
            if re.match(rf'^\s{{{cfg_indent}}}class\s+Config\s*:\s*$', lk):
                cfg_start = k
                # trouver fin du bloc Config
                k += 1
                while k < j:
                    if (len(lines[k]) - len(lines[k].lstrip(" "))) <= cfg_indent and lines[k].strip() != "":
                        break
                    k += 1
                cfg_end = k
                break
            k += 1

        if cfg_start is None:
            i = j
            continue

        # Extraire les flags connus
        cfg_block = "\n".join(lines[cfg_start:cfg_end])
        def has_flag(name):
            return re.search(rf'^\s*{name}\s*=\s*True\s*$', cfg_block, re.M) is not None
        def get_extra():
            m2 = re.search(r'^\s*extra\s*=\s*["\'](forbid|ignore|allow)["\']\s*$', cfg_block, re.M)
            return m2.group(1) if m2 else None
        if re.search(r'json_encoders\s*=', cfg_block):
            file_warnings.append(f"[{path}] Contient json_encoders dans Config (pydantic v2 -> utiliser field_serializer). À adapter manuellement.")

        entries = []
        if has_flag("orm_mode"):
            entries.append("from_attributes=True")
        xtra = get_extra()
        if xtra:
            entries.append(f'extra="{xtra}"')
        if has_flag("allow_population_by_field_name"):
            entries.append("populate_by_name=True")
        if has_flag("arbitrary_types_allowed"):
            entries.append("arbitrary_types_allowed=True")

        # Supprime le bloc Config
        del lines[cfg_start:cfg_end]

        # Point d'insertion: juste après l'éventuel docstring
        insert_at = find_docstring_block(lines, i, class_indent)
        model_cfg_line = " " * (class_indent + 4) + "model_config = ConfigDict(" + ", ".join(entries) + ")"
        lines.insert(insert_at, model_cfg_line)
        changed = True

        # Ajuster j après modification
        j = j - (cfg_end - cfg_start) + 1
        i = j

    if changed:
        # Ajoute import ConfigDict si besoin
        new_txt = "\n".join(lines)
        new_txt2 = ensure_configdict_import(new_txt)
        path_backup = backup_dir / path.relative_to(ROOT)
        path_backup.parent.mkdir(parents=True, exist_ok=True)
        path_backup.write_text(original, encoding="utf-8")
        path.write_text(new_txt2, encoding="utf-8")
        return path, file_warnings
    else:
        return None, []

# Parcours des .py
for py in SRC.rglob("*.py"):
    p, warns = refactor_file(py)
    if p is not None:
        modified.append(p)
    warnings.extend(warns)

print(f"[OK] Refactor terminé. Fichiers modifiés: {len(modified)}")
for w in warnings:
    print("[WARN]", w)
PY
fi

# --- 3) Rebuild & tests
echo "[STEP] docker compose build api"
docker compose build api

echo "[STEP] docker compose up -d api"
docker compose up -d api

echo "[STEP] docker compose exec -T api pytest -q /app/tests/test_routes_invoices.py /app/tests/test_public_url.py /app/tests/test_invoice_public_pdf.py"
docker compose exec -T api pytest -q /app/tests/test_routes_invoices.py /app/tests/test_public_url.py /app/tests/test_invoice_public_pdf.py || {
  echo "[ERR] Des tests ont échoué. Consulte les logs ci-dessus."
  exit 1
}

echo "[DONE] Upgrade Pydantic v2 + refactor terminé ✔"
