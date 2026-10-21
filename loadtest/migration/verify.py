#!/usr/bin/env python3
"""API 원장, 채팅 수신 원장과 두 DB의 최종 상태를 대조한다."""
import argparse
from collections import Counter
import json
from pathlib import Path
import sys


STEPS = {
    'group': 201, 'search': 200, 'item_list': 200, 'item_detail': 200, 'my_items': 200,
    'item_update': 204, 'item_updated': 200, 'item_delete': 204, 'item_deleted': 404,
    'exchange_create': 201, 'exchange_detail': 200, 'chat_history': 200, 'exchange_cancel': 204,
}


def verify(ledger, source, rds, summary, run):
    errors, configs = [], []
    requests, sends, received, opened, ended = {}, {}, Counter(), {}, {}
    starts, session_starts, session_ends = set(), set(), set()
    stop_file = Path(summary).with_name(f'{run}-stop.json')
    partial = False
    if stop_file.exists():
        stop = json.loads(stop_file.read_text())
        partial = stop.get('run') == run and stop.get('reason') == 'user_interrupt' and stop.get('exit_code') in (105, 130)
        if not partial:
            errors.append('invalid manual stop record')
    # 이번 실행의 요청 결과와 채팅 송수신 기록을 분류한다.
    for line in Path(ledger).read_text().splitlines():
        entry = json.loads(line)
        if entry.get('run') != run:
            continue
        kind = entry['kind']
        if kind == 'config':
            configs.append(entry)
        elif kind == 'request_start':
            identifier = (entry['step'], entry['key'])
            if identifier in starts or entry['step'] not in STEPS:
                errors.append('duplicate/unknown request start')
            starts.add(identifier)
        elif kind in ('api_session_start', 'api_session_end'):
            entries = session_starts if kind == 'api_session_start' else session_ends
            if entry['key'] in entries:
                errors.append(f'duplicate {kind}')
            entries.add(entry['key'])
        elif kind in STEPS:
            identifier = (kind, entry['key'])
            if identifier in requests:
                errors.append(f'duplicate request: {identifier}')
            requests[identifier] = entry
            if entry.get('status') != STEPS[kind] or entry.get('expected') != STEPS[kind] or entry.get('valid') is not True:
                errors.append(f'request failed/ambiguous/invalid: {identifier}')
        elif kind == 'chat_open':
            if entry['session'] in opened:
                errors.append('duplicate chat session')
            opened[entry['session']] = entry
        elif kind == 'chat_end':
            if entry['session'] in ended or entry.get('valid') is not True:
                errors.append('invalid/duplicate chat end')
            ended[entry['session']] = entry
        elif kind == 'chat_send':
            if entry['key'] in sends:
                errors.append('duplicate chat send')
            sends[entry['key']] = entry
        elif kind == 'chat_receive':
            received[(entry['key'], entry['receiver'], entry.get('user'), entry.get('room'), entry.get('id'))] += 1
        elif kind == 'chat_error':
            errors.append(f'chat error: {entry.get("reason")}')
        else:
            errors.append(f'unexpected ledger event: {kind}')

    config = configs[0] if len(configs) == 1 else {}
    if len(configs) != 1 or config.get('schema') != 4 or set(config.get('steps', [])) != set(STEPS):
        errors.append('missing/duplicate/incompatible config; fresh run required')
    sessions = config.get('sessions', 0)
    if not isinstance(sessions, int) or not 1 <= sessions <= 10:
        errors.append('invalid planned sessions')
        sessions = 0
    # 총수뿐 아니라 각 세션의 필수 요청이 모두 실행됐는지 확인한다.
    wanted_requests = {(kind, f'mg-{run}-{seq}') for seq in range(sessions) for kind in STEPS}
    if not set(requests) <= wanted_requests or (not partial and set(requests) != wanted_requests):
        errors.append('incomplete API session coverage')
    # 수동 종료라도 보낸 요청의 응답이 없으면 실패로 판정한다.
    if starts != set(requests):
        errors.append('request started without matching response')
    planned_keys = {f'mg-{run}-{seq}' for seq in range(sessions)}
    if not session_starts <= planned_keys or not session_ends <= session_starts or not requests:
        errors.append('invalid/missing API sessions')
    if any(key not in session_starts for _, key in requests):
        errors.append('request without session start')
    for key in session_starts:
        executed = [step for step in STEPS if (step, key) in requests]
        complete = len(executed) == len(STEPS)
        if executed != list(STEPS)[:len(executed)]:
            errors.append('API step skipped before manual stop')
        if (key in session_ends and not complete) or (not partial and key not in session_ends):
            errors.append('incomplete API session')

    metrics = json.loads(Path(summary).read_text()).get('metrics', {})
    def metric(name, field):
        return metrics.get(name, {}).get('values', {}).get(field)
    # 요청 기록과 k6 집계를 대조해 부하 누락·중단을 검출한다.
    reads = config.get('reads')
    actual_reads = metric('read_requests', 'count')
    if not isinstance(reads, int) or reads < 1 or not isinstance(actual_reads, (int, float)) or not 0 < actual_reads <= reads or (not partial and actual_reads != reads):
        errors.append('continuous reads do not match plan')
    for name in ('dropped_iterations', 'interrupted_iterations', 'chat_errors'):
        if name == 'chat_errors' and metric(name, 'count') is None:
            errors.append('chat error metric missing')
        elif name == 'interrupted_iterations' and partial:
            continue
        elif (metric(name, 'count') or 0) != 0:
            errors.append(f'{name} is not zero')
    for name, expected in (('checks', 1), ('http_req_failed', 0)):
        if metric(name, 'rate') != expected:
            errors.append(f'{name} did not pass')
    for name, expected in (('api_requests', len(requests)), ('api_sessions_completed', len(session_ends)),
                           ('chat_messages_sent', len(sends)), ('chat_sessions_started', len(opened)),
                           ('chat_sessions_completed', len(ended))):
        if metric(name, 'count') != expected:
            errors.append(f'{name} does not match ledger/plan')
    if not sends or len(opened) < config.get('chat_pairs', 1) or not set(ended) <= set(opened) or (not partial and set(opened) != set(ended)):
        errors.append('missing/incomplete chat sessions')
    for session, entry in opened.items():
        count = sum(e['session'] == session for e in sends.values())
        senders = {e['user'] for e in sends.values() if e['session'] == session}
        if session in ended and (not count or senders != set(entry.get('users', [])) or ended[session].get('sent') != count):
            errors.append(f'incomplete chat sends: {session}')
    # 메시지마다 두 사용자에게 정확히 한 번씩 도착해야 한다.
    wanted_receive = set()
    for key, entry in sends.items():
        opening = opened.get(entry['session'], {})
        users = entry.get('receivers', [])
        if len(set(users)) != 2 or set(users) != set(opening.get('users', [])) or entry['room'] != opening.get('room') or entry['user'] not in users:
            errors.append(f'invalid chat participants: {key}')
        for user in users:
            wanted_receive.add((key, user, entry['user'], entry['room']))
    actual_receive = Counter()
    message_ids = {}
    for (key, user, sender, room, message_id), count in received.items():
        actual_receive[(key, user, sender, room)] += count
        if not isinstance(message_id, int) or message_id < 1:
            errors.append(f'invalid delivered message id: {key}')
        message_ids.setdefault(key, set()).add(str(message_id))
    if actual_receive != Counter({key: 1 for key in wanted_receive}):
        errors.append('chat receiver missing, duplicated or mismatched')
    if any(len(ids) != 1 for ids in message_ids.values()):
        errors.append('chat recipients received different DB message ids')

    # 요청 내용으로 기대 DB 값을 만든다. 두 DB의 결과만 서로 비교하지 않는다.
    expected_rows = {}
    for (kind, key), entry in requests.items():
        user = str(entry['user'])
        if kind == 'group':
            expected_rows[('group', key, user)] = ({'content': key}, None)
        elif kind == 'search':
            expected_rows[('search', key, user)] = ({'keyword': key}, None)
        elif kind == 'item_update':
            item = entry['item']
            expected_rows[('item_update', key, user)] = ({'content': key, 'quantity': entry['quantity'], 'state': 'AVAILABLE',
                'deleted': 0, 'group': entry['group'], 'group_count': 1, 'images': [item * 2 - 1, item * 2], 'views': int(('item_updated', key) in requests)}, str(item))
        elif kind == 'item_delete':
            expected_rows[('item_delete', str(entry['item']), user)] = ({'deleted': 1}, str(entry['item']))
        elif kind == 'exchange_create':
            result = entry.get('result') or {}
            canceled = ('exchange_cancel', key) in requests
            expected_rows[('exchange', str(entry['target']), user)] = ({'quantity': 1, 'status': 'CANCELED' if canceled else 'PENDING',
                'group': entry['group'], 'offered': entry['offered'], 'offered_quantity': 1, 'offered_count': 1,
                'room': result.get('room'), 'room_status': 'CLOSED' if canceled else 'OPEN', 'members': [entry['user'], entry['user'] + 1], 'views': 1},
                str(result.get('id')))
    for key, entry in sends.items():
        ids = message_ids.get(key, set())
        expected_rows[('chat', key, str(entry['user']))] = ({'room': entry['room']}, next(iter(ids)) if len(ids) == 1 else None)

    # 각 DB를 기대값과 먼저 대조한 뒤, 두 DB의 내용·ID도 비교한다.
    snapshots = []
    for name, path in (('source', source), ('rds', rds)):
        rows = []
        for line in Path(path).read_text().splitlines():
            row = line.split('\t')
            if len(row) != 5:
                errors.append(f'{name}: malformed export row')
                continue
            identifier = tuple(row[:3])
            if identifier not in expected_rows and not row[1].startswith(f'mg-{run}-'):
                continue
            try:
                payload = json.loads(row[3])
                for field in ('images', 'members'):
                    if isinstance(payload.get(field), list):
                        payload[field].sort()
            except (ValueError, AttributeError):
                errors.append(f'{name}: invalid export JSON')
                continue
            rows.append((identifier, json.dumps(payload, sort_keys=True), row[4]))
            expected_payload, expected_id = expected_rows.get(identifier, (None, None))
            if payload != expected_payload or (expected_id is not None and row[4] != expected_id):
                errors.append(f'{name}: unexpected state or id: {identifier}')
        counts = Counter(row[0] for row in rows)
        if counts != Counter({key: 1 for key in expected_rows}):
            errors.append(f'{name}: missing/duplicated/unexpected DB writes')
        snapshots.append(Counter(rows))
    if snapshots[0] != snapshots[1]:
        errors.append('source and RDS rows/IDs differ')
    return {'passed': not errors, 'mode': 'manual_stop' if partial else 'full_duration',
            'api_sessions_completed': len(session_ends), 'read_requests': actual_reads,
            'api_requests': len(requests), 'chat_sent': len(sends),
            'coverage': dict(Counter(kind for kind, _ in requests)),
            'excluded': config.get('excluded', []), 'errors': errors}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    for option in ('ledger', 'source', 'rds', 'summary', 'run'):
        parser.add_argument(f'--{option}', required=True)
    result = verify(**vars(parser.parse_args()))
    print(json.dumps(result, ensure_ascii=False, indent=2))
    sys.exit(0 if result['passed'] else 1)
