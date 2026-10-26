// DB 전환 중 API 흐름과 두 사용자 사이의 채팅을 유지한다.
import http from 'k6/http';
import exec from 'k6/execution';
import crypto from 'k6/crypto';
import encoding from 'k6/encoding';
import { check } from 'k6';
import { Counter } from 'k6/metrics';
import { chatPair } from './chat.js';

export const fixture = JSON.parse(__ENV.FIXTURE_JSON || '{}');
const RUN = __ENV.RUN_ID;
const BASE = (__ENV.BASE_URL || '').replace(/\/$/, '');
const SECRET = __ENV.JWT_SECRET || '';
const RATE = Number(__ENV.RATE || 1);
const MINUTES = Number(__ENV.MINUTES || 30);
const CHAT_PAIRS = Number(__ENV.CHAT_PAIRS || 2);
const CHAT_HOLD = Number(__ENV.CHAT_HOLD_SECONDS || 60);
const CHAT_INTERVAL = Number(__ENV.CHAT_INTERVAL_SECONDS || 5);
const ORIGIN = __ENV.CHAT_ORIGIN || BASE.replace(/\/api$/, '');
const SESSIONS = Number(__ENV.WRITE_SESSIONS || 10);
const READS = RATE * MINUTES * 60;
const UPDATES = MINUTES * 10;
const readRequests = new Counter('read_requests');
const STEPS = ['group', 'search', 'item_list', 'item_detail', 'my_items', 'item_delete', 'item_deleted', 'exchange_create', 'exchange_detail',
  'chat_history', 'exchange_cancel'];
const apiRequests = new Counter('api_requests');
const apiSessions = new Counter('api_sessions_completed');
const HEADER = encoding.b64encode(JSON.stringify({ alg: 'HS256', typ: 'JWT' }), 'rawurl');
if (!RUN || !/^[a-z0-9]{1,10}$/.test(RUN)) throw new Error('RUN_ID: 재사용하지 않는 영문 소문자와 숫자 1~10자');
if (!/^https:\/\/[^/]+\/api$/.test(BASE) || SECRET.length < 32) throw new Error('시험용 BASE_URL(https://호스트/api)과 JWT_SECRET 필요');
if (!Number.isInteger(RATE) || RATE < 1 || !Number.isInteger(MINUTES) || MINUTES < 1 || !Number.isInteger(SESSIONS) || SESSIONS < 1 || SESSIONS > 10) {
  throw new Error('RATE와 MINUTES는 양의 정수, WRITE_SESSIONS는 1~10');
}
if (!Array.isArray(fixture.sessions) || fixture.sessions.length !== SESSIONS) throw new Error('WRITE_SESSIONS와 준비된 fixture 수가 다릅니다');
if (!Number.isInteger(CHAT_PAIRS) || CHAT_PAIRS < 1 || CHAT_PAIRS > 5 ||
    !Number.isInteger(CHAT_HOLD) || CHAT_HOLD < 10 || CHAT_HOLD > 60 ||
    !Number.isInteger(CHAT_INTERVAL) || CHAT_INTERVAL < 1 || CHAT_INTERVAL > CHAT_HOLD - 5) {
  throw new Error('CHAT_PAIRS: 1~5, CHAT_HOLD_SECONDS: 10~60, CHAT_INTERVAL_SECONDS: 1~(hold-5)');
}

export function token(user) {
  const now = Math.floor(Date.now() / 1000);
  const payload = encoding.b64encode(JSON.stringify({ sub: String(user), role: 'USER', iat: now, exp: now + 86400 }), 'rawurl');
  const data = `${HEADER}.${payload}`;
  return `${data}.${crypto.hmac('sha256', SECRET, data, 'base64rawurl')}`;
}
export function log(entry) { console.log(JSON.stringify({ run: RUN, at: Date.now(), ...entry })); }

export const options = {
  scenarios: {
    traffic: {
      executor: 'constant-arrival-rate', exec: 'apiTraffic', rate: SESSIONS, timeUnit: `${MINUTES}m`, duration: `${MINUTES}m`,
      preAllocatedVUs: 10, maxVUs: 100, gracefulStop: '90s',
    },
    // 같은 물건을 6초마다 수정하며, 요청 순서를 유지하도록 VU를 하나만 사용한다.
    updates: { executor: 'constant-arrival-rate', exec: 'updateTraffic', rate: 10, timeUnit: '1m',
      duration: `${MINUTES}m`, preAllocatedVUs: 1, maxVUs: 1, gracefulStop: '90s' },
    reads: { executor: 'constant-arrival-rate', exec: 'readTraffic', rate: RATE, timeUnit: '1s',
      duration: `${MINUTES}m`, preAllocatedVUs: 10, maxVUs: 100, gracefulStop: '90s' },
    chat: { executor: 'constant-vus', exec: 'chatTraffic', vus: CHAT_PAIRS, duration: `${MINUTES}m`, gracefulStop: '90s' },
  },
  insecureSkipTLSVerify: __ENV.SELF_SIGNED === 'true',
  thresholds: {
    checks: ['rate==1'], http_req_failed: ['rate==0'], dropped_iterations: ['count==0'],
    read_requests: ['count>0'],
    api_sessions_completed: ['count>=0'], chat_errors: ['count==0'], chat_messages_sent: ['count>0'],
  },
  tags: { run_id: RUN },
};

export function setup() {
  const chatEnabled = __ENV.CHAT_ENABLED === 'true';
  log({ kind: 'config', schema: 4, sessions: SESSIONS, updates: UPDATES, reads: READS, steps: STEPS, chat_pairs: chatEnabled ? CHAT_PAIRS : 0,
    excluded: ['item_create_ai', 'real_oauth', 'frontend', 'ai', 'kafka_consumer', ...(!chatEnabled ? ['websocket_chat'] : [])] });
}

function request(method, path, user, body, kind, key, expected, meta = {}, validate = () => true) {
  const started = Date.now();
  // 응답이 없는 요청도 검증할 수 있도록 호출 전에 기록한다.
  log({ kind: 'request_start', step: kind, key, started });
  const res = http.request(method, `${BASE}${path}`, body === null ? null : JSON.stringify(body), {
    headers: { Authorization: `Bearer ${token(user)}`, 'Content-Type': 'application/json' },
    tags: { name: kind }, timeout: '65s', responseCallback: http.expectedStatuses(expected),
  });
  let data = null;
  try { data = res.json('data'); } catch (_) { /* 204와 404는 JSON 데이터가 필요 없다. */ }
  const valid = res.status === expected && validate(data);
  apiRequests.add(1);
  log({ kind, key, user, started, ended: Date.now(), status: res.status, expected, valid, ...meta,
    result: kind === 'exchange_create' && data ? { id: data.exchangeRequestId, room: data.chatRoomId } : null });
  check(res, { [kind]: () => valid });
  return data;
}

export function apiTraffic() {
  const seq = exec.scenario.iterationInTest;
  // 종료 경계의 추가 호출은 fixture 접근과 시작 기록 전에 막는다.
  if (seq >= SESSIONS) return;
  const marker = `mg-${RUN}-${seq}`;
  log({ kind: 'api_session_start', key: marker });
  const { user, owner, group, offered, target, deleted, deleteOwner, groupCreator } = fixture.sessions[seq];
  request('POST', '/groups', groupCreator, {
    groupName: marker, roadAddress: '서울특별시 시험로 1', longitude: 127, latitude: 37.5, groupContent: marker,
  }, 'group', marker, 201);
  request('GET', `/items?groupId=${group}&keyword=${encodeURIComponent(marker)}`, user, null, 'search', marker, 200,
    {}, d => d && Array.isArray(d.items));
  request('GET', `/groups/${group}/items`, user, null, 'item_list', marker, 200,
    {}, d => d && Array.isArray(d.items) && d.items.length > 0);
  request('GET', `/items/${target}`, user, null, 'item_detail', marker, 200,
    {}, d => d && d.itemId === target);
  request('GET', '/users/me/items?size=10', user, null, 'my_items', marker, 200,
    {}, d => d && Array.isArray(d.items) && d.items.length > 0);
  request('DELETE', `/items/${deleted}`, deleteOwner, null, 'item_delete', marker, 204, { item: deleted });
  request('GET', `/items/${deleted}`, deleteOwner, null, 'item_deleted', marker, 404);
  const exchange = request('POST', `/items/${target}/exchange-requests`, user, {
    groupId: group, requestedQuantity: 1, offeredItems: [{ itemId: offered, quantity: 1 }],
  }, 'exchange_create', marker, 201, { target, offered, group, owner },
  d => d && Number.isInteger(d.exchangeRequestId) && Number.isInteger(d.chatRoomId) && d.requestedStatus === 'PENDING');
  if (exchange && Number.isInteger(exchange.exchangeRequestId) && Number.isInteger(exchange.chatRoomId)) {
    request('GET', `/exchange-requests/${exchange.exchangeRequestId}`, user, null, 'exchange_detail', marker, 200,
      { exchange: exchange.exchangeRequestId }, d => d && d.exchangeRequestId === exchange.exchangeRequestId && d.requestedStatus === 'PENDING');
    request('GET', `/chat/rooms/${exchange.chatRoomId}/messages`, user, null, 'chat_history', marker, 200,
      {}, d => d && Array.isArray(d.messages) && d.messages.length > 0);
    request('DELETE', `/exchange-requests/${exchange.exchangeRequestId}`, user, null, 'exchange_cancel', marker, 204, { exchange: exchange.exchangeRequestId });
  }
  log({ kind: 'api_session_end', key: marker });
  apiSessions.add(1);
}

export function updateTraffic() {
  const seq = exec.scenario.iterationInTest;
  if (seq >= UPDATES) return;
  const marker = `mg-${RUN}-update-${seq}`;
  const { user, item: edited, group, images } = fixture.update;
  const quantity = 7;
  request('PUT', `/items/${edited}`, user, {
    title: marker, content: marker, quantity, itemState: 'AVAILABLE', exchangeUrgencyScore: 0.5,
    valueGapToleranceScore: 0.5, groupIds: [group], imageIds: images,
  }, 'item_update', marker, 204, { item: edited, quantity, group, images });
}

export function readTraffic() {
  const seq = exec.scenario.iterationInTest;
  if (seq >= READS) return;
  const key = `read-${seq}`, started = Date.now();
  log({ kind: 'read_start', key, started });
  const res = http.request('GET', `${BASE}/groups/${fixture.read.group}/items`, null, {
    headers: { Authorization: `Bearer ${token(fixture.read.user)}` }, tags: { name: 'read_probe' }, timeout: '65s',
    responseCallback: http.expectedStatuses(200),
  });
  let data;
  try { data = res.json('data'); } catch (_) { /* 응답 검증에서 실패 처리한다. */ }
  readRequests.add(1);
  log({ kind: 'read_end', key, started, ended: Date.now(), status: res.status, valid: res.status === 200 && !!data && Array.isArray(data.items) && data.items.length > 0 });
  check(res, { read_probe: () => res.status === 200 && data && Array.isArray(data.items) && data.items.length > 0 });
}

export function chatTraffic() {
  const room = 901 + ((exec.vu.idInTest - 1) % 5);
  chatPair({ run: RUN, session: `${exec.vu.idInTest}-${exec.scenario.iterationInTest}`, room,
    users: [room * 2 - 1, room * 2], url: `${BASE.replace(/^https/, 'wss').replace(/\/api$/, '')}/ws`,
    origin: ORIGIN, hold: CHAT_HOLD, interval: CHAT_INTERVAL, token, log });
}

export function handleSummary(data) {
  return { [`${__ENV.RESULTS_DIR || '.'}/${RUN}-summary.json`]: JSON.stringify(data, null, 2) };
}
