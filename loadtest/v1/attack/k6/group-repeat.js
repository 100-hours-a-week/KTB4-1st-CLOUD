import http from 'k6/http';
import crypto from 'k6/crypto';
import encoding from 'k6/encoding';
import { Counter } from 'k6/metrics';

const ip = __ENV.TARGET_IP || '';
if (!/^(10(\.\d{1,3}){3}|172\.(1[6-9]|2\d|3[01])(\.\d{1,3}){2}|192\.168(\.\d{1,3}){2})$/.test(ip)) {
  throw new Error('기존 runner .env의 TARGET_IP를 사용한다');
}
const secret = __ENV.JWT_SECRET || '';
if (secret.length < 32) throw new Error('기존 runner .env의 JWT_SECRET이 필요하다');
const now = Math.floor(Date.now() / 1000);
const header = encoding.b64encode(JSON.stringify({ alg: 'HS256', typ: 'JWT' }), 'rawurl');
const payload = encoding.b64encode(JSON.stringify({ sub: '1', role: 'USER', iat: now, exp: now + 86400 }), 'rawurl');
const signed = `${header}.${payload}`;
const jwt = `${signed}.${crypto.hmac('sha256', secret, signed, 'base64rawurl')}`;
const responses = new Counter('group_responses');
const body = JSON.stringify({
  groupName: 'loadtest-group-1', roadAddress: '서울특별시 테스트로 1',
  longitude: 127.0, latitude: 37.5, groupContent: '부하 테스트 그룹',
});

export const options = {
  vus: 1,
  stages: [{ duration: '30s', target: 800 }, { duration: '4m30s', target: 800 }],
  hosts: { 'target.loadtest': ip }, insecureSkipTLSVerify: true,
  tags: { testid: __ENV.TESTID || 'group-repeat', api: 'be' },
};

export default function () {
  const res = http.post('https://target.loadtest/api/groups', body, {
    headers: { Authorization: `Bearer ${jwt}`, 'Content-Type': 'application/json' },
    timeout: '65s', redirects: 0,
    responseCallback: http.expectedStatuses(201, 409, 429),
  });
  responses.add(1, { status: String(res.status) });
  if (__VU === 1 && __ITER === 0) console.log(`첫 응답: ${res.status} ${res.body || ''}`);
}
