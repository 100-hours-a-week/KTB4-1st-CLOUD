-- 트래픽 종료 후 consumer와 복제의 catch-up을 확인한 다음 두 DB에서 실행한다.
-- mysql --batch --raw --skip-column-names 출력은 verify.py의 입력으로 사용한다.
SELECT 'group', g.group_name, gm.user_id, g.group_content, g.group_id
FROM `groups` g JOIN group_members gm ON gm.group_id = g.group_id
WHERE g.group_name LIKE 'mg-%' AND g.deleted_at IS NULL AND gm.user_status = 'ACTIVE'
UNION ALL
SELECT 'search', keyword, user_id, keyword, search_history_id
FROM search_histories WHERE keyword LIKE 'mg-%' AND deleted_at IS NULL;
