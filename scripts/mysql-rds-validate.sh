#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=mysql-rds-migration-common.sh
source "${SCRIPT_DIR}/mysql-rds-migration-common.sh"

with_migration_lock
log "validating EC2 MySQL and RDS connectivity"
source_mysql -Nse 'SELECT VERSION(), @@read_only, @@super_read_only' >/dev/null
rds_mysql -Nse 'SELECT VERSION(), @@read_only, @@super_read_only' >/dev/null

status="$(replica_status)"
assert_replica_healthy "$status"
[[ "$(replica_field "$status" Seconds_Behind_Source)" == "0" ]] ||
  log "replica is healthy but currently catching up; prepare step will wait"

source_mysql -Nse "
  SELECT CASE
    WHEN @@version LIKE '8.4.%'
      AND @@log_bin = 1
      AND @@binlog_format = 'ROW'
      AND @@binlog_row_image = 'FULL'
      AND @@server_id <> 0
    THEN 1 ELSE 0 END
" | grep -qx 1 || die "source MySQL is not configured for MySQL 8.4 row-based binlog replication"
log "preflight validation passed"
