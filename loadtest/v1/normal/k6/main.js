// API 사용자 흐름과 STOMP 채팅 부하를 생성한다.
import http from 'k6/http';
import exec from 'k6/execution';
import crypto from 'k6/crypto';
import encoding from 'k6/encoding';
import { check, sleep } from 'k6';
import { openChat } from './chat.js';

function num(name, fallback) {
  const v = Number(__ENV[name]);
  return __ENV[name] !== undefined && __ENV[name] !== '' && Number.isFinite(v) ? v : fallback;
}

const PROFILE = __ENV.PROFILE || 'smoke';
const SMOKE = PROFILE === 'smoke';
const PEAK_SESSIONS_PER_SEC = num('PEAK_SESSIONS_PER_SEC', 6.7);
const CHAT_CONNECTIONS = num('CHAT_CONNECTIONS', 300);
// VU별 채팅 연결 수와 요청 대기 시간을 설정한다.
const CONNS_PER_VU = 5;
const THINK_SECONDS = num('THINK_SECONDS', 1);
const HOT_RATIO = 0.3;

const P = {
  login: 0.10,
  exchange: 0.15,
  edit: 0.05,
  join: 0.05,
  leave: 0.01,
};
const EVERY = { prefs: 100, del: 50, create: 200 };

const TARGET_HOST = 'target.loadtest';
const TARGET_IP = __ENV.TARGET_IP || '';
if (!/^(10(\.\d{1,3}){3}|172\.(1[6-9]|2\d|3[01])(\.\d{1,3}){2}|192\.168(\.\d{1,3}){2})$/.test(TARGET_IP)) {
  throw new Error(`TARGET_IP는 복제 EC2의 사설 IPv4여야 한다(현재: "${TARGET_IP}")`);
}
const BASE = `https://${TARGET_HOST}/api`;

// seed.sql의 사용자·물건·그룹 ID 범위를 사용한다.
const USERS = 2000;
const NEW_USERS_FROM = 2001;
const NEW_USERS = 1000;
const DELETABLE_FROM = 20001;
const DELETABLE = 4000;
const JOIN_GROUP_FROM = 21;
const JOIN_GROUPS = 100;

const JWT_SECRET = __ENV.JWT_SECRET || '';
if (JWT_SECRET.length < 32) {
  throw new Error('JWT_SECRET이 없다. runner/.env에 target/.env와 같은 값을 넣는다');
}
const JWT_HEADER = encoding.b64encode(JSON.stringify({ alg: 'HS256', typ: 'JWT' }), 'rawurl');

// 시드 사용자의 HS256 JWT를 생성한다.
function token(u) {
  const now = Math.floor(Date.now() / 1000);
  const payload = encoding.b64encode(JSON.stringify({ sub: String(u), role: 'USER', iat: now, exp: now + 86400 }), 'rawurl');
  const data = `${JWT_HEADER}.${payload}`;
  return `${data}.${crypto.hmac('sha256', JWT_SECRET, data, 'base64rawurl')}`;
}

function seedUser(u) {
  const i0 = (u - 1) * 10 + 1;
  return { u, t: token(u), g: Math.ceil(u / 100), i0, i1: u * 10, r: Math.ceil(u / 2), e: [i0, 2 * i0 - 1, 2 * i0] };
}

// 프로필별 부하 단계를 구성한다.
function buildSteps() {
  const ramp = num('RAMP_SECONDS', 30);
  if (PROFILE === 'smoke') return [{ label: 'smoke', kind: 'hold', seconds: 60, m: 0 }];
  if (PROFILE === 'step') {
    const steps = [];
    for (const m of (__ENV.MULTIPLIERS || '0.5 1 2 3 4').trim().split(/[\s,]+/).map(Number)) {
      steps.push({ label: 'ramp', kind: 'ramp', seconds: ramp, m });
      steps.push({ label: `x${m}`, kind: 'hold', seconds: num('STEP_SECONDS', 180), m });
    }
    return steps;
  }
  if (PROFILE === 'breakpoint') {
    const max = num('BREAKPOINT_MAX', 8);
    const total = num('BREAKPOINT_SECONDS', 1200);
    const steps = [];
    for (let t = 60; t <= total; t += 60) {
      const m = (max * t) / total;
      steps.push({ label: `~x${m.toFixed(1)}`, kind: 'hold', seconds: 60, m });
    }
    return steps;
  }
  throw new Error(`알 수 없는 PROFILE: ${PROFILE}`);
}

const steps = buildSteps();
let t = 0;
const segments = steps.map((s) => {
  const seg = Object.assign({}, s, { start: t, end: t + s.seconds });
  t += s.seconds;
  return seg;
});

function tagStage() {
  const elapsed = (Date.now() - exec.scenario.startTime) / 1000;
  const seg = segments.find((s) => elapsed >= s.start && elapsed < s.end) || segments[segments.length - 1];
  exec.vu.metrics.tags.stage = seg.label;
}

const sessionsPerMinute = (m) => Math.max(1, Math.round(PEAK_SESSIONS_PER_SEC * 60 * m));
const chatVus = (m) => Math.max(1, Math.ceil((CHAT_CONNECTIONS * m) / CONNS_PER_VU));

const scenarios = SMOKE
  ? {
      api: { executor: 'per-vu-iterations', exec: 'session', vus: 1, iterations: 3, maxDuration: '2m' },
      chat: { executor: 'constant-vus', exec: 'chat', vus: 2, duration: '40s' },
    }
  : {
      api: {
        executor: 'ramping-arrival-rate',
        exec: 'session',
        startRate: 0,
        timeUnit: '1m',
        stages: steps.map((s) => ({ duration: `${s.seconds}s`, target: sessionsPerMinute(s.m) })),
        preAllocatedVUs: 200,
        maxVUs: 3000,
      },
      chat: {
        executor: 'ramping-vus',
        exec: 'chat',
        startVUs: 0,
        stages: steps.map((s) => ({ duration: `${s.seconds}s`, target: chatVus(s.m) })),
        gracefulRampDown: '30s',
      },
    };

// API·채팅 임계값과 실패율 중단 조건을 설정한다.
const thresholds = {
  'http_req_duration{api:be}': ['p(95)<2000'],
  'http_req_failed{api:be}': ['rate<0.01'],
  'http_reqs{api:be}': ['count>=0'],

  http_req_failed: [{ threshold: 'rate<0.3', abortOnFail: true, delayAbortEval: '1m' }],
};
for (const s of segments.filter((x) => x.kind === 'hold')) {
  thresholds[`http_req_duration{api:be,stage:${s.label}}`] = ['p(95)<2000'];
  thresholds[`http_req_failed{api:be,stage:${s.label}}`] = ['rate<0.01'];
  thresholds[`http_reqs{api:be,stage:${s.label}}`] = ['count>=0'];
  thresholds[`dropped_iterations{stage:${s.label}}`] = ['count>=0'];
  thresholds[`stomp_message_rtt{stage:${s.label}}`] = ['p(95)<1000'];
  thresholds[`stomp_errors{stage:${s.label}}`] = ['count>=0'];
}

export const options = {

  tags: { testid: __ENV.TESTID || `${PROFILE}-${new Date().toISOString().replace(/[-:]/g, '').slice(0, 15)}` },
  hosts: { [TARGET_HOST]: TARGET_IP },
  insecureSkipTLSVerify: true,

  systemTags: ['status', 'method', 'name', 'scenario', 'expected_response', 'error_code', 'proto', 'tls_version', 'check'],
  discardResponseBodies: true,
  summaryTrendStats: ['avg', 'med', 'p(95)', 'p(99)', 'max'],
  scenarios,
  thresholds,
};

function api(method, path, name, user, body, opts = {}) {
  const params = {
    headers: user ? { Authorization: `Bearer ${user.t}` } : {},
    tags: { name, api: 'be' },
    timeout: '65s',
  };
  if (body !== undefined) params.headers['Content-Type'] = 'application/json';
  if (opts.readBody) params.responseType = 'text';
  if (opts.expected) params.responseCallback = http.expectedStatuses(...opts.expected);
  const res = http.request(method, `${BASE}${path}`, body === undefined ? null : JSON.stringify(body), params);
  check(res, { [`${name} ${opts.expected ? opts.expected.join('/') : '2xx'}`]: (r) =>
    (opts.expected ? opts.expected.includes(r.status) : r.status >= 200 && r.status < 300) });
  return res;
}

function json(res, selector) {
  try {
    return res.status >= 200 && res.status < 300 ? res.json(selector) : undefined;
  } catch (e) {
    return undefined;
  }
}

function think() {
  if (THINK_SECONDS > 0) sleep(THINK_SECONDS * (0.5 + Math.random()));
}

const rand = (n) => Math.floor(Math.random() * n);
const between = (a, b) => a + rand(b - a + 1);
const flow = (name) => { exec.vu.metrics.tags.flow = name; };

function otherUserInGroup(user) {
  const first = (user.g - 1) * 100 + 1;
  for (;;) {
    const other = first + rand(100);
    if (other !== user.u) return seedUser(other);
  }
}

function pickItem(user) {
  const lastItem = user.g * 1000;
  if (Math.random() < HOT_RATIO) return lastItem - rand(10);
  return between(lastItem - 999, lastItem);
}

function nth(every) {
  const i = exec.scenario.iterationInTest;
  if (SMOKE) return i;
  return i % every === 0 ? i / every : -1;
}

function login() {
  flow('login');
  api('GET', '/auth/oauth/state', 'GET /auth/oauth/state', null);
}

function preferences(index) {
  flow('preferences');
  const u = NEW_USERS_FROM + (index % NEW_USERS);
  const user = { u, t: token(u) };
  api('POST', '/users/preferences', 'POST /users/preferences', user, {
    answers: [
      { question: 'CONVERSATION_STYLE', answer: 'CONCISE' },
      { question: 'DESCRIPTION_STYLE', answer: 'BRIEF' },
      { question: 'OPINION_STYLE', answer: 'CLEAR' },
    ],
  }, { expected: [201, 409] });
}

function browse(user) {
  flow('browse');
  const first = api('GET', `/groups/${user.g}/items`, 'GET /groups/{id}/items', user, undefined, { readBody: true });
  think();
  const cursor = json(first, 'data.nextCursor');
  api('GET', `/groups/${user.g}/items${cursor ? `?cursor=${encodeURIComponent(cursor)}` : ''}`, 'GET /groups/{id}/items', user);
  for (let i = 0; i < 3; i++) {
    think();
    api('GET', `/items/${pickItem(user)}`, 'GET /items/{id}', user);
  }
}

function exchange(user) {
  flow('exchange');
  api('GET', '/users/me/items?size=10', 'GET /users/me/items', user);
  think();
  const owner = otherUserInGroup(user);
  const created = api('POST', `/items/${between(owner.i0, owner.i1)}/exchange-requests`, 'POST /items/{id}/exchange-requests', user, {
    groupId: user.g,
    requestedQuantity: 1,
    offeredItems: [{ itemId: between(user.i0, user.i1), quantity: 1 }],
  }, { readBody: true, expected: [201, 409] });
  think();
  api('GET', `/chat/rooms/${user.r}/messages`, 'GET /chat/rooms/{id}/messages', user);
  const requestId = json(created, 'data.exchangeRequestId');
  if (requestId) {
    think();
    api('PATCH', `/exchange-requests/${requestId}/status`, 'PATCH /exchange-requests/{id}/status', owner,
      { status: Math.random() < 0.5 ? 'COMPLETED' : 'REJECTED' });
  }
}

function editItem(user) {
  flow('edit');
  api('GET', '/users/me/items?size=10', 'GET /users/me/items', user);
  think();
  const [itemId, ...imageIds] = user.e;
  api('PUT', `/items/${itemId}`, 'PUT /items/{id}', user, {
    title: `부하 테스트 물건 ${user.u}-1 (수정 ${rand(1000)})`,
    content: '부하 테스트로 수정한 물건 설명입니다.',
    quantity: 1000,
    itemState: 'AVAILABLE',
    exchangeUrgencyScore: 0.5,
    valueGapToleranceScore: 0.5,
    groupIds: [user.g],
    imageIds,
  });
}

function deleteItem(index) {
  flow('delete');
  const k = index % DELETABLE;
  const owner = seedUser(Math.ceil((k + 1) / 2));
  api('GET', '/users/me/items?size=10', 'GET /users/me/items', owner);
  think();
  api('DELETE', `/items/${DELETABLE_FROM + k}`, 'DELETE /items/{id}', owner, undefined, { expected: [204, 404] });
}

function joinGroup(user) {
  flow('group-join');
  api('GET', '/groups?keyword=loadtest-join', 'GET /groups', user);
  think();
  api('POST', `/groups/${JOIN_GROUP_FROM + rand(JOIN_GROUPS)}/members`, 'POST /groups/{id}/members', user,
    undefined, { expected: [201, 409] });
}

function leaveGroup(user) {
  flow('group-leave');
  const mine = api('GET', '/users/me/groups', 'GET /users/me/groups', user, undefined, { readBody: true });
  const joined = (json(mine, 'data.groups') || []).filter((g) => g.groupName.startsWith('loadtest-join-'));
  if (joined.length === 0) return;
  think();
  api('DELETE', `/groups/${joined[rand(joined.length)].groupId}/members/me`, 'DELETE /groups/{id}/members/me', user);
}

function createGroup(user, index) {
  flow('group-create');
  const name = `lt-${index}-${rand(100000)}`;
  const created = api('POST', '/groups', 'POST /groups', user, {
    groupName: name,
    roadAddress: '서울특별시 테스트로 3',
    longitude: 127.0,
    latitude: 37.5,
    groupContent: '부하 테스트로 만든 그룹',
  }, { expected: [201, 409] });
  if (created.status !== 201) return;
  think();
  const mine = api('GET', '/users/me/groups', 'GET /users/me/groups', user, undefined, { readBody: true });
  const group = (json(mine, 'data.groups') || []).find((g) => g.groupName === name);
  if (!group) return;
  think();
  api('DELETE', `/groups/${group.groupId}/members/me`, 'DELETE /groups/{id}/members/me', user);
}

const hit = (p) => SMOKE || Math.random() < p;

export function session() {
  tagStage();
  const user = seedUser(1 + rand(USERS));
  if (hit(P.login)) login();
  const prefs = nth(EVERY.prefs);
  if (prefs >= 0) preferences(prefs);
  browse(user);
  if (hit(P.exchange)) exchange(user);
  if (hit(P.edit)) editItem(user);
  const del = nth(EVERY.del);
  if (del >= 0) deleteItem(del);
  if (hit(P.join)) joinGroup(user);
  if (hit(P.leave)) leaveGroup(user);
  const create = nth(EVERY.create);
  if (create >= 0) createGroup(user, create);
}

export function chat() {
  tagStage();
  for (let c = 0; c < CONNS_PER_VU; c++) {
    const u = 1 + (((exec.vu.idInTest - 1) * CONNS_PER_VU + c) % USERS);
    openChat(seedUser(u), `${exec.vu.idInTest}-${c}`, {
      url: `wss://${TARGET_HOST}/ws`,
      origin: 'https://bakkucca.com',
      holdSeconds: SMOKE ? 30 : 600,
      messageIntervalSeconds: SMOKE ? 5 : 40,
      reconnectDelayMs: 5000,
      onEvent: tagStage,
    });
  }
}

function value(data, name, stat) {
  const m = data.metrics[name];
  return m && m.values && m.values[stat] !== undefined ? m.values[stat] : null;
}

const fmt = (v, d) => (v === null || v === undefined ? '-' : Number(v).toFixed(d));

// 구간별 요약과 JSON 결과를 저장한다.
export function handleSummary(data) {
  const dir = __ENV.RESULTS_DIR || '/results';
  const testid = exec.test.options.tags.testid;
  const endMs = Date.now();
  const startMs = endMs - data.state.testRunDurationMs;
  const rows = segments.filter((s) => s.kind === 'hold' && startMs + s.start * 1000 < endMs).map((s) => {
    const seconds = Math.max(1, (Math.min(startMs + s.end * 1000, endMs) - (startMs + s.start * 1000)) / 1000);
    const count = value(data, `http_reqs{api:be,stage:${s.label}}`, 'count');
    return [
      s.label,
      fmt(count === null ? null : count / seconds, 1),
      fmt(value(data, `http_req_duration{api:be,stage:${s.label}}`, 'p(95)'), 0),
      fmt((value(data, `http_req_failed{api:be,stage:${s.label}}`, 'rate') || 0) * 100, 2),
      fmt(value(data, `dropped_iterations{stage:${s.label}}`, 'count') || 0, 0),
      SMOKE ? 10 : Math.round(CHAT_CONNECTIONS * s.m),
      fmt(value(data, `stomp_message_rtt{stage:${s.label}}`, 'p(95)'), 0),
      fmt(value(data, `stomp_errors{stage:${s.label}}`, 'count') || 0, 0),
    ].join('\t');
  });
  const text = [
    `${testid}  1배 = ${PEAK_SESSIONS_PER_SEC}세션/초 + 채팅 ${CHAT_CONNECTIONS}연결`,
    `전체: 요청 ${fmt(value(data, 'http_reqs{api:be}', 'count'), 0)}건, p95 ${fmt(value(data, 'http_req_duration{api:be}', 'p(95)'), 0)}ms, 실패율 ${fmt((value(data, 'http_req_failed{api:be}', 'rate') || 0) * 100, 2)}%`,
    '',
    ['구간', 'RPS', 'p95ms', '실패%', '누락세션', '채팅연결', '채팅왕복p95ms', '채팅오류'].join('\t'),
    ...rows,
    '',
  ].join('\n');
  return { stdout: text, [`${dir}/${testid}.txt`]: text, [`${dir}/${testid}.json`]: JSON.stringify(data) };
}
