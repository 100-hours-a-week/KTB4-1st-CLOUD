#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=mysql-rds-migration-common.sh
source "${SCRIPT_DIR}/mysql-rds-migration-common.sh"

with_migration_lock
[[ ! -f "${MIGRATION_STATE_DIR}/rds-promoted" ]] ||
  die "RDS is already promoted; use the rollback procedure instead"

if [[ -f "${MIGRATION_STATE_DIR}/source-sealed" ]]; then
  log "re-enabling EC2 MySQL writes"
  source_mysql -e 'SET GLOBAL super_read_only = OFF; SET GLOBAL read_only = OFF;'
  rm -f "${MIGRATION_STATE_DIR}/source-sealed"
fi

if [[ -f "${MIGRATION_STATE_DIR}/barrier-acquired" ]]; then
  log "aborting the application write barrier"
  admin_post '/abort?target=RDS' >/dev/null
  rm -f "${MIGRATION_STATE_DIR}/barrier-acquired"
fi

rm -f "${MIGRATION_STATE_DIR}/target-file" \
  "${MIGRATION_STATE_DIR}/target-pos" \
  "${MIGRATION_STATE_DIR}/drained"
log "migration was safely aborted before RDS promotion"
