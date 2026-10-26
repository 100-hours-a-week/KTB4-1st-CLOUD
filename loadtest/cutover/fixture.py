#!/usr/bin/env python3
"""DB를 변경하지 않고 별도 시험 fixture 입력의 형식과 중복을 검사한다."""
import json
import os
import sys
from pathlib import Path


def validate(f):
    def positive(v):
        return type(v) is int and v > 0
    sessions = f.get('sessions', [])
    if not 1 <= len(sessions) <= 10:
        raise ValueError('sessions는 별도로 준비한 1~10개 슬롯이어야 합니다')
    targets, offered, deleted, creators = [], [], [], []
    for row in sessions:
        if not all(positive(row.get(k)) for k in ['user', 'owner', 'group', 'offered', 'target', 'deleted', 'deleteOwner', 'groupCreator']):
            raise ValueError('세션의 모든 ID는 양의 정수여야 합니다')
        if row['user'] == row['owner'] or len({row['offered'], row['target'], row['deleted']}) != 3:
            raise ValueError('교환 참여자와 물품 슬롯을 분리하세요')
        for values, key in [(targets, 'target'), (offered, 'offered'), (deleted, 'deleted'), (creators, 'groupCreator')]:
            values.append(row[key])
    if any(len(set(values)) != len(values) for values in [targets, offered, deleted, creators]):
        raise ValueError('세션 사이의 교환·삭제 물품과 그룹 생성 사용자를 분리하세요')
    update, read = f.get('update', {}), f.get('read', {})
    if not all(positive(update.get(k)) for k in ['user', 'item', 'group']) or not all(positive(read.get(k)) for k in ['user', 'group']):
        raise ValueError('update(user,item,group), read(user,group)가 필요합니다')
    images = update.get('images', [])
    if len(images) != 2 or len(set(images)) != 2 or not all(positive(i) for i in images):
        raise ValueError('수정 물품의 실제 image ID 두 개가 필요합니다')
    if len(set(targets + offered + deleted + [update['item']])) != len(targets + offered + deleted) + 1:
        raise ValueError('교환·삭제·수정 물품을 모두 분리하세요')
    if os.environ.get('CHAT_ENABLED', 'false') != 'true':
        return f
    rooms, users = [], []
    for key in ['persistent', 'split', 'new']:
        row = f.get('chat', {}).get(key, {})
        participants = row.get('users', [])
        if not positive(row.get('room')) or len(participants) != 2 or len(set(participants)) != 2 or not all(positive(u) for u in participants):
            raise ValueError('chat 각 항목에 room과 users 두 개가 필요합니다')
        rooms.append(row['room'])
        users.extend(participants)
    if len(set(rooms)) != 3 or len(set(users)) != 6:
        raise ValueError('채팅 시나리오의 방과 사용자를 분리하세요')
    return f


if __name__ == '__main__':
    try:
        print(json.dumps(validate(json.loads(Path(sys.argv[1]).read_text()))))
    except (ValueError, KeyError, TypeError, IndexError) as error:
        sys.exit(str(error))
