import re
import sys
from pathlib import Path

ROOT = Path("backend/app")

# Regex pour capturer un bloc "class Config:"
CONFIG_RE = re.compile(
    r'(?m)^(?P<indent>\s*)class\s+Config\s*:\s*\n(?P<body>(?:\s{4,}.*\n)+)'
)

# Clés v1 -> v2 (ConfigDict)
MAPPINGS = {
    "orm_mode": ("from_attributes", lambda v: v == "True", lambda _: "True"),
    "allow_population_by_field_name": ("populate_by_name", lambda v: v == "True", lambda _: "True"),
    "anystr_strip_whitespace": ("str_strip_whitespace", lambda v: v == "True", lambda _: "True"),
    "min_anystr_length": ("str_min_length", lambda v: v.isdigit(), lambda v: v),
    "validate_assignment": ("validate_assignment", lambda v: v in ("True","False"), lambda v: v),
    "arbitrary_types_allowed": ("arbitrary_types_allowed", lambda v: v in ("True","False"), lambda v: v),
    "use_enum_values": ("use_enum_values", lambda v: v in ("True","False"), lambda v: v),
    # extra='allow'|'forbid'|'ignore'
    "extra": ("extra", lambda v: True, lambda v: v),
    # v2 garde aussi 'title', 'frozen', etc. si jamais présents
}

def _extract_kv_lines(body: str, base_indent: str) -> list[tuple[str,str,str]]:
    """
    Retourne [(raw_line, key, value)] pour lignes de type "key = value".
    """
    out = []
    for line in body.splitlines():
        # On ignore docstrings/commentaires éventuels dans le bloc Config
        if not line.strip() or line.strip().startswith(("#", '"""', "'''")):
            continue
        m = re.match(rf"^{re.escape(base_indent)}\s+(?P<k>[A-Za-z0-9_]+)\s*=\s*(?P<v>.+?)\s*$", line)
        if m:
            out.append((line, m.group("k"), m.group("v")))
    return out

def _ensure_configdict_import(text: str) -> str:
    # Cherche un import "from pydantic import ..."
    m = re.search(r"(?m)^from\s+pydantic\s+import\s+([^\n]+)$", text)
    if not m:
        # Aucun import direct => on ne force pas (peut-être import global)
        return text
    line = m.group(0)
    items = [x.strip() for x in m.group(1).split(",")]
    if "ConfigDict" not in items:
        items.append("ConfigDict")
        items_sorted = ", ".join(sorted(set(items)))
        newline = f"from pydantic import {items_sorted}"
        text = text.replace(line, newline)
    return text

def refactor_file(path: Path) -> bool:
    txt = path.read_text(encoding="utf-8")
    original = txt

    # Si déjà en v2 (model_config =) on ne touche pas
    if "model_config = ConfigDict(" in txt:
        return False

    # Remplace les blocs class Config:
    def _replace(m: re.Match) -> str:
        indent = m.group("indent")
        body = m.group("body")
        kvs = _extract_kv_lines(body, indent)

        mapped_parts = []
        unknown_lines = []

        for raw, k, v in kvs:
            if k in MAPPINGS:
                new_key, validator, emitter = MAPPINGS[k]
                vv = v.strip()
                if validator(vv):
                    mapped_parts.append(f"{new_key}={emitter(vv)}")
                else:
                    unknown_lines.append(raw.strip())
            else:
                # non mappé automatiquement (ex: json_encoders)
                unknown_lines.append(raw.strip())

        cfg_line = f"{indent}model_config = ConfigDict({', '.join(mapped_parts)})\n"
        if unknown_lines:
            comment = "\n".join(f"{indent}# TODO(pydantic v2): vérifier -> {l}" for l in unknown_lines) + "\n"
        else:
            comment = ""

        return cfg_line + comment

    new_txt, n = CONFIG_RE.subn(_replace, txt)

    if n > 0:
        new_txt = _ensure_configdict_import(new_txt)
        path.write_text(new_txt, encoding="utf-8")
        return True
    return False

def main():
    changed = []
    for p in ROOT.rglob("*.py"):
        try:
            if refactor_file(p):
                changed.append(str(p))
        except Exception as e:
            print(f"[WARN] Échec refactor {p}: {e}")
    if changed:
        print("[OK] Fichiers modifiés (Pydantic v2):")
        for c in changed:
            print("  -", c)
    else:
        print("[OK] Aucun fichier à refactor ou déjà migré.")

if __name__ == "__main__":
    main()
