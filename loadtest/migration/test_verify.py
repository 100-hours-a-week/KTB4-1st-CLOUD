"""전환 후 데이터 손실과 불완전한 부하를 성공으로 판정하지 않는지 검증한다."""
import copy
import json
from pathlib import Path
import tempfile
import unittest

from verify import STEPS, verify


class VerifyTest(unittest.TestCase):
    def setUp(self):
        # 정상 실행의 요청·채팅 기록과 DB 결과를 준비한다.
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.stop = None
        self.run = 'case'
        self.key = 'mg-case-0'
        self.events = [{'run': self.run, 'kind': 'config', 'schema': 4, 'sessions': 1, 'reads': 1800,
                        'steps': list(STEPS), 'chat_pairs': 1, 'excluded': ['item_create_ai']}]
        for kind, status in STEPS.items():
            entry = {'run': self.run, 'kind': kind, 'key': self.key, 'user': 2001 if kind == 'group' else 1,
                     'status': status, 'expected': status, 'valid': True}
            if kind == 'item_update':
                entry.update(item=2, quantity=7, group=1)
            elif kind == 'item_delete':
                entry.update(item=20001)
            elif kind == 'exchange_create':
                entry.update(target=16, offered=6, group=1, result={'id': 1001, 'room': 1001})
            self.events.append(entry)
        self.events.append({'run': self.run, 'kind': 'chat_open', 'session': '11-0', 'room': 901, 'users': [1801, 1802]})
        # export.sql과 같은 순서: 종류, 식별값, 사용자, 저장 내용, DB ID.
        self.rows = [
            ['group', self.key, '2001', {'content': self.key}, '121'],
            ['search', self.key, '1', {'keyword': self.key}, '1'],
            ['item_update', self.key, '1', {'content': self.key, 'quantity': 7, 'state': 'AVAILABLE',
                'deleted': 0, 'group': 1, 'group_count': 1, 'images': [3, 4], 'views': 1}, '2'],
            ['item_delete', '20001', '1', {'deleted': 1}, '20001'],
            ['exchange', '16', '1', {'quantity': 1, 'status': 'CANCELED', 'group': 1, 'offered': 6,
                'offered_quantity': 1, 'offered_count': 1, 'room': 1001, 'room_status': 'CLOSED',
                'members': [1, 2], 'views': 1}, '1001'],
        ]
        for offset, sender in enumerate((1801, 1802)):
            key = f'mg-case-chat-11-0-{offset}'
            self.events.append({'run': self.run, 'kind': 'chat_send', 'session': '11-0', 'key': key,
                                'user': sender, 'room': 901, 'receivers': [1801, 1802]})
            for receiver in (1801, 1802):
                self.events.append({'run': self.run, 'kind': 'chat_receive', 'session': '11-0', 'key': key,
                                    'receiver': receiver, 'user': sender, 'room': 901, 'id': 5001 + offset})
            self.rows.append(['chat', key, str(sender), {'room': 901}, str(5001 + offset)])
        self.events.append({'run': self.run, 'kind': 'chat_end', 'session': '11-0', 'valid': True, 'sent': 2})
        self.metrics = {'checks': {'values': {'rate': 1}}, 'http_req_failed': {'values': {'rate': 0}}}
        for name, count in [('read_requests', 1800), ('dropped_iterations', 0), ('chat_errors', 0), ('api_requests', 13),
                            ('api_sessions_completed', 1), ('chat_messages_sent', 2),
                            ('chat_sessions_started', 1), ('chat_sessions_completed', 1)]:
            self.metrics[name] = {'values': {'count': count}}

        # 요청 시작·종료 기록으로 중간 종료와 응답 누락을 구분한다.
        events = [self.events[0], {'run': self.run, 'kind': 'api_session_start', 'key': self.key}]
        for entry in self.events[1:]:
            if entry['kind'] in STEPS:
                events.append({'run': self.run, 'kind': 'request_start', 'step': entry['kind'], 'key': self.key})
            events.append(entry)
        events.append({'run': self.run, 'kind': 'api_session_end', 'key': self.key})
        self.events = events

    def check_result(self, source=None, rds=None):
        # 임시 결과 파일을 실제 검증기에 입력한다. 서버에는 접속하지 않는다.
        files = {name: self.root / name for name in ('ledger', 'source', 'rds', 'summary')}
        if self.stop is not None:
            (self.root / f'{self.run}-stop.json').write_text(json.dumps(self.stop))
        files['ledger'].write_text('\n'.join(json.dumps(e) for e in self.events))
        files['summary'].write_text(json.dumps({'metrics': self.metrics}))
        for name, rows in [('source', source if source is not None else self.rows),
                           ('rds', rds if rds is not None else self.rows)]:
            files[name].write_text('\n'.join('\t'.join([*r[:3], json.dumps(r[3]), r[4]]) for r in rows))
        return verify(**files, run=self.run)

    def manual_stop(self):
        self.stop = {'run': self.run, 'reason': 'user_interrupt', 'exit_code': 105}
        self.events[0]['sessions'] = 10
        self.metrics['read_requests']['values']['count'] = 60
        self.metrics['interrupted_iterations'] = {'values': {'count': 1}}

    def test_manual_stop_accepts_completed_work(self):
        self.manual_stop()
        self.assertTrue(self.check_result()['passed'])

    def test_short_run_without_manual_stop_fails(self):
        self.metrics['read_requests']['values']['count'] = 60
        self.assertFalse(self.check_result()['passed'])

    def test_manual_stop_keeps_unacknowledged_request_failure(self):
        self.manual_stop()
        self.events = [e for e in self.events if e['kind'] != 'group']
        self.metrics['api_requests']['values']['count'] = 12
        self.assertFalse(self.check_result()['passed'])

    def test_manual_stop_accepts_delivered_chat_before_close(self):
        self.manual_stop()
        self.events = [e for e in self.events if e['kind'] != 'chat_end']
        self.metrics['chat_sessions_completed']['values']['count'] = 0
        self.assertTrue(self.check_result()['passed'])

    def test_manual_stop_does_not_hide_chat_loss(self):
        self.manual_stop()
        self.events = [e for e in self.events if not (e['kind'] == 'chat_receive' and e['receiver'] == 1802)]
        self.assertFalse(self.check_result()['passed'])

    def test_manual_stop_before_cancel_checks_pending_exchange(self):
        self.manual_stop()
        self.events = [e for e in self.events if e['kind'] not in ('exchange_cancel', 'api_session_end')
                       and not (e['kind'] == 'request_start' and e['step'] == 'exchange_cancel')]
        self.rows[4][3].update(status='PENDING', room_status='OPEN')
        self.metrics['api_requests']['values']['count'] = 12
        self.metrics['api_sessions_completed']['values']['count'] = 0
        self.assertTrue(self.check_result()['passed'])

    def test_stop_record_for_another_run_fails(self):
        self.manual_stop()
        self.stop['run'] = 'other'
        self.assertFalse(self.check_result()['passed'])

    def test_missing_continuous_reads_fails(self):
        self.metrics['read_requests']['values']['count'] = 0
        self.assertFalse(self.check_result()['passed'])

    def test_complete_run_passes(self):
        self.assertTrue(self.check_result()['passed'])

    def test_missing_api_step_fails_even_with_matching_metric(self):
        # 요청 총수가 맞아도 필수 단계가 빠졌으면 실패해야 한다.
        self.events = [e for e in self.events if e['kind'] != 'item_deleted']
        self.metrics['api_requests']['values']['count'] = 12
        self.assertFalse(self.check_result()['passed'])

    def test_lost_update_fails_even_when_both_dbs_agree(self):
        # 두 DB가 똑같이 잘못 저장돼도 성공으로 판정하면 안 된다.
        self.rows[2][3]['quantity'] = 1000
        self.assertFalse(self.check_result()['passed'])

    def test_delete_not_persisted_fails(self):
        self.rows[3][3]['deleted'] = 0
        self.assertFalse(self.check_result()['passed'])

    def test_cancel_not_persisted_fails(self):
        self.rows[4][3]['status'] = 'PENDING'
        self.assertFalse(self.check_result()['passed'])

    def test_lost_group_or_async_view_fails(self):
        self.assertFalse(self.check_result(source=self.rows[1:], rds=self.rows[1:])['passed'])
        self.rows[2][3]['views'] = 0
        self.assertFalse(self.check_result()['passed'])

    def test_async_search_missing_in_both_dbs_fails(self):
        rows = [r for r in self.rows if r[0] != 'search']
        self.assertFalse(self.check_result(source=rows, rds=rows)['passed'])

    def test_one_recipient_missing_fails(self):
        # 송신자만 받고 상대방은 못 받은 경우를 재현한다.
        self.events = [e for e in self.events if not (e['kind'] == 'chat_receive' and e['receiver'] == 1802)]
        self.assertFalse(self.check_result()['passed'])

    def test_duplicate_chat_db_write_fails(self):
        self.rows.append(copy.deepcopy(self.rows[-1]))
        self.rows[-1][4] = '9999'
        self.assertFalse(self.check_result()['passed'])

    def test_db_id_must_match_live_delivery(self):
        # 실시간 수신 메시지와 DB 저장 행이 같은 메시지인지 확인한다.
        self.rows[-1][4] = '9999'
        self.assertFalse(self.check_result()['passed'])

    def test_two_db_ids_must_match(self):
        rds = copy.deepcopy(self.rows)
        rds[0][4] = '9999'
        self.assertFalse(self.check_result(rds=rds)['passed'])

    def test_failed_http_request_not_hidden(self):
        next(e for e in self.events if e['kind'] == 'group')['status'] = 503
        self.assertFalse(self.check_result()['passed'])

    def test_old_or_reused_run_fails(self):
        self.events[0]['schema'] = 1
        self.assertFalse(self.check_result()['passed'])
        self.events.append(copy.deepcopy(self.events[0]))
        self.assertFalse(self.check_result()['passed'])

    def test_incomplete_chat_session_fails(self):
        self.events = [e for e in self.events if e['kind'] != 'chat_end']
        self.assertFalse(self.check_result()['passed'])


if __name__ == '__main__':
    unittest.main()
