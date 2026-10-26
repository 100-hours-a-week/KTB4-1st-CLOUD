// 같은 RDS를 사용하는 v1/v2의 요청 완료와 WebSocket 연속성을 검증한다.
import http from 'k6/http';
import exec from 'k6/execution';
import { check, sleep } from 'k6';
import { options as baseline, setup as baselineSetup, apiTraffic, updateTraffic, readTraffic,
  token, log, handleSummary, fixture } from './workload.js';
import { chatPair } from './chat.js';

export { apiTraffic, updateTraffic, readTraffic, handleSummary };
const minutes = Number(__ENV.MINUTES || 30);
const hold = minutes * 60;
const delay = Number(__ENV.SPLIT_DELAY_SECONDS || 300);
const base = (__ENV.BASE_URL || '').replace(/\/$/, '');
const slowPath = __ENV.LONG_REQUEST_PATH || '';
const chatEnabled = __ENV.CHAT_ENABLED === 'true';
if (base !== 'https://staging.bakkucca.com/api') throw new Error('인프라 전환 시험은 staging 서비스 주소만 허용');
if (!Number.isInteger(delay) || delay < 10 || delay > hold - 10) throw new Error('SPLIT_DELAY_SECONDS는 10~(시험 초-10)');
if (slowPath && (!slowPath.startsWith('/') || slowPath.startsWith('//'))) throw new Error('LONG_REQUEST_PATH는 동일 API의 상대 경로');

export const options = {
  ...baseline,
  thresholds: Object.fromEntries(Object.entries(baseline.thresholds)
    .filter(([key]) => chatEnabled || !key.startsWith('chat_'))),
  scenarios: {
    ...Object.fromEntries(Object.entries(baseline.scenarios).filter(([key]) => key !== 'chat')),
    ...(chatEnabled ? { persistent: { executor: 'per-vu-iterations', exec: 'persistentChat', vus: 1, iterations: 1,
      maxDuration: `${hold + 30}s`, gracefulStop: '30s' },
    split: { executor: 'per-vu-iterations', exec: 'splitChat', vus: 1, iterations: 1,
      maxDuration: `${hold + 30}s`, gracefulStop: '30s' },
    newcomers: { executor: 'constant-vus', exec: 'newChat', vus: 1, duration: `${minutes}m`, gracefulStop: '70s' } } : {}),
    ...(slowPath ? { slow: { executor: 'constant-vus', exec: 'slowRequest', vus: 1,
      duration: `${minutes}m`, gracefulStop: '70s' } } : {}),
  },
  insecureSkipTLSVerify: false,
};

export function setup() {
  baselineSetup();
  log({ kind: 'cutover_config', split_delay_seconds: delay, hold_seconds: hold,
    chat_enabled: chatEnabled,
    long_request_path: slowPath, long_request_min_ms: Number(__ENV.LONG_REQUEST_MIN_MS || 3000) });
}
function pair(room, session, seconds, secondDelay = 0) {
  const selected = fixture.chat[room];
  chatPair({ run: __ENV.RUN_ID, session, room: selected.room, users: selected.users,
    url: 'wss://staging.bakkucca.com/ws', origin: 'https://staging.bakkucca.com',
    hold: seconds, interval: 5, secondDelay, observe: true, token, log });
}
export function persistentChat() { pair('persistent', 'persistent', hold); }
export function splitChat() { pair('split', 'split', hold, delay); }
export function newChat() { pair('new', `new-${exec.scenario.iterationInTest}`, 60); }
export function slowRequest() {
  const key = `slow-${exec.scenario.iterationInTest}`, started = Date.now();
  log({ kind: 'long_start', key, started });
  // 실제 API 요청을 사용한다. sleep이나 응답 지연 주입을 긴 요청의 증거로 삼지 않는다.
  const res = http.get(`${base}${slowPath}`, {
    headers: { Authorization: `Bearer ${token(fixture.read.user)}` }, timeout: '65s', tags: { name: 'long_request' },
  });
  log({ kind: 'long_end', key, started, ended: Date.now(), status: res.status, error_code: res.error_code });
  check(res, { long_request_completed: r => r.status === 200 });
  sleep(1);
}
