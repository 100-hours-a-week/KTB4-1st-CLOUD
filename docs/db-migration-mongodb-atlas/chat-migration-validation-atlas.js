// MongoDB Atlas mongosh 검증 스크립트 (읽기 전용)
// 역할: 실행 스크립트가 MySQL에서 받은 워터마크 이하의 Atlas 메시지를 내보냅니다.
// databaseName은 run-chat-migration-validation.sh가 환경변수로 전달합니다.
// 2) mongosh "<Atlas 접속 URI>" --file chat-migration-validation-atlas.js > atlas-result.txt
//    접속 URI는 셸 기록/공유 파일에 남기지 말고 안전하게 관리하세요.
// 3) 컷오버 전/후 검증 각각에 대해 별도 결과 파일을 저장하세요.
// 메시지 문서 필드는 ChatMessageDocument 기준: message_id, chat_room_id, user_id,
// content, message_type, system_event_type, created_at, _id(ObjectId)입니다.

const databaseName = globalThis.CHAT_VALIDATION_DATABASE;
const collectionName = "chat_messages";
// 실행 스크립트가 전달한 워터마크 이하의 고정된 메시지 집합을 검사합니다.
const watermarkMessageId = globalThis.CHAT_VALIDATION_WATERMARK ?? null;
// ID별 대조용 JSONL을 출력합니다. 워터마크와 함께 사용하세요.
const exportWatermarkRows = true;

const targetDb = db.getSiblingDB(databaseName);
const messages = targetDb.getCollection(collectionName);

print("=== Atlas database / collection ===");
printjson({ database: databaseName, collection: collectionName, checkedAt: new Date() });

print("=== Total count and message_id range ===");
printjson(messages.aggregate([
  { $group: {
    _id: null,
    count: { $sum: 1 },
    minMessageId: { $min: "$message_id" },
    maxMessageId: { $max: "$message_id" },
    firstCreatedAt: { $min: "$created_at" },
    lastCreatedAt: { $max: "$created_at" }
  } },
  { $project: { _id: 0, count: 1, minMessageId: 1, maxMessageId: 1, firstCreatedAt: 1, lastCreatedAt: 1 } }
]).toArray());

if (watermarkMessageId !== null) {
  print("=== Count and range through source watermark ===");
  printjson(messages.aggregate([
    { $match: { message_id: { $lte: watermarkMessageId } } },
    { $group: {
      _id: null, count: { $sum: 1 },
      minMessageId: { $min: "$message_id" }, maxMessageId: { $max: "$message_id" }
    } },
    { $project: { _id: 0, count: 1, minMessageId: 1, maxMessageId: 1 } }
  ]).toArray());
}

print("=== Count by chat room and sender ===");
printjson(messages.aggregate([
  { $group: {
    _id: { chatRoomId: "$chat_room_id", userId: "$user_id" },
    count: { $sum: 1 },
    minMessageId: { $min: "$message_id" },
    maxMessageId: { $max: "$message_id" }
  } },
  { $sort: { "_id.chatRoomId": 1, "_id.userId": 1 } }
]).toArray());

print("=== Duplicate message_id values (expected: empty) ===");
printjson(messages.aggregate([
  { $group: { _id: "$message_id", copies: { $sum: 1 } } },
  { $match: { copies: { $gt: 1 } } },
  { $sort: { _id: 1 } }
]).toArray());

print("=== Documents missing required fields (expected: empty) ===");
printjson(messages.find({ $or: [
  { message_id: { $exists: false } },
  { chat_room_id: { $exists: false } },
  { content: { $exists: false } },
  { message_type: { $exists: false } },
  { created_at: { $exists: false } }
] }, { _id: 1, message_id: 1, chat_room_id: 1, user_id: 1, created_at: 1 }).toArray());

print("=== created_at BSON type counts ===");
printjson(messages.aggregate([
  { $group: { _id: { $type: "$created_at" }, count: { $sum: 1 } } },
  { $sort: { _id: 1 } }
]).toArray());

print("=== Collection indexes ===");
printjson(messages.getIndexes());

// 선택 시 워터마크 이하의 ID별 메시지 행을 내보냅니다.
if (exportWatermarkRows) {
  if (watermarkMessageId === null) {
    throw new Error("exportWatermarkRows=true일 때 watermarkMessageId도 입력해야 합니다.");
  }
  messages.find({ message_id: { $lte: watermarkMessageId } }, {
    _id: 1, message_id: 1, chat_room_id: 1, user_id: 1, content: 1,
    message_type: 1, system_event_type: 1, created_at: 1
  }).sort({ message_id: 1 }).forEach((message) => {
    print("ROW " + JSON.stringify({
      message_id: message.message_id.toString(),
      chat_room_id: message.chat_room_id == null ? null : message.chat_room_id.toString(),
      user_id: message.user_id == null ? null : message.user_id.toString(),
      content: message.content,
      message_type: message.message_type,
      system_event_type: message.system_event_type ?? null,
      message_object_id: message._id == null ? null : message._id.toString(),
      created_at: message.created_at instanceof Date ? message.created_at.toISOString() : message.created_at
    }));
  });
}
