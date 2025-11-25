#!/bin/bash
set -e

# Sync schema from production to local dev
# Usage: ./scripts/sync-schema.sh [--with-data]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Load env
if [ -f "$PROJECT_DIR/.env" ]; then
  export $(grep -v '^#' "$PROJECT_DIR/.env" | xargs)
fi

# Production connection (set these in .env or export before running)
PROD_HOST="${PROD_POSTGRES_HOST:?Set PROD_POSTGRES_HOST in .env}"
PROD_PORT="${PROD_POSTGRES_PORT:-5432}"
PROD_DB="${PROD_POSTGRES_DB:?Set PROD_POSTGRES_DB in .env}"
PROD_USER="${PROD_POSTGRES_USER:?Set PROD_POSTGRES_USER in .env}"

# Local connection
LOCAL_HOST="${POSTGRES_HOST:-localhost}"
LOCAL_PORT="${POSTGRES_PORT:-5432}"
LOCAL_DB="${POSTGRES_DB:-ugs}"
LOCAL_USER="${POSTGRES_USER:-postgres}"

DUMP_DIR="$PROJECT_DIR/dumps"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
SCHEMA_DUMP="$DUMP_DIR/schema_${TIMESTAMP}.sql"

mkdir -p "$DUMP_DIR"

echo "==> Dumping schema from production ($PROD_HOST:$PROD_PORT/$PROD_DB)..."

# Schema only by default, add --with-data for data too
if [ "$1" == "--with-data" ]; then
  echo "    Including data (this may take a while)..."
  PGPASSWORD="$PROD_POSTGRES_PASSWORD" pg_dump \
    -h "$PROD_HOST" \
    -p "$PROD_PORT" \
    -U "$PROD_USER" \
    -d "$PROD_DB" \
    --clean \
    --if-exists \
    -f "$SCHEMA_DUMP"
else
  PGPASSWORD="$PROD_POSTGRES_PASSWORD" pg_dump \
    -h "$PROD_HOST" \
    -p "$PROD_PORT" \
    -U "$PROD_USER" \
    -d "$PROD_DB" \
    --schema-only \
    --clean \
    --if-exists \
    -f "$SCHEMA_DUMP"
fi

echo "==> Schema dumped to $SCHEMA_DUMP"

echo "==> Applying schema to local dev ($LOCAL_HOST:$LOCAL_PORT/$LOCAL_DB)..."
PGPASSWORD="$POSTGRES_PASSWORD" psql \
  -h "$LOCAL_HOST" \
  -p "$LOCAL_PORT" \
  -U "$LOCAL_USER" \
  -d "$LOCAL_DB" \
  -f "$SCHEMA_DUMP"

echo "==> Done! Local dev schema synced from production."
echo "    Dump saved at: $SCHEMA_DUMP"
