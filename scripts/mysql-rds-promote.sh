#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=mysql-rds-migration-common.sh
source "${SCRIPT_DIR}/mysql-rds-migration-common.sh"

with_migration_lock
[[ -f "${MIGRATION_STATE_DIR}/source-sealed" ]] ||
  die "run mysql-rds-prepare-drain.sh first"
[[ -f "${MIGRATION_STATE_DIR}/drained" ]] ||
  die "RDS has not reached the source coordinate"

assert_replica_healthy "$(replica_status)"
log "stopping forward replication and promoting RDS"
rds_mysql -e 'CALL mysql.rds_stop_replication; CALL mysql.rds_reset_external_source;'
rds_mysql -Nse "SELECT @@read_only = 0 AND @@super_read_only = 0" | grep -qx 1 ||
  die "RDS is not writable after promotion"
state_put rds-promoted "$(date -u +%FT%TZ)"
log "RDS promotion completed; application barrier remains held"
