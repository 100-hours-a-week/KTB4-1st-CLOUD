// v1 시험의 JWT 인증·시드 데이터를 사용해 일정한 DB 쓰기를 발생시킨다.
import http from 'k6/http';
import exec from 'k6/execution';
import crypto from 'k6/crypto';
import encoding from 'k6/encoding';
import { check } from 'k6';

const RUN = __ENV.RUN_ID;
const BASE = __ENV.BASE_URL;
const SECRET = __ENV.JWT_SECRET || '';
const RATE = Number(__ENV.RATE || 1);
const MINUTES = Number(__ENV.MINUTES || 30);
if (!RUN || !/^[a-z0-9]{1,10}$/.test(RUN)) throw new Error('RUN_ID: 재사용하지 않는 영문 소문자·숫자 1~10자');
if (!BASE || !/^https:\/\//.test(BASE) || SECRET.length < 32) throw new Error('시험용 BASE_URL(https)과 JWT_SECRET 필요');
if (!Number.isInteger(RATE) || RATE < 1 || !Number.isInteger(MINUTES) || MINUTES < 1 || RATE * MINUTES * 60 > 4000) {
  throw new Error('RATE·MINUTES는 양의 정수이며 총 세션 수는 4,000 이하여야 함');
}
// 신규 생성 사용자 2001~3000의 그룹 가입 한도(5개)에 여유를 남긴다.
const HEADER = encoding.b64encode(JSON.stringify({ alg: 'HS256', typ: 'JWT' }), 'rawurl');
function token(user) {
  const now = Math.floor(Date.now() / 1000);
  const payload = encoding.b64encode(JSON.stringify({ sub: String(user), role: 'USER', iat: now, exp: now + 86400 }), 'rawurl');
  const data = `${HEADER}.${payload}`;
  return `${data}.${crypto.hmac('sha256', SECRET, data, 'base64rawurl')}`;
}

export const options = {
  scenarios: { traffic: {
    executor: 'constant-arrival-rate', rate: RATE, timeUnit: '1s', duration: `${MINUTES}m`,
    preAllocatedVUs: 10, maxVUs: 100, gracefulStop: '90s',
  } },
  insecureSkipTLSVerify: __ENV.SELF_SIGNED === 'true',
  thresholds: { checks: ['rate==1'], http_req_failed: ['rate==0'], dropped_iterations: ['count==0'] },
  tags: { run_id: RUN },
};

export function setup() {
  console.log(JSON.stringify({ run: RUN, kind: 'config', sessions: RATE * MINUTES * 60 }));
}

function request(method, path, user, body, kind, key, expected) {
  const started = Date.now();
  const res = http.request(method, `${BASE}${path}`, body === null ? null : JSON.stringify(body), {
    headers: { Authorization: `Bearer ${token(user)}`, 'Content-Type': 'application/json' },
    tags: { name: kind }, timeout: '65s', responseCallback: http.expectedStatuses(expected),
  });
  // 자동 재시도하지 않는다. 타임아웃 후 실제 커밋 여부도 검증 대상이다.
  console.log(JSON.stringify({ run: RUN, kind, key, user, started, ended: Date.now(), status: res.status }));
  check(res, { [kind]: r => r.status === expected });
  return res;
}

export default function () {
  const seq = exec.scenario.iterationInTest;
  const marker = `mg-${RUN}-${seq}`;
  const user = 2001 + seq % 1000;
  request('POST', '/groups', user, {
    groupName: marker, roadAddress: '서울특별시 시험로 1', longitude: 127, latitude: 37.5, groupContent: marker,
  }, 'group', marker, 201);
  // 시드 그룹의 기존 멤버로 검색하면 BE 내부 비동기 executor가 검색 이력을 저장한다.
  request('GET', `/items?groupId=1&keyword=${encodeURIComponent(marker)}`, 1, null, 'search', marker, 200);
}

export function handleSummary(data) {
  return { [`${__ENV.RESULTS_DIR || '.'}/${RUN}-summary.json`]: JSON.stringify(data, null, 2) };
}
