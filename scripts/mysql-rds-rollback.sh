#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=mysql-rds-migration-common.sh
source "${SCRIPT_DIR}/mysql-rds-migration-common.sh"

with_migration_lock
: "${ROLLBACK_TARGET:=EC2}"
[[ "$ROLLBACK_TARGET" == "EC2" ]] || die "only EC2 rollback is supported"
[[ -f "${MIGRATION_STATE_DIR}/traffic-switched" ]] ||
  die "traffic has not been switched to RDS"

log "acquiring the application write barrier for rollback"
admin_post '/prepare?target=EC2' >/dev/null
if [[ "$(docker inspect -f '{{.State.Running}}' "$EC2_CONTAINER" 2>/dev/null || true)" != "true" ]]; then
  log "starting the retained EC2 MySQL container"
  docker start "$EC2_CONTAINER" >/dev/null
fi
for _ in $(seq 1 60); do
  source_mysql -Nse 'SELECT 1' >/dev/null 2>&1 && break
  sleep 2
done
source_mysql -Nse 'SELECT 1' >/dev/null ||
  die "EC2 MySQL did not become reachable during rollback"
if [[ "${EC2_REVERSE_REPLICA_READY:-no}" != "yes" ]]; then
  die "EC2 reverse replication must be caught up and verified before rollback"
fi
reverse_status="$(source_mysql -e 'SHOW REPLICA STATUS\G')"
[[ "$(replica_field "$reverse_status" Replica_IO_Running)" == "Yes" ]] ||
  die "EC2 reverse replica IO thread is not running"
[[ "$(replica_field "$reverse_status" Replica_SQL_Running)" == "Yes" ]] ||
  die "EC2 reverse replica SQL thread is not running"
[[ -z "$(replica_field "$reverse_status" Last_IO_Error)" ]] ||
  die "EC2 reverse replica has an IO error"
[[ -z "$(replica_field "$reverse_status" Last_SQL_Error)" ]] ||
  die "EC2 reverse replica has a SQL error"
source_mysql -e 'SET GLOBAL super_read_only = OFF; SET GLOBAL read_only = OFF;'
admin_post '/commit?target=EC2' >/dev/null
admin_post '/health?target=EC2' >/dev/null
admin_post '/release?target=EC2' >/dev/null
state_put rolled-back "$(date -u +%FT%TZ)"
log "traffic was rolled back to EC2 without bypassing replication verification"
