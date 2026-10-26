// 채팅 전용: 서버 간 PubSub와 서비스 주소의 장기 연결을 각각 검증한다.
import exec from 'k6/execution';
import crypto from 'k6/crypto';
import encoding from 'k6/encoding';
import { chatPair } from './chat.js';
const run = __ENV.RUN_ID;
const fixture = JSON.parse(__ENV.FIXTURE_JSON || '{}');
const secret = __ENV.JWT_SECRET || '';
const duration = Number(__ENV.DURATION || 600);
const origin = 'https://staging.bakkucca.com';
if (!/^[a-z0-9]{1,10}$/.test(run || '') || secret.length < 32 || !Number.isInteger(duration) || duration < 60 || duration > 900) {
  throw new Error('RUN_ID/JWT_SECRET/DURATION(60~900초) 확인');
}
const pairs = ['split', 'service'].map(name => fixture.pairs?.find(p => p.name === name));
if (pairs.some(p => !p || !Number.isInteger(p.room) || p.users?.length !== 2 || p.users.some(u => !Number.isInteger(u)))) {
  throw new Error('별도 PubSub fixture 필요');
}
if (pairs.some(p => p.room <= 0 || p.users.some(u => u <= 0)) ||
    new Set(pairs.map(p => p.room)).size !== 2 || new Set(pairs.flatMap(p => p.users)).size !== 4) {
  throw new Error('채팅방과 사용자 ID는 양의 정수이며 시나리오별로 분리해야 합니다');
}
export const options = {
  scenarios: { continuous: { executor: 'per-vu-iterations', vus: 2, iterations: 1, maxDuration: `${duration + 15}s`, gracefulStop: '0s' } },
  thresholds: { checks: ['rate==1'], chat_errors: ['count==0'], chat_sessions_completed: ['count==2'], chat_messages_sent: ['count>0'] },
};
function token(user) {
  const now = Math.floor(Date.now() / 1000);
  const head = encoding.b64encode(JSON.stringify({ alg: 'HS256', typ: 'JWT' }), 'rawurl');
  const payload = encoding.b64encode(JSON.stringify({ sub: String(user), role: 'USER', iat: now, exp: now + duration + 600 }), 'rawurl');
  const data = `${head}.${payload}`;
  return `${data}.${crypto.hmac('sha256', secret, data, 'base64rawurl')}`;
}
export function setup() {
  console.log(JSON.stringify({ run, at: Date.now(), kind: 'pubsub_start', duration, pairs,
    scope: 'continuous_only', excluded: ['reconnect_history', 'frontend_rendering'] }));
}
export default function () {
  const p = pairs[exec.vu.idInTest - 1];
  const urls = p.name === 'split'
    ? ['wss://v1-origin.staging.bakkucca.com/ws', 'wss://origin.staging.bakkucca.com/ws']
    : ['wss://staging.bakkucca.com/ws', 'wss://staging.bakkucca.com/ws'];
  chatPair({ run, session: p.name, room: p.room, users: p.users, urls, origin,
    hold: duration, interval: Number(__ENV.MESSAGE_INTERVAL || 1), alternating: true, observe: true, token,
    subscribeWaitMs: Number(__ENV.SUBSCRIBE_WAIT_MS || 500), continueOnMissing: __ENV.CONTINUE_ON_MISSING === 'true',
    log: entry => console.log(JSON.stringify({ run, at: Date.now(), ...entry })) });
}
export function handleSummary(data) {
  return { [`${__ENV.RESULTS_DIR || '.'}/${run}-summary.json`]: JSON.stringify(data, null, 2) };
}
