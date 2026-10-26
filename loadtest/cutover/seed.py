#!/usr/bin/env python3
"""별도 cutover fixture와 INSERT SQL만 생성한다. DB 접속/적용 기능은 없다.

mysql batch 모드에서 --force 없이 실행한다. SQL 오류 시 연결 종료로 트랜잭션을
롤백한다. 접속 wrapper가 실제 접속 host를 @cutover_endpoint에 설정해야 한다.
기존 migration 데이터와 seed는 사용하지 않는다. 선택한 namespace는 한 번만 사용한다.
"""
import argparse
import json
from pathlib import Path

HOST = 'bakkucca-v2-staging-mysql.c9acsiyqqzik.ap-northeast-2.rds.amazonaws.com'
BASE = 8300000


def build(base=BASE):
    if base < 8000000 or base % 1000:
        raise ValueError('base는 8000000 이상인 1000의 배수여야 합니다')
    prefix = f'cutover-{base}'
    sessions = []
    users, groups, members, items = [], [], [], []
    for n in range(6):
        u, owner, creator = base + n * 3 + 1, base + n * 3 + 2, base + n * 3 + 3
        group, offered, target, deleted = base + n + 1, base + n * 3 + 1, base + n * 3 + 2, base + n * 3 + 3
        sessions.append(dict(user=u, owner=owner, group=group, offered=offered,
                             target=target, deleted=deleted, deleteOwner=u, groupCreator=creator))
        users.extend([u, owner, creator]); groups.append(group)
        members.extend([(group, u), (group, owner)])
        items.extend([(offered, u, group), (target, owner, group), (deleted, u, group)])
    update_user, read_user = base + 19, base + 20
    users.extend([update_user, read_user]); groups.extend([base + 7, base + 8])
    members.extend([(base + 7, update_user), (base + 8, read_user)])
    items.extend([(base + 19, update_user, base + 7), (base + 20, read_user, base + 8)])
    fixture = dict(namespace=prefix, sessions=sessions,
                   update=dict(user=update_user, item=base + 19, group=base + 7,
                               images=[base + 37, base + 38]),
                   read=dict(user=read_user, group=base + 8))
    sql = [f'-- INSERT only: {prefix}; 20 users, 8 groups, 14 memberships, 20 items/stats, 40 images.',
           '-- Run once in mysql batch mode WITHOUT --force. Set @cutover_endpoint to the actual connection host.',
           'CREATE TEMPORARY TABLE cutover_seed_guard (ok INT NOT NULL CHECK (ok = 1));',
           'START TRANSACTION;',
           f"INSERT INTO cutover_seed_guard VALUES (IF(DATABASE()='market' AND COALESCE(@cutover_endpoint,'')='{HOST}',1,0));",
           'SET @now=NOW(6);']
    for table, key in [('users', 'user_id'), ('groups', 'group_id'), ('items', 'item_id'), ('images', 'image_id')]:
        sql.append(f'INSERT INTO cutover_seed_guard SELECT IF(COUNT(*)=0,1,0) FROM `{table}` WHERE `{key}` BETWEEN {base} AND {base+999};')
    sql.append(f"INSERT INTO cutover_seed_guard SELECT IF(COUNT(*)=0,1,0) FROM `groups` WHERE group_name LIKE '{prefix}%';")
    def lit(x):
        return str(x) if isinstance(x, (int, float)) else "'" + x.replace("'", "''") + "'"
    def insert(table, columns, rows, updated=True):
        times = ', created_at, updated_at' if updated else ', created_at'
        tail = ', @now, @now)' if updated else ', @now)'
        sql.append(f'INSERT INTO `{table}` ({columns}{times}) VALUES\n' + ',\n'.join(
            '(' + ', '.join(map(lit, row)) + tail for row in rows) + ';')
    insert('users', 'user_id,nickname,user_role,user_status', [(u, f'{prefix}-u{u-base}', 'USER', 'ACTIVE') for u in users])
    insert('groups', 'group_id,group_name,road_address,group_longitude,group_latitude,group_content',
           [(g, f'{prefix}-g{g-base}', '서울특별시 시험로 1', 127, 37.5, prefix) for g in groups])
    insert('group_members', 'group_id,user_id,location_verified_at,user_status', [(g,u,'SEED_NOW','ACTIVE') for g,u in members])
    insert('items', 'item_id,user_id,quantity,item_state,title,content,min_unit_price,max_unit_price,unit_price,exchange_urgency_score,value_gap_tolerance_score,price_status',
           [(i,u,99,'AVAILABLE',f'{prefix}-i{i-base}',prefix,1000,3000,2000,.5,.5,'SUCCESS') for i,u,g in items])
    insert('group_items', 'group_id,item_id', [(g,i) for i,u,g in items])
    insert('item_stats', 'item_id,view_count,like_count', [(i,0,0) for i,u,g in items], False)
    insert('images', 'image_id,owner_id,item_id,object_key',
           [(base + (i-base-1)*2 + k + 1,u,i,f'items/{prefix}/{i}-{k}.jpg') for i,u,g in items for k in range(2)], False)
    sql.append('COMMIT;')
    return fixture, ('\n'.join(sql) + '\n').replace("'SEED_NOW'", '@now')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', type=int, default=BASE)
    parser.add_argument('--sql', type=Path, required=True)
    parser.add_argument('--fixture', type=Path, required=True)
    args = parser.parse_args()
    fixture, sql = build(args.base)
    # Exclusive creation avoids accidentally replacing an already reviewed fixture.
    with args.sql.open('x') as out:
        out.write(sql)
    with args.fixture.open('x') as out:
        out.write(json.dumps(fixture, ensure_ascii=False, indent=2) + '\n')
