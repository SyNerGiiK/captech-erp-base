#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

stamp(){ date +"%Y-%m-%d %H:%M:%S"; }

echo "[$(stamp)] Lecture DATABASE_URL depuis le conteneur api…"
DBURL="$(docker compose exec -T api printenv DATABASE_URL 2>/dev/null || true | tr -d '\r')"

if [ -z "$DBURL" ]; then
  echo "[$(stamp)] ⚠️ DATABASE_URL introuvable dans le conteneur api."
  echo "           Exemple attendu: postgresql+asyncpg://user:pass@db:5432/appdb"
  echo "           Tu peux aussi fixer la base dans .env et relancer."
  exit 1
fi

# Extraction naïve user / db depuis l'URL
DBNAME="$(echo "$DBURL" | sed -E 's#^.*/([^/?]+)(\?.*)?$#\1#')"
DBUSER="$(echo "$DBURL" | sed -E 's#^[^:]+://([^:]+):.*$#\1#')"

echo "[$(stamp)] DATABASE_URL=$DBURL"
echo "[$(stamp)] -> base: $DBNAME | user: $DBUSER"

echo "[$(stamp)] Vérification existence base…"
EXISTS="$(docker compose exec -T db psql -U postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${DBNAME}'" | tr -d '[:space:]')"

if [ "$EXISTS" != "1" ]; then
  echo "[$(stamp)] Création base '${DBNAME}'…"
  docker compose exec -T db psql -U postgres -c "CREATE DATABASE ${DBNAME};"
else
  echo "[$(stamp)] Base '${DBNAME}' déjà présente."
fi

echo "[$(stamp)] Vérification du rôle '${DBUSER}'…"
HASROLE="$(docker compose exec -T db psql -U postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DBUSER}'" | tr -d '[:space:]')"

if [ "$HASROLE" = "1" ]; then
  echo "[$(stamp)] Le rôle existe -> transfert de propriété de '${DBNAME}' vers '${DBUSER}'…"
  docker compose exec -T db psql -U postgres -c "ALTER DATABASE ${DBNAME} OWNER TO ${DBUSER};" || true
else
  echo "[$(stamp)] ⚠️ Le rôle '${DBUSER}' n'existe pas. On laisse l'owner par défaut."
fi

echo "[$(stamp)] Test santé API -> /healthz"
docker compose exec -T api curl -sf http://localhost:8000/healthz || true
echo
echo "[$(stamp)] Terminé."
