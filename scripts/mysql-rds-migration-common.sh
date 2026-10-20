#!/usr/bin/env bash

set -Eeuo pipefail

: "${RDS_HOST:?RDS_HOST is required}"
: "${RDS_USER:?RDS_USER is required}"
: "${RDS_PASSWORD:?RDS_PASSWORD is required}"
: "${EC2_MYSQL_PASSWORD:?EC2_MYSQL_PASSWORD is required}"
: "${WAS_ADMIN_URL:?WAS_ADMIN_URL is required}"

RDS_PORT="${RDS_PORT:-3306}"
EC2_CONTAINER="${EC2_CONTAINER:-mysql}"
WAS_ADMIN_CONTAINER="${WAS_ADMIN_CONTAINER:-}"
MIGRATION_STATE_DIR="${MIGRATION_STATE_DIR:-/var/lib/bakkucca/mysql-migration}"
POLL_SECONDS="${POLL_SECONDS:-2}"
MIGRATION_TIMEOUT_SECONDS="${MIGRATION_TIMEOUT_SECONDS:-900}"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"; }
die() { log "[ERROR] $*" >&2; exit 1; }

require_commands() {
  local command
  for command in "$@"; do
    command -v "$command" >/dev/null || die "${command} is required"
  done
}

require_commands curl docker mysql awk grep flock
umask 077
mkdir -p "$MIGRATION_STATE_DIR"

MYSQL_CNF="${MIGRATION_STATE_DIR}/rds-client.cnf"
cat >"$MYSQL_CNF" <<EOF
[client]
user=${RDS_USER}
password=${RDS_PASSWORD}
host=${RDS_HOST}
port=${RDS_PORT}
connect-timeout=5
EOF

cleanup_mysql_cnf() {
  rm -f "$MYSQL_CNF"
}
trap cleanup_mysql_cnf EXIT

rds_mysql() {
  mysql --defaults-extra-file="$MYSQL_CNF" "$@"
}

source_mysql() {
  docker exec -e MYSQL_PWD="$EC2_MYSQL_PASSWORD" "$EC2_CONTAINER" \
    mysql --protocol=socket -uroot "$@"
}

admin_post() {
  local path="$1"
  if [[ -n "$WAS_ADMIN_CONTAINER" ]]; then
    docker exec "$WAS_ADMIN_CONTAINER" sh -c '
      if command -v curl >/dev/null 2>&1; then
        exec curl --fail --silent --show-error --retry 5 --retry-delay 1 \
          --connect-timeout 5 --max-time 20 -X POST "$1"
      fi
      exec wget -qO- -T 20 --post-data='' "$1"
    ' sh "${WAS_ADMIN_URL}${path}"
  else
    curl --fail --silent --show-error --retry 5 --retry-delay 1 \
      --connect-timeout 5 --max-time 20 -X POST "${WAS_ADMIN_URL}${path}"
  fi
}

with_migration_lock() {
  exec 9>"${MIGRATION_STATE_DIR}/migration.lock"
  flock -n 9 || die "another migration step is running"
}

replica_status() {
  rds_mysql -e 'SHOW REPLICA STATUS\G'
}

replica_field() {
  local status="$1" field="$2"
  awk -v field="$field" '
    {
      separator = index($0, ":")
      key = $0
      sub(/[[:space:]]*:.*$/, "", key)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      if (key == field) {
        value = substr($0, separator + 1)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        print value
        exit
      }
    }
  ' <<<"$status"
}

assert_replica_healthy() {
  local status="$1"
  local io_running sql_running last_io_error last_sql_error
  io_running="$(replica_field "$status" Replica_IO_Running)"
  sql_running="$(replica_field "$status" Replica_SQL_Running)"
  last_io_error="$(replica_field "$status" Last_IO_Error)"
  last_sql_error="$(replica_field "$status" Last_SQL_Error)"

  [[ "$io_running" == "Yes" ]] ||
    die "RDS replica IO thread is not running (state: ${io_running:-unknown})"
  [[ "$sql_running" == "Yes" ]] ||
    die "RDS replica SQL thread is not running (state: ${sql_running:-unknown})"
  [[ -z "$last_io_error" ]] ||
    die "RDS replica has an IO error: $last_io_error"
  [[ -z "$last_sql_error" ]] ||
    die "RDS replica has a SQL error: $last_sql_error"
}

wait_for_source_coordinate() {
  local target_file="$1"
  local target_pos="$2"
  local waited=0 status exec_file exec_pos source_seq exec_seq

  while :; do
    status="$(replica_status)"
    assert_replica_healthy "$status"
    exec_file="$(awk '/Relay_Source_Log_File:/{print $2; exit} /Exec_Source_Log_File:/{print $2; exit}' <<<"$status")"
    exec_pos="$(awk '/Exec_Source_Log_Pos:/{print $2}' <<<"$status")"
    source_seq="${target_file##*.}"
    exec_seq="${exec_file##*.}"

    if [[ "$exec_seq" =~ ^[0-9]+$ && "$exec_pos" =~ ^[0-9]+$ ]] &&
      (( 10#$exec_seq > 10#$source_seq ||
        (10#$exec_seq == 10#$source_seq && exec_pos >= target_pos) )); then
      return 0
    fi

    (( waited >= MIGRATION_TIMEOUT_SECONDS )) &&
      die "replication drain timed out after ${MIGRATION_TIMEOUT_SECONDS}s"
    sleep "$POLL_SECONDS"
    waited=$((waited + POLL_SECONDS))
  done
}

state_get() {
  local key="$1"
  [[ -f "${MIGRATION_STATE_DIR}/${key}" ]] ||
    die "migration state is missing: ${key}"
  cat "${MIGRATION_STATE_DIR}/${key}"
}

state_put() {
  local key="$1" value="$2"
  printf '%s\n' "$value" >"${MIGRATION_STATE_DIR}/${key}"
}
