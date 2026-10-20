#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=mysql-rds-migration-common.sh
source "${SCRIPT_DIR}/mysql-rds-migration-common.sh"

: "${REVERSE_REPL_USER:?REVERSE_REPL_USER is required}"
: "${REVERSE_REPL_PASSWORD:?REVERSE_REPL_PASSWORD is required}"
: "${REVERSE_REPL_SSL:=1}"

with_migration_lock
[[ -f "${MIGRATION_STATE_DIR}/rds-promoted" ]] ||
  die "run mysql-rds-promote.sh first"

coord="$(rds_mysql -Nse 'SHOW BINARY LOG STATUS')"
log_file="$(awk '{print $1}' <<<"$coord")"
log_pos="$(awk '{print $2}' <<<"$coord")"
[[ "$log_file" =~ ^(binlog|mysql-bin-changelog)\.[0-9]+$ && "$log_pos" =~ ^[0-9]+$ ]] ||
  die "invalid RDS binlog coordinate"

source_mysql -e "
  STOP REPLICA;
  RESET REPLICA ALL;
  CHANGE REPLICATION FILTER REPLICATE_WILD_IGNORE_TABLE = ('mysql.rds_%');
  SET GLOBAL super_read_only = ON;
  SET GLOBAL read_only = ON;
  CHANGE REPLICATION SOURCE TO
    SOURCE_HOST='${RDS_HOST}',
    SOURCE_PORT=${RDS_PORT},
    SOURCE_USER='${REVERSE_REPL_USER}',
    SOURCE_PASSWORD='${REVERSE_REPL_PASSWORD}',
    SOURCE_LOG_FILE='${log_file}',
    SOURCE_LOG_POS=${log_pos},
    SOURCE_SSL=${REVERSE_REPL_SSL},
    GET_SOURCE_PUBLIC_KEY=1;
  START REPLICA;
"

for _ in $(seq 1 30); do
  status="$(source_mysql -e 'SHOW REPLICA STATUS\G' || true)"
  if [[ "$(replica_field "$status" Replica_IO_Running)" == "Yes" ]] &&
    [[ "$(replica_field "$status" Replica_SQL_Running)" == "Yes" ]] &&
    [[ -z "$(replica_field "$status" Last_IO_Error)" ]] &&
    [[ -z "$(replica_field "$status" Last_SQL_Error)" ]]; then
    state_put reverse-replica-ready "$(date -u +%FT%TZ)"
    log "EC2 reverse replica is healthy from ${log_file}:${log_pos}"
    exit 0
  fi
  sleep 2
done
die "EC2 reverse replica did not become healthy"
