#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || ( "$1" != "before" && "$1" != "after" ) ]]; then
	echo "사용법: $0 before|after" >&2
	exit 2
fi

: "${MYSQL_DATABASE:?MYSQL_DATABASE 환경변수에 MySQL DB명을 설정하세요}"
: "${MYSQL_HOST:?MYSQL_HOST 환경변수에 RDS 엔드포인트를 설정하세요}"
: "${MYSQL_PORT:?MYSQL_PORT 환경변수에 RDS 포트를 설정하세요}"
: "${MYSQL_USER:?MYSQL_USER 환경변수에 MySQL 계정을 설정하세요}"
: "${ATLAS_DATABASE:?ATLAS_DATABASE 환경변수에 Atlas DB명을 설정하세요}"
: "${MONGODB_URI:?MONGODB_URI 환경변수에 Atlas 접속 URI를 설정하세요}"
: "${MYSQL_TIMEZONE:?MYSQL_TIMEZONE 환경변수에 MySQL DATETIME 시간대를 설정하세요}"
if [[ ! "$MYSQL_PORT" =~ ^[0-9]+$ ]]; then
	echo "MYSQL_PORT는 숫자여야 합니다." >&2
	exit 2
fi
if [[ ! "$ATLAS_DATABASE" =~ ^[A-Za-z0-9_-]+$ ]]; then
	echo "ATLAS_DATABASE는 영문자, 숫자, 밑줄, 하이픈만 포함해야 합니다." >&2
	exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
timestamp="$(date +%Y%m%d-%H%M%S)"
phase="$1"
mysql_output="$script_dir/chat-validation-${phase}-${timestamp}-mysql.jsonl"
atlas_output="$script_dir/chat-validation-${phase}-${timestamp}-atlas.txt"

if [[ -z "${MYSQL_PASSWORD:-}" ]]; then
	read -r -s -p "MySQL 비밀번호: " MYSQL_PASSWORD
	printf '\n'
fi
export MYSQL_PASSWORD
mysql_defaults_file="$(mktemp "${TMPDIR:-/tmp}/chat-migration-mysql.XXXXXX")"
chmod 600 "$mysql_defaults_file"
trap 'rm -f "$mysql_defaults_file"' EXIT

python3 - "$mysql_defaults_file" <<'PY'
import os
import sys

def quote_option(value):
	value = value.replace("\\", "\\\\").replace('"', '\\"')
	value = value.replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")
	return f'"{value}"'

with open(sys.argv[1], "w", encoding="utf-8") as config:
	config.write("[client]\n")
	for name in ("MYSQL_HOST", "MYSQL_PORT", "MYSQL_USER", "MYSQL_PASSWORD"):
		config.write(f"{name.removeprefix('MYSQL_').lower()}={quote_option(os.environ.get(name, ''))}\n")
PY
unset MYSQL_PASSWORD

watermark="$(mysql --defaults-extra-file="$mysql_defaults_file" --batch --skip-column-names \
	"$MYSQL_DATABASE" -e 'SELECT COALESCE(MAX(message_id), 0) FROM chat_messages')"
if [[ ! "$watermark" =~ ^[0-9]+$ ]]; then
	echo "MySQL에서 유효한 워터마크를 얻지 못했습니다: $watermark" >&2
	exit 2
fi

echo "검증 단계: $phase"
echo "워터마크(message_id 상한): $watermark"

mysql --defaults-extra-file="$mysql_defaults_file" \
	--init-command="SET @watermark_message_id = ${watermark}" \
	--batch --raw --skip-column-names "$MYSQL_DATABASE" \
	< "$script_dir/chat-migration-validation-mysql.sql" > "$mysql_output"

(
	cd "$script_dir"
	mongosh "$MONGODB_URI" --quiet \
		--eval "globalThis.CHAT_VALIDATION_DATABASE = '${ATLAS_DATABASE}'; globalThis.CHAT_VALIDATION_WATERMARK = ${watermark}; load('chat-migration-validation-atlas.js');" \
		> "$atlas_output"
)

python3 "$script_dir/compare-chat-migration.py" \
	"$mysql_output" "$atlas_output" --mysql-timezone "$MYSQL_TIMEZONE"

echo "MySQL 결과: $mysql_output"
echo "Atlas 결과: $atlas_output"
