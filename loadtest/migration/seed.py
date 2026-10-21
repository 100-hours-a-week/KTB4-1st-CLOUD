#!/usr/bin/env python3
"""기존 v1 시드를 재사용하되 Flyway V6에서 삭제된 컬럼의 입력만 제거한다."""
from pathlib import Path
import sys

source = Path(__file__).resolve().parents[1] / 'v1' / 'target' / 'seed.sql'
sql = source.read_text()
columns = 'group_name, active_group_name, road_address'
value = "       IF(n <= 20, CONCAT('loadtest-group-', n), CONCAT('loadtest-join-', n)),\n"
if sql.count(columns) != 1 or sql.count(value) != 2:
    raise SystemExit('v1 seed changed; check migration seed compatibility')
sql = sql.replace(columns, 'group_name, road_address', 1).replace(value, '', 1)
sys.stdout.write(sql)
