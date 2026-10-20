#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=mysql-rds-migration-common.sh
source "${SCRIPT_DIR}/mysql-rds-migration-common.sh"

with_migration_lock
if [[ ! -f "${MIGRATION_STATE_DIR}/source-sealed" ]]; then
  log "acquiring the shared application write barrier"
  admin_post '/prepare?target=RDS' >/dev/null
  state_put barrier-acquired "$(date -u +%FT%TZ)"

  log "sealing EC2 MySQL writes"
  source_mysql -e 'SET GLOBAL super_read_only = ON; SET GLOBAL read_only = ON;'
  state_put source-sealed "$(date -u +%FT%TZ)"

  source_coord="$(source_mysql -Nse 'SHOW BINARY LOG STATUS')"
  target_file="$(awk '{print $1}' <<<"$source_coord")"
  target_pos="$(awk '{print $2}' <<<"$source_coord")"
  [[ "$target_file" =~ ^binlog\.[0-9]+$ && "$target_pos" =~ ^[0-9]+$ ]] ||
    die "invalid source binlog coordinate"
  state_put target-file "$target_file"
  state_put target-pos "$target_pos"
else
  log "source is already sealed; resuming replication drain"
  target_file="$(state_get target-file)"
  target_pos="$(state_get target-pos)"
fi

log "waiting for RDS to apply ${target_file}:${target_pos}"
wait_for_source_coordinate "$target_file" "$target_pos"
state_put drained "$(date -u +%FT%TZ)"
log "source sealed and RDS drain completed"
