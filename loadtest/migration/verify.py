#!/usr/bin/env python3
"""요청 원장과 두 DB의 시험 데이터를 대조한다. 검증 실패 시 exit 1."""
import argparse
from collections import Counter
import json
from pathlib import Path
import sys


def verify(ledger, source, rds, summary, run):
    errors = []
    expected = {}
    sessions = None
    for line in Path(ledger).read_text().splitlines():
        entry = json.loads(line)
        if entry.get('run') != run:
            continue
        if entry.get('kind') == 'config':
            if sessions is not None:
                errors.append('run ID reused')
            sessions = entry['sessions']
            continue
        kind, key, user = entry['kind'], entry['key'], entry['user']
        identifier = (kind, key, str(user))
        if identifier in expected:
            errors.append(f'duplicate request: {identifier}')
        expected[identifier] = entry
        success = 201 if kind == 'group' else 200
        if entry['status'] != success:
            errors.append(f'request failed/ambiguous: {identifier}, status={entry["status"]}')
    if not expected:
        errors.append('empty request ledger')

    report = json.loads(Path(summary).read_text())
    # k6의 summary에 options가 없는 버전에서도 metrics와 원장 건수를 검증한다.
    metrics = report.get('metrics', {})
    for name in ('dropped_iterations', 'interrupted_iterations'):
        if metrics.get(name, {}).get('values', {}).get('count', 0) != 0:
            errors.append(f'{name} is not zero')
    for name in ('checks', 'http_req_failed'):
        values = metrics.get(name, {}).get('values', {})
        wanted = 1 if name == 'checks' else 0
        if values.get('rate') != wanted:
            errors.append(f'{name}: {values.get("rate")} != {wanted}')
    requests = metrics.get('http_reqs', {}).get('values', {}).get('count')
    iterations = metrics.get('iterations', {}).get('values', {}).get('count')
    if sessions is None or iterations != sessions:
        errors.append(f'incomplete scheduled traffic: expected={sessions}, actual={iterations}')
    if requests != len(expected) or requests != 2 * (iterations or 0):
        errors.append(f'incomplete ledger/iteration: requests={requests}, ledger={len(expected)}, iterations={iterations}')

    snapshots = []
    for name, path in (('source', source), ('rds', rds)):
        rows = []
        for line in Path(path).read_text().splitlines():
            row = tuple(line.split('\t'))
            if len(row) != 5:
                errors.append(f'{name}: malformed export row')
                continue
            if row[1].startswith(f'mg-{run}-'):
                rows.append(row)
        counts = Counter(row[:3] for row in rows)
        for identifier, entry in expected.items():
            if counts[identifier] != 1:
                errors.append(f'{name}: {identifier} count={counts[identifier]}')
        for row in rows:
            if row[:3] not in expected or row[3] != row[1]:
                errors.append(f'{name}: unexpected/mismatched row: {row}')
        snapshots.append(Counter(rows))
    if snapshots[0] != snapshots[1]:
        errors.append('source and RDS rows/IDs differ')
    return {'passed': not errors, 'requests': len(expected), 'errors': errors}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    for option in ('ledger', 'source', 'rds', 'summary', 'run'):
        parser.add_argument(f'--{option}', required=True)
    result = verify(**vars(parser.parse_args()))
    print(json.dumps(result, ensure_ascii=False, indent=2))
    sys.exit(0 if result['passed'] else 1)
