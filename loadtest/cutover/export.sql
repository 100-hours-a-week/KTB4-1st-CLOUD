-- prepare_export.py가 현재 원장으로 생성한 SET 문과 함께 실행한다. 단독 실행 금지.
-- 트래픽과 비동기 작업 종료, 최종 복제 좌표 반영 후 두 DB에서 실행한다.
-- kind, key, user, JSON payload, DB id의 5열 TSV 형식이다.
SELECT 'group', g.group_name, gm.user_id,
       JSON_OBJECT('content', g.group_content), g.group_id
FROM `groups` g JOIN group_members gm ON gm.group_id = g.group_id
WHERE g.group_name LIKE @cutover_prefix AND g.deleted_at IS NULL AND gm.user_status = 'ACTIVE'
UNION ALL
SELECT 'search', keyword, user_id, JSON_OBJECT('keyword', keyword), search_history_id
FROM search_histories WHERE keyword LIKE @cutover_prefix AND deleted_at IS NULL
UNION ALL
SELECT 'item_update', i.title, i.user_id,
       JSON_OBJECT('content', i.content, 'quantity', i.quantity, 'state', i.item_state,
         'deleted', i.deleted_at IS NOT NULL,
         'group', (SELECT MIN(gi.group_id) FROM group_items gi WHERE gi.item_id=i.item_id AND gi.deleted_at IS NULL),
         'group_count', (SELECT COUNT(*) FROM group_items gi WHERE gi.item_id=i.item_id AND gi.deleted_at IS NULL),
         'images', (SELECT JSON_ARRAYAGG(im.image_id) FROM images im WHERE im.item_id=i.item_id),
         'views', (SELECT st.view_count FROM item_stats st WHERE st.item_id=i.item_id)), i.item_id
FROM items i WHERE i.title LIKE @cutover_prefix
UNION ALL
SELECT 'item_delete', CAST(item_id AS CHAR), user_id,
       JSON_OBJECT('deleted', deleted_at IS NOT NULL), item_id
FROM items WHERE FIND_IN_SET(item_id, @cutover_deleted_ids)
UNION ALL
SELECT 'exchange', CAST(er.exchange_request_id AS CHAR), er.requester_id,
       JSON_OBJECT('quantity', er.requested_quantity, 'status', er.requested_status, 'group', er.group_id,
         'offered', (SELECT MIN(oi.item_id) FROM exchange_request_offered_items oi WHERE oi.exchange_request_id=er.exchange_request_id),
         'offered_quantity', (SELECT MIN(oi.quantity) FROM exchange_request_offered_items oi WHERE oi.exchange_request_id=er.exchange_request_id),
         'offered_count', (SELECT COUNT(*) FROM exchange_request_offered_items oi WHERE oi.exchange_request_id=er.exchange_request_id),
         'room', cr.chat_room_id, 'room_status', cr.chat_room_status,
         'members', (SELECT JSON_ARRAYAGG(cm.user_id) FROM chat_members cm WHERE cm.chat_room_id=cr.chat_room_id),
         'views', (SELECT st.view_count FROM item_stats st WHERE st.item_id=er.item_id)), er.exchange_request_id
FROM exchange_requests er JOIN chat_rooms cr ON cr.exchange_request_id=er.exchange_request_id
WHERE FIND_IN_SET(er.exchange_request_id, @cutover_exchange_ids)
UNION ALL
SELECT 'chat', content, user_id, JSON_OBJECT('room', chat_room_id), message_id
FROM chat_messages WHERE content LIKE @cutover_prefix AND message_type='TEXT';
