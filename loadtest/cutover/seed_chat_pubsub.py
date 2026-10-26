#!/usr/bin/env python3
"""채팅 전용 INSERT SQL/fixture 생성. DB 접속하지 않는다. mysql --force 사용 금지."""
import argparse
import json
from pathlib import Path
from seed import HOST


def build(base=8400000):
    if base < 8000000 or base % 1000:
        raise ValueError('base: 8000000 이상 1000 배수')
    prefix = f'pubsub-{base}'
    pairs = [dict(name=name, room=base+n+1, users=[base+2*n+1,base+2*n+2])
             for n,name in enumerate(['split','service','reconnect'])]
    fixture = dict(namespace=prefix, pairs=pairs)
    sql=['CREATE TEMPORARY TABLE pubsub_guard (ok INT NOT NULL CHECK(ok=1));','START TRANSACTION;',
         f"INSERT INTO pubsub_guard VALUES(IF(DATABASE()='market' AND COALESCE(@cutover_endpoint,'')='{HOST}',1,0));",
         'SET @now=NOW(6);']
    for t,k in [('users','user_id'),('groups','group_id'),('items','item_id'),('exchange_requests','exchange_request_id'),('chat_rooms','chat_room_id')]:
        sql.append(f'INSERT INTO pubsub_guard SELECT IF(COUNT(*)=0,1,0) FROM `{t}` WHERE {k} BETWEEN {base} AND {base+999};')
    def lit(v):
        return str(v) if isinstance(v,(int,float)) else "'"+v.replace("'","''")+"'"
    def insert(t,cols,rows,times=2):
        suffix=[[],['created_at'],['created_at','updated_at']][times]
        sql.append(f'INSERT INTO `{t}` ({cols}'+(' ,'+','.join(suffix) if suffix else '')+') VALUES\n'+',\n'.join(
            '('+','.join(map(lit,row))+(',@now'*times)+')' for row in rows)+';')
    insert('users','user_id,nickname,user_role,user_status',[(base+i,f'{prefix}-u{i}','USER','ACTIVE') for i in range(1,7)])
    insert('groups','group_id,group_name,road_address,group_longitude,group_latitude,group_content',[(base+1,prefix,'서울특별시 시험로 1',127,37.5,prefix)])
    insert('group_members','group_id,user_id,location_verified_at,user_status',[(base+1,base+i,'SEED_NOW','ACTIVE') for i in range(1,7)])
    insert('items','item_id,user_id,quantity,item_state,title,content,min_unit_price,max_unit_price,unit_price,exchange_urgency_score,value_gap_tolerance_score,price_status',
           [(base+i,base+i,9,'AVAILABLE',f'{prefix}-i{i}',prefix,1000,3000,2000,.5,.5,'SUCCESS') for i in range(1,7)])
    insert('group_items','group_id,item_id',[(base+1,base+i) for i in range(1,7)])
    insert('item_stats','item_id,view_count,like_count',[(base+i,0,0) for i in range(1,7)],1)
    insert('exchange_requests','exchange_request_id,requester_id,item_id,requested_quantity,requested_status,group_id',
           [(p['room'],p['users'][0],p['users'][1],1,'PENDING',base+1) for p in pairs])
    insert('exchange_request_offered_items','exchange_request_id,item_id,quantity',[(p['room'],p['users'][0],1) for p in pairs],0)
    insert('chat_rooms','chat_room_id,exchange_request_id,chat_room_status,last_message_at',[(p['room'],p['room'],'OPEN','SEED_NOW') for p in pairs],1)
    insert('chat_members','chat_room_id,user_id,member_role',[(p['room'],u,role) for p in pairs for u,role in zip(p['users'],['REQUESTER','OWNER'])],1)
    sql.append('COMMIT;')
    return fixture,('\n'.join(sql)+'\n').replace("'SEED_NOW'",'@now')


if __name__ == '__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--base',type=int,default=8400000)
    p.add_argument('--sql',type=Path,required=True)
    p.add_argument('--fixture',type=Path,required=True)
    a=p.parse_args(); f,s=build(a.base)
    with a.sql.open('x') as out: out.write(s)
    with a.fixture.open('x') as out: out.write(json.dumps(f,indent=2)+'\n')
