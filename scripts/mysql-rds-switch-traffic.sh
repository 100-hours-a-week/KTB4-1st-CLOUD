#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=mysql-rds-migration-common.sh
source "${SCRIPT_DIR}/mysql-rds-migration-common.sh"

with_migration_lock
[[ -f "${MIGRATION_STATE_DIR}/rds-promoted" ]] ||
  die "run mysql-rds-promote.sh first"
[[ -f "${MIGRATION_STATE_DIR}/barrier-acquired" ]] ||
  die "application write barrier is not recorded"

log "switching datasource to RDS while writes remain blocked"
admin_post '/commit?target=RDS' >/dev/null
log "verifying application read/write health against RDS"
admin_post '/health?target=RDS' >/dev/null
log "releasing the application write barrier"
admin_post '/release?target=RDS' >/dev/null
state_put traffic-switched "$(date -u +%FT%TZ)"
rm -f "${MIGRATION_STATE_DIR}/barrier-acquired"
log "traffic is now served by RDS without dropping queued writes"
