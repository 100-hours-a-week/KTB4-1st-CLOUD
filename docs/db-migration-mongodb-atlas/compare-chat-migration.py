#!/usr/bin/env python3
"""Compare MySQL and Atlas chat-message JSONL exports through a shared message_id watermark."""

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo


FIELDS = (
    "chat_room_id",
    "user_id",
    "content",
    "message_type",
    "system_event_type",
    "message_object_id",
    "created_at",
)


def load_mysql(path):
    rows = []
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        value = json.loads(line)
        rows.append(value)
    return rows


def load_atlas(path):
    rows = []
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        if line.startswith("ROW "):
            rows.append(json.loads(line[4:]))
    return rows


def normalize_id(value):
    return None if value is None else str(value)


def normalize_time(value, mysql_timezone=None):
    if value is None:
        return None
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        if mysql_timezone is None:
            raise ValueError("MySQL 시간대가 필요합니다.")
        parsed = parsed.replace(tzinfo=mysql_timezone)
    parsed = parsed.astimezone(timezone.utc)
    # BSON Date는 밀리초 정밀도이므로 양쪽을 밀리초로 맞춰 비교합니다.
    return parsed.replace(microsecond=(parsed.microsecond // 1000) * 1000)


def index_rows(rows, side):
    indexed = {}
    duplicates = []
    for row in rows:
        message_id = normalize_id(row.get("message_id"))
        if message_id is None:
            duplicates.append("<missing message_id>")
        elif message_id in indexed:
            duplicates.append(message_id)
        else:
            indexed[message_id] = row
    if duplicates:
        print(f"{side} duplicate/missing message_id: {', '.join(duplicates[:20])}")
    return indexed, duplicates


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mysql_jsonl", help="MySQL SQL 파일 실행 결과")
    parser.add_argument("atlas_output", help="mongosh Atlas 스크립트 실행 결과")
    parser.add_argument(
        "--mysql-timezone", required=True,
        help="MySQL DATETIME이 나타내는 시간대. 예: Asia/Seoul 또는 UTC",
    )
    args = parser.parse_args()

    mysql_timezone = ZoneInfo(args.mysql_timezone)
    mysql_rows = load_mysql(args.mysql_jsonl)
    atlas_rows = load_atlas(args.atlas_output)
    mysql_by_id, mysql_duplicates = index_rows(mysql_rows, "MySQL")
    atlas_by_id, atlas_duplicates = index_rows(atlas_rows, "Atlas")

    mysql_ids = set(mysql_by_id)
    atlas_ids = set(atlas_by_id)
    missing = sorted(mysql_ids - atlas_ids, key=int)
    extra = sorted(atlas_ids - mysql_ids, key=int)
    differences = []

    for message_id in sorted(mysql_ids & atlas_ids, key=int):
        source = mysql_by_id[message_id]
        target = atlas_by_id[message_id]
        for field in FIELDS:
            # V27 이전 메시지는 MySQL message_object_id가 NULL일 수 있습니다.
            # MongoDB는 문서에 _id가 필요하므로, 이 경우 자동 생성된 _id와 대조하지 않습니다.
            if field == "message_object_id" and source.get(field) is None:
                continue
            if field == "created_at":
                source_value = normalize_time(source.get(field), mysql_timezone)
                target_value = normalize_time(target.get(field))
            elif field in ("chat_room_id", "user_id"):
                source_value = normalize_id(source.get(field))
                target_value = normalize_id(target.get(field))
            else:
                source_value = source.get(field)
                target_value = target.get(field)
            if source_value != target_value:
                differences.append((message_id, field, source.get(field), target.get(field)))

    print(f"MySQL rows: {len(mysql_rows)}; unique IDs: {len(mysql_by_id)}")
    print(f"Atlas rows: {len(atlas_rows)}; unique IDs: {len(atlas_by_id)}")
    print(f"Missing in Atlas: {len(missing)}")
    print(f"Extra in Atlas: {len(extra)}")
    print(f"Field differences: {len(differences)}")
    for label, values in (("Missing IDs", missing), ("Extra IDs", extra)):
        if values:
            print(f"{label} (first 100): {', '.join(values[:100])}")
    for message_id, field, source, target in differences[:100]:
        print(f"Field difference message_id={message_id} field={field}: MySQL={source!r} Atlas={target!r}")
    if len(missing) > 100 or len(extra) > 100 or len(differences) > 100:
        print("Only the first 100 mismatches of each kind are shown.")

    ok = not (mysql_duplicates or atlas_duplicates or missing or extra or differences)
    print("RESULT: " + ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(2)
