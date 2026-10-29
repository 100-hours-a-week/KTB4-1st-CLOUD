import http from 'k6/http';
import exec from 'k6/execution';
import crypto from 'k6/crypto';
import encoding from 'k6/encoding';
import { check } from 'k6';

const BASE_URL = __ENV.BASE_URL;
const SECRET = __ENV.JWT_SECRET || '';
const SUBJECT = __ENV.JWT_SUBJECT || '';
const RUN = __ENV.RUN_ID || 'mig01';

if (!BASE_URL || !/^https:\/\//.test(BASE_URL)) {
    throw new Error('BASE_URL은 HTTPS 주소여야 합니다.');
}
if (SECRET.length < 32 || !SUBJECT) {
    throw new Error('JWT_SECRET과 JWT_SUBJECT가 필요합니다.');
}

// 기존 서비스에서 사용하던 JWT 생성 방식
const HEADER = encoding.b64encode(
    JSON.stringify({ alg: 'HS256', typ: 'JWT' }),
    'rawurl'
);

function token(subject) {
    const now = Math.floor(Date.now() / 1000);
    const payload = encoding.b64encode(
        JSON.stringify({
            sub: String(subject),
            role: 'USER',
            iat: now,
            exp: now + 86400,
        }),
        'rawurl'
    );

    const data = `${HEADER}.${payload}`;
    const signature = crypto.hmac(
        'sha256',
        SECRET,
        data,
        'base64rawurl'
    );

    return `${data}.${signature}`;
}

// 아래 9개 API를 실제 URL과 요청 본문으로 수정하세요.
const endpoints = [
    // UPDATE 1
    {
        name: 'update_내취향',
        operation: 'update',
        method: 'PUT',
        path: '/api/users/preferences',
        expected: 200,
        body: (seq) => ({
            "answers": [
                { "question": "CONVERSATION_STYLE", "answer": "CONCISE" },
                { "question": "DESCRIPTION_STYLE", "answer": "MODERATE" },
                { "question": "OPINION_STYLE", "answer": "NATURAL" }
            ]
        }),
    },
    // READ 1~3
    {
        name: 'read_내정보',
        operation: 'read',
        method: 'GET',
        path: '/api/users/me',
        expected: 200,
        body: null,
    },
    {
        name: 'read_내취향',
        operation: 'read',
        method: 'GET',
        path: '/api/users/preferences',
        expected: 200,
        body: null,
    },
    {
        name: 'read_그룹검색',
        operation: 'read',
        method: 'GET',
        path: '/api/groups?keyword=분당&cursor=',
        expected: 200,
        body: null,
    },
];

export const options = {
    scenarios: {
        general_traffic: {
            executor: 'constant-arrival-rate',
            exec: 'generalTraffic',
            rate: 18,
            timeUnit: '1s',
            duration: '10m',
            preAllocatedVUs: 80,
            maxVUs: 120,
        },
        like_pair: {
            executor: 'constant-arrival-rate',
            exec: 'likePair',
            rate: 1,
            timeUnit: '1s',
            duration: '10m',
            preAllocatedVUs: 5,
            maxVUs: 20,
        },
    },
    summaryTrendStats: [
        'avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)',
    ],
    thresholds: {
        checks: ['rate==1'],
        http_req_failed: ['rate==0'],
        dropped_iterations: ['count==0'],
    },
};

// 일반 API: iteration마다 하나의 요청
export function generalTraffic() {
    const seq = exec.scenario.iterationInTest;
    const endpoint = endpoints[seq % endpoints.length];

    const body =
        typeof endpoint.body === 'function'
            ? endpoint.body(seq)
            : endpoint.body;

    const response = http.request(
        endpoint.method,
        `${BASE_URL}${endpoint.path}`,
        body === null ? null : JSON.stringify(body),
        {
            headers: {
                Authorization: `Bearer ${token(SUBJECT)}`,
                Accept: 'application/json',
                'Content-Type': 'application/json',
            },
            timeout: '10s',
            tags: {
                name: endpoint.name,
                operation: endpoint.operation,
            },
        }
    );

    check(response, {
        [`${endpoint.name}: expected ${endpoint.expected}`]:
            (r) => r.status === endpoint.expected,
    });
}

// 좋아요: 생성 성공 후 삭제
const LIKE_USER_START = 1;

export function likePair() {
    const seq = exec.scenario.iterationInTest;
    const likeSubject = LIKE_USER_START + seq;

    if (likeSubject > 3000) {
        throw new Error('좋아요 테스트용 사용자 ID 범위를 초과했습니다.');
    }

    const params = {
        headers: {
            Authorization: `Bearer ${token(likeSubject)}`,
            Accept: 'application/json',
        },
        timeout: '10s',
    };

    const created = http.post(
        `${BASE_URL}/api/items/1/likes`,
        null,
        {
            ...params,
            tags: { name: 'create_like' },
        }
    );

    const createOk = check(created, {
        '좋아요 생성 성공': (r) => r.status === 201,
    });

    if (!createOk) {
        console.error(
            JSON.stringify({
                operation: 'create_like',
                user: likeSubject,
                status: created.status,
                body: created.body,
            })
        );
        return;
    }

    const deleted = http.del(
        `${BASE_URL}/api/items/1/likes`,
        null,
        {
            ...params,
            tags: { name: 'delete_like' },
        }
    );

    check(deleted, {
        '좋아요 삭제 성공': (r) => r.status === 204,
    });
}

export function handleSummary(data) {
    return {
        [`${RUN}-summary.json`]: JSON.stringify(data, null, 2),
    };
}