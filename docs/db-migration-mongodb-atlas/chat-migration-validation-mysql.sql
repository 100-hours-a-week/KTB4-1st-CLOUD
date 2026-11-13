-- 역할: MySQL 원본에서 한 시점의 message_id 상한(워터마크)과 그 이하 메시지를 내보냅니다.
-- 컷오버 전 실행은 기존 이관 데이터 검증용, 컷오버 후 실행은 전환 중 생성된 메시지 검증용입니다.
-- 각 실행 결과를 별도 파일로 보관하고 같은 워터마크를 Atlas 조회와 비교에 사용하세요.
-- 실행 예: mysql --defaults-extra-file="./.my.cnf" --batch --raw --skip-column-names 원본_DB명 < chat-migration-validation-mysql.sql > mysql-export.jsonl

-- 실행 스크립트가 넘긴 워터마크를 사용합니다. 직접 실행할 때는 현재 최대 ID를 자동 사용합니다.
SET @watermark_message_id = COALESCE(
    @watermark_message_id,
    (SELECT MAX(message_id) FROM chat_messages)
);

-- 원본 메시지 건수와 message_id 범위
SELECT COUNT(*) AS message_count,
       MIN(message_id) AS min_message_id,
       MAX(message_id) AS max_message_id,
       MIN(created_at) AS first_created_at,
       MAX(created_at) AS last_created_at
FROM chat_messages;

-- 확정된 워터마크입니다.
-- message_id는 증가하는 기본 키이므로 이 상한 이하의 원본 메시지 집합은 이후 쓰기에 영향받지 않습니다.
SELECT @watermark_message_id AS watermark_message_id;

-- 워터마크 이하 원본 집합의 기준 건수와 ID 범위
SELECT COUNT(*) AS message_count,
       MIN(message_id) AS min_message_id,
       MAX(message_id) AS max_message_id
FROM chat_messages
WHERE @watermark_message_id IS NOT NULL AND message_id <= @watermark_message_id;

-- ID별 내용은 Atlas 결과와 대조할 수 있도록 내보내기
SELECT JSON_OBJECT(
         'message_id', message_id,
         'chat_room_id', chat_room_id,
         'user_id', user_id,
         'content', content,
         'message_type', message_type,
         'system_event_type', system_event_type,
         'message_object_id', message_object_id,
         'created_at', DATE_FORMAT(created_at, '%Y-%m-%dT%H:%i:%s.%f')
       ) AS message_json
FROM chat_messages
WHERE @watermark_message_id IS NOT NULL AND message_id <= @watermark_message_id
ORDER BY message_id;

-- 방·사용자별 메시지 수
SELECT chat_room_id, user_id, COUNT(*) AS message_count,
       MIN(message_id) AS min_message_id, MAX(message_id) AS max_message_id
FROM chat_messages
GROUP BY chat_room_id, user_id
ORDER BY chat_room_id, user_id;

-- 채팅방과 교환 요청 연결, 삭제 여부, 메시지 수
SELECT r.chat_room_id, r.exchange_request_id, r.chat_room_status,
       r.deleted_at, COUNT(m.message_id) AS message_count
FROM chat_rooms r
LEFT JOIN chat_messages m ON m.chat_room_id = r.chat_room_id
GROUP BY r.chat_room_id, r.exchange_request_id, r.chat_room_status, r.deleted_at
ORDER BY r.chat_room_id;

-- 원본 내 메시지의 채팅방/사용자 참조 누락 (결과가 없어야 함)
SELECT m.message_id, m.chat_room_id, m.user_id
FROM chat_messages m
LEFT JOIN chat_rooms r ON r.chat_room_id = m.chat_room_id
LEFT JOIN users u ON u.user_id = m.user_id
WHERE r.chat_room_id IS NULL OR (m.user_id IS NOT NULL AND u.user_id IS NULL);


