import importlib.util
import copy
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('cutover_verify', Path(__file__).with_name('verify.py'))
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)


class CoverageTest(unittest.TestCase):
    def test_runner_does_not_start_requests_past_prepared_counts(self):
        result = subprocess.run(['node', '-e', r'''
const fs=require('fs'),vm=require('vm'),assert=require('assert');
const logs=[],calls=[],exec={scenario:{iterationInTest:0}};
const context={__ENV:{RUN_ID:'bound',BASE_URL:'https://staging.bakkucca.com/api',JWT_SECRET:'x'.repeat(32),MINUTES:'6',WRITE_SESSIONS:'6',
 FIXTURE_JSON:JSON.stringify({sessions:Array(6).fill({user:1,groupCreator:2}),update:{user:1,item:2,group:3,images:[4,5]},read:{user:1,group:3}})},
 exec,http:{expectedStatuses(){},request(){calls.push(1);throw Error('HTTP_STUB');}},Counter:class{add(){}},
 crypto:{hmac(){return 'stub';}},encoding:{b64encode(v){return v;}},check(){},chatPair(){},console:{log(v){logs.push(v);}}};
const source=fs.readFileSync('loadtest/cutover/workload.js','utf8').replace(/^import .*;\n/gm,'').replace(/export /g,'');
vm.runInNewContext(source,context);
for(const [name,limit] of [['apiTraffic',6],['updateTraffic',60],['readTraffic',360]]){
 for(const seq of [limit,limit+1]){exec.scenario.iterationInTest=seq;context[name]();}
 assert.equal(calls.length,0);assert.equal(logs.length,0);
 exec.scenario.iterationInTest=limit-1;
 assert.throws(()=>context[name](),/HTTP_STUB/);assert.equal(calls.length,1);
 calls.length=0;logs.length=0;
}
'''], cwd=Path(__file__).resolve().parents[2], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_actual_request_records_keep_plan_response_and_db_failures_separate(self):
        run, key = 'bound', 'mg-bound-0'
        steps = {k: v for k, v in verify.workload.STEPS.items() if k not in ('item_update', 'item_updated')}
        rows = [dict(run=run, kind='config', schema=4, sessions=1, updates=1, reads=2,
                     steps=list(steps), chat_pairs=0), dict(run=run, kind='api_session_start', key=key)]
        for index, (kind, status) in enumerate(steps.items()):
            started = 100 + index * 10
            rows += [dict(run=run, kind='request_start', step=kind, key=key, started=started),
                     dict(run=run, kind=kind, key=key, user=1, started=started, ended=started+5,
                          status=status, expected=status, valid=True, item=5, group=4, offered=3, owner=2,
                          result={'id': 7, 'room': 8})]
        rows += [dict(run=run, kind='api_session_end', key=key),
                 dict(run=run, kind='request_start', step='item_update', key='mg-bound-update-0', started=300),
                 dict(run=run, kind='item_update', key='mg-bound-update-0', user=1, item=10, quantity=7,
                      group=4, images=[11,12], started=300, ended=305, status=204, expected=204, valid=True)]
        for i in range(2):
            rows += [dict(run=run, kind='read_start', key=f'read-{i}', started=400+i*10),
                     dict(run=run, kind='read_end', key=f'read-{i}', started=400+i*10,
                          ended=405+i*10, status=200, valid=True)]
        db = [('group',key,'1',{'content':key},'1'), ('search',key,'1',{'keyword':key},'2'),
              ('item_delete','5','1',{'deleted':1},'5'),
              ('exchange','7','1',{'quantity':1,'status':'CANCELED','group':4,'offered':3,'offered_quantity':1,
                                    'offered_count':1,'room':8,'room_status':'CLOSED','members':[1,2],'views':1},'7'),
              ('item_update','mg-bound-update-0','1',{'content':'mg-bound-update-0','quantity':7,'state':'AVAILABLE',
                   'deleted':0,'group':4,'group_count':1,'images':[11,12],'views':0},'10')]
        metrics = {name:{'values':values} for name, values in {
            'read_requests':{'count':2},'api_requests':{'count':12},'api_sessions_completed':{'count':1},
            'checks':{'rate':1},'http_req_failed':{'rate':0}}.items()}
        with tempfile.TemporaryDirectory() as folder:
            p=Path(folder); ledger=p/'ledger'; summary=p/'summary'; snapshot=p/'db'
            for case in ['ok','planned_close','unexpected_close','extra_read','missing_read','missing_update','bad_response','bad_db']:
                with self.subTest(case=case):
                    entries, stats, stored = copy.deepcopy(rows), copy.deepcopy(metrics), copy.deepcopy(db)
                    if case in ('planned_close', 'unexpected_close'):
                        entries.append(dict(run=run, kind='chat_disconnected', planned=case=='planned_close'))
                    if case=='extra_read':
                        entries += [dict(run=run,kind='read_start',key='read-2',started=500),
                                    dict(run=run,kind='read_end',key='read-2',started=500,ended=505,status=200,valid=True)]
                        stats['read_requests']['values']['count']=3
                    if case=='missing_read':
                        entries=[e for e in entries if not (e['kind']=='read_end' and e['key']=='read-1')]
                        stats['read_requests']['values']['count']=1
                    if case=='missing_update':
                        entries=[e for e in entries if e['kind']!='item_update']
                        stats['api_requests']['values']['count']=11
                    if case=='bad_response':
                        next(e for e in entries if e['kind']=='read_end').update(status=500,valid=False)
                        stats['http_req_failed']['values']['rate']=0.1
                    if case=='bad_db': stored[-1][3]['quantity']=999
                    ledger.write_text('\n'.join(json.dumps(e) for e in entries)); summary.write_text(json.dumps({'metrics':stats}))
                    snapshot.write_text('\n'.join('\t'.join([a,b,c,json.dumps(d),e]) for a,b,c,d,e in stored))
                    result=verify.workload.verify(str(ledger),str(snapshot),str(snapshot),str(summary),run)
                    self.assertEqual(result['passed'],case in ('ok', 'planned_close'),result['errors'])
                    if case=='extra_read':
                        self.assertTrue(result['plan_differences']); self.assertEqual(result['response_errors'],[])
                    if case in ('missing_read','missing_update'):
                        self.assertTrue(result['response_errors']); self.assertEqual(result['plan_differences'],[])
                        self.assertEqual(result['read_totals' if case=='missing_read' else 'update_totals']['unanswered'],1)
                    if case=='bad_response': self.assertTrue(result['response_errors'])
                    if case=='bad_db': self.assertTrue(result['db_errors'])

    def fixture(self):
        phases = [dict(phase=name, at=at) for name, at in zip(verify.PHASES, [10000, 20000, 40000, 50000])]
        rows = [dict(kind='cutover_config', long_request_min_ms=3000, long_request_path='/probe')]
        for session, times in [('persistent', [100, 200]), ('split', [300, 25000]), ('new-0', [26000, 27000]), ('new-1', [55000, 56000])]:
            rows += [dict(kind='chat_connected', session=session, at=at) for at in times]
        rows += [dict(kind='chat_end', session='persistent', at=60000)]
        for key, start, end in [('a', 8000, 12000), ('b', 38000, 42000)]:
            rows += [dict(kind='long_start', key=key, started=start),
                     dict(kind='long_end', key=key, started=start, ended=end, status=200),
                     dict(kind='exchange_create', started=start, ended=end, status=201)]
        for at in [1000, 30000, 55000]:
            rows += [dict(kind=kind, key=str(at), exchange=at, result={'id': at},
                          started=at + index * 20, ended=at + index * 20 + 10, valid=True)
                     for index, kind in enumerate(['exchange_create', 'exchange_detail', 'exchange_cancel'])]
            rows += [dict(kind='read_start', key=str(at), started=at),
                     dict(kind='read_end', key=str(at), started=at, ended=at+10, status=200, valid=True)]
        return rows, phases

    def test_all_boundaries_covered(self):
        self.assertEqual(verify.coverage(*self.fixture())[1], [])

    def test_wrong_exchange_id_and_no_rollback_chat_fail(self):
        rows, phases = self.fixture()
        for row in rows:
            if row['kind'] == 'exchange_cancel':
                row['exchange'] = -1
        rows = [r for r in rows if r.get('session') != 'new-1']
        result, errors = verify.coverage(rows, phases)
        self.assertFalse(result['v2_exchange_flow'])
        self.assertFalse(result['new_rollback_chat'])
        self.assertTrue(errors)

    def test_http_only_excludes_chat_but_detects_missing_http_response(self):
        rows, phases = self.fixture()
        rows[0]['chat_enabled'] = False
        rows = [r for r in rows if not r['kind'].startswith('chat_')]
        result, errors = verify.coverage(rows, phases)
        self.assertEqual(errors, [])
        self.assertNotIn('mixed_v1_v2_chat', result)
        rows = [r for r in rows if not (r['kind'] == 'read_end' and r['key'] == '30000')]
        self.assertTrue(verify.coverage(rows, phases)[1])

    def test_optional_inflight_is_reported_without_failing_baseline(self):
        rows, phases = self.fixture()
        rows[0]['long_request_path'] = ''
        rows = [r for r in rows if r['kind'] not in ('long_start', 'long_end')
                and not (r['kind'] == 'exchange_create' and r.get('valid') is not True)]
        result, errors = verify.coverage(rows, phases)
        self.assertEqual(errors, [])
        self.assertFalse(result['switch_long_inflight'])
        self.assertFalse(result['rollback_exchange_inflight'])

    def test_fast_request_is_not_long_request_proof(self):
        rows, phases = self.fixture()
        # 모든 긴 응답을 최소 시간보다 짧게 변경한다.
        for row in rows:
            if row['kind'] == 'long_end':
                row['started'] = row['ended'] - 1
        self.assertTrue(verify.coverage(rows, phases)[1])

    def test_no_switch_or_no_mixed_connection_fails(self):
        rows, phases = self.fixture()
        self.assertTrue(verify.coverage(rows, phases[:-1])[1])
        rows = [r for r in rows if not (r['kind'] == 'chat_connected' and r['session'] == 'split')]
        self.assertFalse(verify.coverage(rows, phases)[0]['mixed_v1_v2_chat'])

    def test_unanswered_request_fails(self):
        rows, phases = self.fixture()
        rows.append(dict(kind='long_start', key='unanswered', started=9000))
        self.assertIn('긴 요청 실패 또는 응답 누락', verify.coverage(rows, phases)[1])


if __name__ == '__main__':
    unittest.main()
