#!/usr/bin/env python3
"""빈 마이그레이션 시험 DB에 테이블별 최대 50건의 초기 데이터를 생성한다."""
import sys


def literal(value):
    if isinstance(value, (int, float)):
        return str(value)
    return "'" + str(value).replace("'", "''") + "'"


def insert(table, columns, rows):
    assert 0 < len(rows) <= 50, (table, len(rows))
    sys.stdout.write(f'-- {table}: {len(rows)} rows\n')
    values = ["(" + ", ".join(map(literal, row)) + ", @now, @now)" for row in rows]
    sys.stdout.write(f'INSERT INTO `{table}` ({columns}, created_at, updated_at) VALUES\n' + ',\n'.join(values) + ';\n')


def seed():
    print("CREATE USER IF NOT EXISTS 'exporter'@'%' IDENTIFIED BY 'loadtest-exporter' WITH MAX_USER_CONNECTIONS 2;")
    print("GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'exporter'@'%';")
    print("SET @now = NOW(6);\nSTART TRANSACTION;")
    insert('groups', 'group_id, group_name, road_address, group_longitude, group_latitude, group_content',
           [(n, f'loadtest-group-{n}', '서울특별시 테스트로 1', 127, 37.5, '마이그레이션 시험') for n in range(1, 51)])
    users = [*range(1, 31), *range(1801, 1811), *range(2001, 2011)]
    insert('users', 'user_id, nickname, user_role, user_status',
           [(n, f'loadtest-user-{n}', 'USER', 'ACTIVE') for n in users])
    insert('group_members', 'group_id, user_id, location_verified_at, user_status',
           [(1 if n < 1800 else 19, n, '2026-01-01 00:00:00', 'ACTIVE') for n in users if n < 2001])
    items = {}
    edits, offers, targets = [], [], []
    for seq in range(10):
        user = 1 + 2 * seq
        edited, offered, target = (user - 1) * 10 + 2, (user - 1) * 10 + 6, user * 10 + 6
        edits.append(edited); offers.append(offered); targets.append(target)
        for item, owner in [(edited, user), (offered, user), (target, user + 1), (20001 + seq, 1 + seq // 2)]:
            items[item] = owner
    for room in range(901, 906):
        items[(2 * room - 2) * 10 + 1] = 2 * room - 1
        items[(2 * room - 1) * 10 + 1] = 2 * room
    insert('items', 'item_id, user_id, quantity, item_state, title, content, min_unit_price, max_unit_price, unit_price, exchange_urgency_score, value_gap_tolerance_score',
           [(item, owner, 99, 'AVAILABLE', f'시험 물건 {item}', '마이그레이션 시험', 1000, 3000, 2000, .5, .5) for item, owner in items.items()])
    insert('group_items', 'group_id, item_id',
           [(1 if owner < 1800 else 19, item) for item, owner in items.items() if item < 20001])
    # 아래 테이블에는 updated_at이 없으므로 스키마에 맞춰 별도 출력한다.
    def created(table, columns, rows):
        assert 0 < len(rows) <= 50, (table, len(rows))
        print(f'-- {table}: {len(rows)} rows')
        print(f'INSERT INTO `{table}` ({columns}, created_at) VALUES\n' + ',\n'.join(
            '(' + ', '.join(map(literal, row)) + ', @now)' for row in rows) + ';')
    created('item_stats', 'item_id, view_count, like_count', [(item, 0, 0) for item in items])
    image_items = [*edits, *offers, *targets[:5]]
    created('images', 'image_id, owner_id, item_id, object_key',
            [(2 * item - 1 + offset, items[item], item, f'items/{item}-{offset}.jpg') for item in image_items for offset in range(2)])
    insert('exchange_requests', 'exchange_request_id, requester_id, item_id, requested_quantity, requested_status, group_id',
           [(room, 2 * room - 1, (2 * room - 1) * 10 + 1, 1, 'PENDING', 19) for room in range(901, 906)])
    # 이 연결 테이블에는 타임스탬프 컬럼이 없다.
    print('INSERT INTO exchange_request_offered_items (exchange_request_id, item_id, quantity) VALUES\n' + ',\n'.join(
        f'({room}, {(2 * room - 2) * 10 + 1}, 1)' for room in range(901, 906)) + ';')
    created('chat_rooms', 'chat_room_id, exchange_request_id, chat_room_status, last_message_at',
            [(room, room, 'OPEN', '2026-01-01 00:00:00') for room in range(901, 906)])
    created('chat_members', 'chat_room_id, user_id, member_role',
            [(room, 2 * room - 1 + offset, 'REQUESTER' if offset == 0 else 'OWNER') for room in range(901, 906) for offset in range(2)])
    created('chat_messages', 'chat_room_id, user_id, content, message_type',
            [(room, 2 * room - 1 + seq % 2, f'시드 메시지 {seq}', 'TEXT') for room in range(901, 906) for seq in range(10)])
    print('COMMIT;')


if __name__ == '__main__':
    seed()
