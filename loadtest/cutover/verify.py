#!/usr/bin/env python3
"""기존 DB·메시지 검증에 실제 전환 구간의 요청·연결 커버리지를 추가한다."""
import argparse
from collections import Counter
import importlib.util
import json
from pathlib import Path
import tempfile

spec = importlib.util.spec_from_file_location('workload_verify', Path(__file__).with_name('workload_verify.py'))
workload = importlib.util.module_from_spec(spec)
spec.loader.exec_module(workload)
EXTRA = {'cutover_config', 'chat_connected', 'long_start', 'long_end'}
PHASES = ['switch_start', 'switch_complete', 'rollback_start', 'rollback_complete']


def coverage(entries, phases):
    errors, result = [], {}
    if [p.get('phase') for p in phases] == PHASES[:2]:
        return {}, ['미검증 구간: rollback (롤백 미실행)']
    if [p.get('phase') for p in phases] != PHASES or any(not isinstance(p.get('at'), int) for p in phases):
        return {}, ['전환·롤백 네 시점을 순서대로 한 번씩 기록해야 합니다']
    t = [p['at'] for p in phases]
    if t != sorted(set(t)):
        return {}, ['전환 시점의 순서가 잘못됐습니다']
    def connected(session):
        return [e['at'] for e in entries if e['kind'] == 'chat_connected' and e['session'] == session]
    persistent = connected('persistent')
    endings = [e for e in entries if e['kind'] == 'chat_end' and e['session'] == 'persistent']
    result['persistent_chat'] = len(persistent) == 2 and max(persistent) < t[0] and len(endings) == 1 and endings[0]['at'] > t[3]
    split = sorted(connected('split'))
    result['mixed_v1_v2_chat'] = len(split) == 2 and split[0] < t[0] and t[1] < split[1] < t[2]
    new_sessions = {e['session'] for e in entries if e['kind'] == 'chat_connected' and e['session'].startswith('new-')}
    result['new_v2_chat'] = any(len(connected(s)) == 2 and all(t[1] < at < t[2] for at in connected(s)) for s in new_sessions)
    result['new_rollback_chat'] = any(len(connected(s)) == 2 and all(at > t[3] for at in connected(s)) for s in new_sessions)
    config = [e for e in entries if e['kind'] == 'cutover_config']
    if len(config) != 1:
        errors.append('인프라 전환 설정 원장이 한 개여야 합니다')
    if len(config) == 1 and config[0].get('chat_enabled') is False:
        for key in ['persistent_chat', 'mixed_v1_v2_chat', 'new_v2_chat', 'new_rollback_chat']:
            result.pop(key, None)
    minimum = config[0].get('long_request_min_ms', 3000) if len(config) == 1 else 3000
    if not isinstance(minimum, (int, float)) or minimum < 1000:
        errors.append('긴 요청 최소 시간은 1000ms 이상이어야 합니다')
        minimum = 1000
    slow_starts = {e['key']: e for e in entries if e['kind'] == 'long_start'}
    slow_ends = {e['key']: e for e in entries if e['kind'] == 'long_end'}
    if len(slow_starts) != sum(e['kind'] == 'long_start' for e in entries) or len(slow_ends) != sum(e['kind'] == 'long_end' for e in entries):
        errors.append('중복된 긴 요청 원장')
    if set(slow_starts) != set(slow_ends) or any(e.get('status') != 200 for e in slow_ends.values()):
        errors.append('긴 요청 실패 또는 응답 누락')
    if any(e.get('started') != slow_starts[key].get('started') or e.get('ended', 0) < e.get('started', 0)
           for key, e in slow_ends.items() if key in slow_starts):
        errors.append('긴 요청 시작·완료 시각 불일치')
    for label, boundary in [('switch', t[0]), ('rollback', t[2])]:
        result[f'{label}_long_inflight'] = any(e['started'] <= boundary < e['ended'] and e['ended'] - e['started'] >= minimum and e['status'] == 200 for e in slow_ends.values())
        result[f'{label}_exchange_inflight'] = any(e['kind'] == 'exchange_create' and e['started'] <= boundary < e['ended'] and e['status'] == 201 for e in entries)
    windows = [('v1_before', float('-inf'), t[0]), ('v2', t[1], t[2]), ('v1_after', t[3], float('inf'))]
    for label, start, end in windows:
        created = [e for e in entries if e['kind'] == 'exchange_create' and e.get('valid') is True
                   and start < e.get('started', 0) <= e.get('ended', 0) < end]
        result[f'{label}_exchange_flow'] = any(
            type((create.get('result') or {}).get('id')) is int and all(any(
                e['kind'] == kind and e.get('key') == create.get('key')
                and e.get('exchange') == create['result']['id'] and e.get('valid') is True
                and create['ended'] <= e.get('started', 0) <= e.get('ended', 0) < end
                for e in entries) for kind in ['exchange_detail', 'exchange_cancel'])
            for create in created)
    read_starts = {e['key']: e for e in entries if e['kind'] == 'read_start'}
    read_ends = {e['key']: e for e in entries if e['kind'] == 'read_end'}
    if (len(read_starts) != sum(e['kind'] == 'read_start' for e in entries)
            or len(read_ends) != sum(e['kind'] == 'read_end' for e in entries)
            or not read_starts or set(read_starts) != set(read_ends)
            or any(e.get('status') != 200 or e.get('valid') is not True
                   or e.get('started') != read_starts[key].get('started')
                   or e.get('ended', 0) < e.get('started', 0)
                   for key, e in read_ends.items() if key in read_starts)):
        errors.append('조회 요청 실패 또는 시작·응답 원장 불일치')
    for label, start, end in windows:
        selected = [e for e in read_ends.values() if start < e.get('started', 0) <= e.get('ended', 0) < end]
        result[f'{label}_read'] = bool(selected)

    # 진행 중 교환 요청은 참고 지표다. 긴 요청은 명시적으로 실행한 경우만 필수다.
    required = {key: value for key, value in result.items()
                if not key.endswith('_inflight') or
                (key.endswith('_long_inflight') and len(config) == 1 and config[0].get('long_request_path'))}
    errors.extend(f'미검증 구간: {key}' for key, value in required.items() if not value)
    return result, errors


def verify(ledger, rds, summary, phases, run):
    entries = [json.loads(line) for line in Path(ledger).read_text().splitlines() if line.strip()]
    entries = [e for e in entries if e.get('run') == run]
    timeline = [json.loads(line) for line in Path(phases).read_text().splitlines() if line.strip()]
    if any(e.get('run') != run for e in timeline):
        raise ValueError('다른 실행의 전환 기록입니다')
    with tempfile.TemporaryDirectory() as folder:
        filtered = Path(folder) / 'ledger.jsonl'
        filtered.write_text('\n'.join(json.dumps(e) for e in entries if e['kind'] not in EXTRA))
        # 인프라 전환은 동일 RDS를 공유하므로 최종 RDS 한 개와 원장을 대조한다.
        base = workload.verify(str(filtered), rds, rds, summary, run)
    covered, errors = coverage(entries, timeline)
    if base['mode'] != 'full_duration':
        errors.append('중단된 실행은 인프라 전환 통과로 판정하지 않습니다')
    base['unverified'] = sorted(set(
        [message for message in errors if message.startswith('미검증 구간:')] +
        [f'미검증 구간: {key}' for key, value in covered.items() if key.endswith('_inflight') and not value]))
    base['coverage_errors'] = [message for message in errors if message not in base['unverified']]
    base['errors'].extend(errors)
    base['passed'] = not base['errors']
    base['cutover_coverage'] = covered
    config = next((e for e in entries if e['kind'] == 'cutover_config'), {})
    if config.get('chat_enabled') is False:
        base['excluded'].append('websocket_chat')
    metrics = json.loads(Path(summary).read_text()).get('metrics', {})
    ends = [e for e in entries if e['kind'] == 'read_end']
    base['read_status_counts'] = {str(status): sum(e.get('status') == status for e in ends) for status in sorted({e.get('status', 0) for e in ends})}
    if len(timeline) == 4 and all(type(p.get('at')) is int for p in timeline):
        t = [p['at'] for p in timeline]
        windows = [('v1_before', float('-inf'), t[0]), ('switching', t[0], t[1]),
                   ('v2', t[1], t[2]), ('rolling_back', t[2], t[3]), ('v1_after', t[3], float('inf'))]
        base['read_by_phase'] = {}
        for label, start, end in windows:
            selected = [e for e in entries if e['kind'] == 'read_start' and start <= e['started'] < end]
            completed = [e for e in ends if e['key'] in {r['key'] for r in selected}]
            base['read_by_phase'][label] = {
                'total': len(selected), 'normal': sum(e.get('valid') is True and e.get('status') == 200 for e in completed),
                'failed': sum(e.get('valid') is not True or e.get('status') != 200 for e in completed),
                'unanswered': len(selected) - len(completed),
                'statuses': dict(Counter(str(e.get('status')) for e in completed))}
    base['passed'] = not base['errors']
    base['http'] = {name: metrics.get(name, {}).get('values', {}) for name in ['http_reqs', 'http_req_failed', 'http_req_duration', 'dropped_iterations']}
    return base


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    for option in ['ledger', 'rds', 'summary', 'phases', 'run']:
        parser.add_argument(f'--{option}', required=True)
    result = verify(**vars(parser.parse_args()))
    print(json.dumps(result, ensure_ascii=False, indent=2))
    raise SystemExit(0 if result['passed'] else 1)
