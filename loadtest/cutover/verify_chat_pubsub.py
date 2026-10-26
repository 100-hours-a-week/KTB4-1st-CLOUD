#!/usr/bin/env python3
"""연속 연결 원장과 DB 메시지를 대조한다. CF 전환/실제 FE 화면 검증은 별도다."""
import argparse
import collections
import json
import re
from pathlib import Path


def verify(rows, db, summary):
    errors=[]
    sends={}; receives=collections.defaultdict(list)
    starts=[r for r in rows if r.get('kind')=='pubsub_start']
    if len(starts)!=1: errors.append('pubsub_start_count')
    for r in rows:
        kind=r.get('kind')
        if kind=='chat_error': errors.append(r.get('reason','chat_error'))
        if kind=='chat_disconnected' and not r.get('planned'): errors.append('unexpected_close')
        if kind=='chat_send':
            if r['key'] in sends: errors.append('duplicate_send_key')
            sends[r['key']]=r
        if kind=='chat_receive': receives[r['key']].append(r)
    db_by=collections.defaultdict(list); ids=[]
    for row in db:
        db_by[row['key']].append(row); ids.append(row['id'])
    if len(ids)!=len(set(ids)): errors.append('duplicate_db_message_id')
    connected=[r for r in rows if r.get('kind')=='chat_connected']
    for session in ['split','service']:
        opening=[r for r in rows if r.get('kind')=='chat_open' and r.get('session')==session]
        endings=[r for r in rows if r.get('kind')=='chat_end' and r.get('session')==session]
        if len(opening)!=1 or len(endings)!=1 or not endings[0].get('valid'): errors.append(session+'_not_complete')
        cs=[r for r in connected if r.get('session')==session]
        if len(cs)!=2 or len({r['user'] for r in cs})!=2: errors.append(session+'_connect_count')
        if session=='split' and {r.get('url') for r in cs}!={'wss://v1-origin.staging.bakkucca.com/ws','wss://origin.staging.bakkucca.com/ws'}:
            errors.append('split_urls')
        if starts and endings and endings[0]['at']-starts[0]['at'] < (starts[0]['duration']-2)*1000:
            errors.append(session+'_duration_short')
    for key,s in sends.items():
        got=receives[key]; stored=db_by[key]
        if collections.Counter(r['receiver'] for r in got)!=collections.Counter(s['receivers']): errors.append(key+':missing_or_duplicate_delivery')
        if len(stored)!=1: errors.append(key+':db_missing_or_duplicate'); continue
        d=stored[0]
        if d['room']!=s['room'] or d['user']!=s['user']: errors.append(key+':db_metadata')
        if any(r.get('id')!=d['id'] or r.get('room')!=d['room'] or r.get('user')!=d['user'] for r in got): errors.append(key+':receive_metadata')
    if set(db_by)!=set(sends): errors.append('db_key_set')
    if set(receives)-set(sends): errors.append('unknown_receive')
    if not sends: errors.append('no_messages')
    for name,metric in summary.get('metrics',{}).items():
        if any(not t.get('ok') for t in metric.get('thresholds',{}).values()): errors.append('threshold:'+name)
    if not summary.get('metrics'): errors.append('no_summary')
    return dict(pass_continuous=not errors, sent=len(sends), received=sum(map(len,receives.values())), db=len(db), errors=errors,
                limits=['CF phase overlap and origin access logs require separate evidence','reconnect REST recovery untested','frontend rendering untested'])


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--run',required=True);p.add_argument('--ledger',type=Path);p.add_argument('--db',type=Path);p.add_argument('--summary',type=Path)
    p.add_argument('--export-sql',action='store_true');a=p.parse_args()
    if not re.fullmatch('[a-z0-9]{1,10}',a.run): p.error('invalid RUN_ID')
    if a.export_sql:
        print("SELECT message_id,chat_room_id,user_id,content FROM chat_messages WHERE content LIKE 'mg-%s-chat-%%' ORDER BY message_id;"%a.run)
    else:
        if not all([a.ledger,a.db,a.summary]): p.error('ledger,db,summary required')
        rows=[json.loads(line) for line in a.ledger.read_text().splitlines() if line.strip()]
        rows=[r for r in rows if r.get('run')==a.run]
        db=[]
        for line in a.db.read_text().splitlines():
            mid,room,user,key=line.split('\t',3);db.append(dict(id=int(mid),room=int(room),user=int(user),key=key))
        result=verify(rows,db,json.loads(a.summary.read_text()));print(json.dumps(result,indent=2));raise SystemExit(0 if result['pass_continuous'] else 1)
