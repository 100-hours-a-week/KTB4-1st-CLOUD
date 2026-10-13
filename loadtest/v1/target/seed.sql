-- 테스트 사용자·그룹·물건·교환·채팅 데이터를 생성한다.
SET SESSION cte_max_recursion_depth = 100000;
SET @now = NOW(6);

-- MySQL 지표 조회 계정을 생성한다.
CREATE USER IF NOT EXISTS 'exporter'@'%' IDENTIFIED BY 'loadtest-exporter' WITH MAX_USER_CONNECTIONS 2;
GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'exporter'@'%';

INSERT INTO `groups` (group_id, group_name, active_group_name, road_address, group_longitude, group_latitude, group_content, created_at, updated_at)
WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 120)
SELECT n,
       IF(n <= 20, CONCAT('loadtest-group-', n), CONCAT('loadtest-join-', n)),
       IF(n <= 20, CONCAT('loadtest-group-', n), CONCAT('loadtest-join-', n)),
       '서울특별시 테스트로 1', 127.000000, 37.500000, '부하 테스트 그룹', @now, @now
FROM seq;

INSERT INTO users (user_id, nickname, user_role, user_status, created_at, updated_at)
WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 3100)
SELECT n, CONCAT('loadtest-', CASE WHEN n <= 2000 THEN 'user-' WHEN n <= 3000 THEN 'new-' ELSE 'host-' END, n),
       'USER', 'ACTIVE', @now, @now
FROM seq;

INSERT INTO group_members (group_id, user_id, location_verified_at, user_status, created_at, updated_at)
SELECT CEIL(user_id / 100), user_id, @now, 'ACTIVE', @now, @now FROM users WHERE user_id <= 2000
UNION ALL
SELECT user_id - 2980, user_id, @now, 'ACTIVE', @now, @now FROM users WHERE user_id > 3000;

INSERT INTO items (item_id, user_id, quantity, item_state, title, content, min_unit_price, max_unit_price, unit_price,
                   exchange_urgency_score, value_gap_tolerance_score, created_at, updated_at)
WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 24000)
SELECT n,
       IF(n <= 20000, CEIL(n / 10), CEIL((n - 20000) / 2)),
       IF(n <= 20000, 1000, 1),
       'AVAILABLE',
       IF(n <= 20000, CONCAT('부하 테스트 물건 ', n), CONCAT('부하 테스트 삭제용 ', n)),
       REPEAT('부하 테스트 물건 설명입니다. ', 10),
       1000, 3000, 2000, 0.50, 0.50, @now, @now
FROM seq;

INSERT INTO group_items (group_id, item_id, created_at, updated_at)
SELECT CEIL(user_id / 100), item_id, @now, @now FROM items WHERE item_id <= 20000;

INSERT INTO item_stats (item_id, view_count, like_count, created_at)
SELECT item_id, 0, 0, @now FROM items;

INSERT INTO images (image_id, owner_id, item_id, object_key, created_at)
WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 40000)
SELECT n, CEIL(CEIL(n / 2) / 10), CEIL(n / 2), CONCAT('items/', CEIL(n / 2), '-', n, '.jpg'), @now
FROM seq;

INSERT INTO exchange_requests (exchange_request_id, requester_id, item_id, requested_quantity, requested_status, created_at, updated_at, group_id)
WITH RECURSIVE seq(k) AS (SELECT 1 UNION ALL SELECT k + 1 FROM seq WHERE k < 1000)
SELECT k, 2 * k - 1, (2 * k) * 10 - 9, 1, 'PENDING', @now, @now, CEIL((2 * k - 1) / 100)
FROM seq;

INSERT INTO exchange_request_offered_items (exchange_request_id, item_id, quantity)
SELECT exchange_request_id, (requester_id - 1) * 10 + 1, 1 FROM exchange_requests;

INSERT INTO chat_rooms (chat_room_id, exchange_request_id, chat_room_status, last_message_at, created_at)
SELECT exchange_request_id, exchange_request_id, 'OPEN', @now, @now FROM exchange_requests;

INSERT INTO chat_members (chat_room_id, user_id, member_role, created_at)
SELECT chat_room_id, 2 * chat_room_id - 1, 'REQUESTER', @now FROM chat_rooms
UNION ALL
SELECT chat_room_id, 2 * chat_room_id, 'OWNER', @now FROM chat_rooms;

INSERT INTO chat_messages (chat_room_id, user_id, content, created_at, message_type)
WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 20)
SELECT cr.chat_room_id, 2 * cr.chat_room_id - 1 + (s.n % 2), CONCAT('부하 테스트 시드 메시지 ', s.n),
       DATE_SUB(@now, INTERVAL (20 - s.n) MINUTE), 'TEXT'
FROM chat_rooms cr CROSS JOIN seq s;
