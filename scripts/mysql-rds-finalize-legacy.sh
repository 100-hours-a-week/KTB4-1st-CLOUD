#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=mysql-rds-migration-common.sh
source "${SCRIPT_DIR}/mysql-rds-migration-common.sh"

with_migration_lock
[[ -f "${MIGRATION_STATE_DIR}/traffic-switched" ]] ||
  die "traffic has not been switched to RDS"
[[ "${CONFIRM_FINALIZE:-}" == "yes" ]] ||
  die "set CONFIRM_FINALIZE=yes after the rollback retention window"

log "keeping EC2 MySQL read-only while finalizing the legacy host"
source_mysql -e 'SET GLOBAL super_read_only = ON; SET GLOBAL read_only = ON;'
docker update --restart=no "$EC2_CONTAINER" >/dev/null
docker stop "$EC2_CONTAINER" >/dev/null
state_put legacy-finalized "$(date -u +%FT%TZ)"
log "legacy EC2 MySQL stopped; retain its volume and backups for rollback"
