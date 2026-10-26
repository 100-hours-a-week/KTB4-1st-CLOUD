#!/usr/bin/env python3
"""현재 실행의 응답 ID로 제한한 읽기 전용 export SQL을 출력한다."""
import argparse
import json
import re
from pathlib import Path


def prepare(ledger, run):
    if not re.fullmatch('[a-z0-9]{1,10}', run):
        raise ValueError('RUN_ID 형식 오류')
    rows = [json.loads(line) for line in Path(ledger).read_text().splitlines() if line.strip()]
    rows = [r for r in rows if r.get('run') == run]
    def ids(kind, field):
        values = [r.get('result', {}).get('id') if field == 'result' else r.get(field)
                  for r in rows if r.get('kind') == kind and r.get('valid') is True]
        if any(type(v) is not int or v <= 0 for v in values):
            raise ValueError('유효하지 않은 응답/물품 ID')
        return ','.join(str(v) for v in sorted(set(values)))
    prefix = f"SET @cutover_prefix = 'mg-{run}-%';\n"
    prefix += f"SET @cutover_exchange_ids = '{ids('exchange_create', 'result')}';\n"
    prefix += f"SET @cutover_deleted_ids = '{ids('item_delete', 'item')}';\n"
    return prefix + Path(__file__).with_name('export.sql').read_text()


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--ledger', required=True)
    p.add_argument('--run', required=True)
    args = p.parse_args()
    print(prepare(args.ledger, args.run))
