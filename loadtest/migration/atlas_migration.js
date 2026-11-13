import http from 'k6/http';
import ws from 'k6/ws';
import exec from 'k6/execution';
import crypto from 'k6/crypto';
import encoding from 'k6/encoding';
import { check } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

// ============================================================
// 환경 변수
// ============================================================

const BASE_URL = (__ENV.BASE_URL || '').replace(/\/+$/, '');
const WS_URL = (__ENV.WS_URL || '').replace(/\/+$/, '');

const SECRET = __ENV.JWT_SECRET || '';
const SETUP_USER_ID = __ENV.CHAT_USER_ID;
const GROUP_ID = __ENV.MIGRATION_GROUP_ID;

const RUN = __ENV.RUN_ID || 'mig01';
const MIGRATION_PHASE = __ENV.MIGRATION_PHASE || 'unspecified';

// WebSocket 설정
const WS_ORIGIN = __ENV.WS_ORIGIN || BASE_URL;
const STOMP_HOST = __ENV.STOMP_HOST || 'localhost';

// 부하 테스트 설정
const MAX_PAGES = Number(__ENV.MAX_PAGES || 10);
const WS_TIMEOUT_MS = Number(__ENV.WS_TIMEOUT_MS || 5000);
// E2E 1회는 exchange, room detail, message query, cancel의 HTTP 4건을 발생시킨다.
// 기본값 5회/s로 채팅 HTTP 약 20 RPS를 만들고, http_fill 20 RPS를 더한다.
const CHAT_FLOW_RATE = Number(__ENV.CHAT_FLOW_RATE || __ENV.RATE || 5);
const HTTP_FILL_RATE = Number(__ENV.HTTP_FILL_RATE || 20);
const TEST_DURATION = __ENV.TEST_DURATION || '15m';
const PAIR_ENABLED = __ENV.PAIR_ENABLED === 'true';
const PAIR_COUNT = Number(__ENV.PAIR_COUNT || 1);
const PAIR_HOLD_SECONDS = Number(__ENV.PAIR_HOLD_SECONDS || 30);
const PAIR_START_DELAY_SECONDS = Number(__ENV.PAIR_START_DELAY_SECONDS || 2);

// ============================================================
// 환경 변수 검증
// ============================================================

if (!BASE_URL || !/^https:\/\//.test(BASE_URL)) {
    throw new Error('BASE_URL은 HTTPS 주소여야 합니다.');
}

if (!WS_URL || !/^wss:\/\//.test(WS_URL)) {
    throw new Error('WS_URL은 WSS 주소여야 합니다.');
}

if (SECRET.length < 32) {
    throw new Error('JWT_SECRET은 32자 이상이어야 합니다.');
}

if (!SETUP_USER_ID || !/^\d+$/.test(String(SETUP_USER_ID))) {
    throw new Error('CHAT_USER_ID는 숫자 requester user_id여야 합니다.');
}

if (!GROUP_ID || !/^\d+$/.test(String(GROUP_ID))) {
    throw new Error('MIGRATION_GROUP_ID는 숫자여야 합니다.');
}

if (!Number.isInteger(MAX_PAGES) || MAX_PAGES < 1 ||
    !Number.isInteger(WS_TIMEOUT_MS) || WS_TIMEOUT_MS < 1 ||
    !Number.isFinite(CHAT_FLOW_RATE) || CHAT_FLOW_RATE < 1 ||
    !Number.isFinite(HTTP_FILL_RATE) || HTTP_FILL_RATE < 1) {
    throw new Error('부하 테스트 숫자 설정은 유효한 양수여야 합니다.');
}

if (PAIR_ENABLED && (!Number.isInteger(PAIR_COUNT) || PAIR_COUNT < 1 ||
    !Number.isInteger(PAIR_HOLD_SECONDS) || PAIR_HOLD_SECONDS < 10 ||
    !Number.isInteger(PAIR_START_DELAY_SECONDS) || PAIR_START_DELAY_SECONDS < 1)) {
    throw new Error('PAIR_COUNT와 pair 시간 설정은 유효한 양수여야 합니다.');
}

// ============================================================
// Custom Metrics
// ============================================================

const wsMessageSent = new Counter('ws_message_sent');
const wsMessageReceived = new Counter('ws_message_received');

const wsConnectionSuccess = new Rate('ws_connection_success');
const wsMessageReceivedRate = new Rate('ws_message_received_rate');
const exchangeCreated = new Rate('exchange_created');
const pageLimitReached = new Counter('message_query_page_limit_reached');
const setupPairs = new Counter('setup_pairs');
const pairMessageDelivered = new Rate('pair_message_delivered');
const pairSenderSuccess = new Rate('pair_sender_success');
const pairReceiverSuccess = new Rate('pair_receiver_success');
const exchangeCancelled = new Rate('exchange_cancelled');

const wsSessionDuration = new Trend('custom_ws_session_duration');

const messageQueryPages = new Counter('message_query_pages');
const messageQueryMessages = new Counter('message_query_messages');

// ============================================================
// JWT 생성
// ============================================================

const HEADER = encoding.b64encode(
    JSON.stringify({
        alg: 'HS256',
        typ: 'JWT',
    }),
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

// ============================================================
// HTTP 공통 설정
// ============================================================

function httpParams(jwt) {
    return {
        headers: {
            Authorization: `Bearer ${jwt}`,
            'Content-Type': 'application/json',
        },
        tags: {
            test_type: 'chat',
            migration_phase: MIGRATION_PHASE,
        },
    };
}

// ============================================================
// 채팅 메시지 조회
// ============================================================

function responseData(res) {
    try {
        return res.json('data');
    } catch (_) {
        return null;
    }
}

function loadFixturePairs() {
    const items = [];
    let cursor = null;
    let pageCount = 0;

    while (pageCount < 100) {
        const url = cursor
            ? `${BASE_URL}/groups/${GROUP_ID}/items?size=100&cursor=${encodeURIComponent(cursor)}`
            : `${BASE_URL}/groups/${GROUP_ID}/items?size=100`;
        const itemsRes = http.get(url, {
            ...httpParams(token(SETUP_USER_ID)),
            tags: {
                test_type: 'migration',
                operation: 'fixture_items',
                migration_phase: MIGRATION_PHASE,
            },
        });
        const page = responseData(itemsRes);
        if (itemsRes.status !== 200 || !page || !Array.isArray(page.items)) {
            throw new Error(
                `fixture item list failed: status=${itemsRes.status} body=${String(itemsRes.body).substring(0, 500)}`
            );
        }
        items.push(...page.items);
        pageCount++;
        if (!page.hasNext) {
            break;
        }
        if (!page.nextCursor) {
            throw new Error('fixture item list hasNext=true without nextCursor');
        }
        cursor = page.nextCursor;
    }

    const targets = items
        // seed.sql reserves TARGET_0001 for the baseline chat room fixture.
        .filter((item) => /^K6_CHAT_TARGET_\d{4}$/.test(item.title) &&
            item.title !== 'K6_CHAT_TARGET_0001')
        .sort((a, b) => a.title.localeCompare(b.title));
    const offers = items
        .filter((item) => /^K6_CHAT_OFFER_\d{4}$/.test(item.title))
        .sort((a, b) => a.title.localeCompare(b.title));
    const pairs = targets
        .map((target, index) => {
            const offered = offers[index];
            if (!offered || String(target.owner?.userId) === String(offered.owner?.userId)) {
                return null;
            }
            return {
                requesterId: offered.owner.userId,
                targetItemId: target.itemId,
                offeredItemId: offered.itemId,
                targetOwnerId: target.owner.userId,
            };
        })
        .filter(Boolean);
    console.log(
        `[fixture totals] items=${items.length}, targets=${targets.length}, offers=${offers.length}, pairs=${pairs.length}`
    );
    if (pairs.length === 0) {
        throw new Error('no valid migration fixture pairs were found');
    }
    setupPairs.add(pairs.length);
    return pairs;
}

function createExchange(pair) {
    const res = http.post(
        `${BASE_URL}/items/${pair.targetItemId}/exchange-requests`,
        JSON.stringify({
            groupId: Number(GROUP_ID),
            requestedQuantity: 1,
            offeredItems: [{ itemId: pair.offeredItemId, quantity: 1 }],
        }),
        {
            ...httpParams(token(pair.requesterId)),
            tags: {
                test_type: 'migration',
                operation: 'exchange_create',
                migration_phase: MIGRATION_PHASE,
            },
        }
    );
    const data = responseData(res);
    const valid = res.status === 201 &&
        data &&
        Number.isInteger(data.exchangeRequestId) &&
        Number.isInteger(data.chatRoomId);

    exchangeCreated.add(valid);
    check(res, {
        'exchange creates chat room': () => valid,
    });

    if (!valid) {
        console.error(
            `[EXCHANGE ERROR] status=${res.status} body=${String(res.body).substring(0, 1000)}`
        );
        return null;
    }

    return {
        exchangeRequestId: data.exchangeRequestId,
        chatRoomId: data.chatRoomId,
        ownerId: pair.targetOwnerId,
        requesterId: pair.requesterId,
    };
}

function createPairFixtures(pairs) {
    if (pairs.length < PAIR_COUNT) {
        throw new Error(
            `PAIR_COUNT=${PAIR_COUNT} exceeds available fixture pairs=${pairs.length}`
        );
    }

    const fixtures = [];
    for (let index = 0; index < PAIR_COUNT; index++) {
        const pair = pairs[index];
        const res = http.post(
            `${BASE_URL}/items/${pair.targetItemId}/exchange-requests`,
            JSON.stringify({
                groupId: Number(GROUP_ID),
                requestedQuantity: 1,
                offeredItems: [{ itemId: pair.offeredItemId, quantity: 1 }],
            }),
            {
                ...httpParams(token(pair.requesterId)),
                tags: {
                    test_type: 'migration_pair',
                    operation: 'pair_exchange_create',
                    migration_phase: MIGRATION_PHASE,
                },
            }
        );
        const data = responseData(res);
        if (res.status !== 201 || !data ||
            !Number.isInteger(data.chatRoomId)) {
            throw new Error(
                `pair fixture creation failed: status=${res.status} body=${String(res.body).substring(0, 500)}`
            );
        }
        fixtures.push({
            chatRoomId: data.chatRoomId,
            requesterId: pair.requesterId,
            ownerId: pair.targetOwnerId,
        });
    }
    return fixtures;
}

function cancelExchange(exchangeRequestId, requesterId) {
    const res = http.del(
        `${BASE_URL}/exchange-requests/${exchangeRequestId}`,
        null,
        {
            ...httpParams(token(requesterId)),
            tags: {
                test_type: 'migration',
                operation: 'exchange_cancel',
                migration_phase: MIGRATION_PHASE,
            },
        }
    );
    const success = res.status === 204;
    exchangeCancelled.add(success);
    check(res, {
        'exchange request cancelled': (response) => response.status === 204,
    });
}

function fetchMessages(chatRoomId, jwt) {
    let cursor = null;
    let pageCount = 0;
    let totalMessages = 0;
    let responseHasNext = false;

    while (pageCount < MAX_PAGES) {
        const url = cursor
            ? `${BASE_URL}/chat/rooms/${chatRoomId}/messages?cursor=${encodeURIComponent(cursor)}`
            : `${BASE_URL}/chat/rooms/${chatRoomId}/messages`;

        const res = http.get(url, {
            ...httpParams(jwt),
            tags: {
                test_type: 'chat',
                operation: 'message_query',
                migration_phase: MIGRATION_PHASE,
            },
        });

        // 실패 원인을 먼저 출력
        if (res.status !== 200) {
            console.error(
                `[HTTP ERROR] status=${res.status}` +
                ` url=${url}` +
                ` body=${String(res.body).substring(0, 1000)}`
            );

            check(res, {
                'message query status is 200': (r) => r.status === 200,
            });

            return;
        }

        check(res, {
            'message query status is 200': (r) => r.status === 200,
        });

        let response;

        try {
            response = res.json('data');
        } catch (_) {
            console.error(
                `[JSON ERROR] body=${String(res.body).substring(0, 1000)}`
            );

            check(null, {
                'message response JSON parsed': () => false,
            });

            return;
        }

        if (!response || !Array.isArray(response.messages)) {
            console.error(
                `[RESPONSE ERROR] body=${String(res.body).substring(0, 1000)}`
            );

            check(null, {
                'messages response is valid': () => false,
            });

            return;
        }

        const messages = response.messages;

        check(messages, {
            'messages is an array': (v) => Array.isArray(v),
            'message IDs exist': (v) =>
                v.every((message) => message.messageId != null),
        });

        totalMessages += messages.length;
        pageCount++;

        messageQueryPages.add(1);
        messageQueryMessages.add(messages.length);

        responseHasNext = response.hasNext === true;
        if (!responseHasNext) {
            break;
        }

        if (!response.nextCursor) {
            console.error(
                '[CURSOR ERROR] hasNext=true but nextCursor is empty'
            );

            check(null, {
                'nextCursor exists when hasNext is true': () => false,
            });

            break;
        }

        cursor = response.nextCursor;
    }

    if (pageCount === MAX_PAGES && responseHasNext) {
        pageLimitReached.add(1);
        check(null, {
            'message query completed before page limit': () => false,
        });
    }

    return {
        pageCount,
        totalMessages,
    };
}

// ============================================================
// 채팅방 상세 조회
// ============================================================

function fetchChatRoomDetail(chatRoomId, jwt) {
    const res = http.get(
        `${BASE_URL}/chat-rooms/${chatRoomId}`,
        {
            ...httpParams(jwt),
            tags: {
                test_type: 'chat',
                operation: 'room_detail',
                migration_phase: MIGRATION_PHASE,
            },
        }
    );

    check(res, {
        'chat room detail status is 200': (r) => r.status === 200,
    });

    if (res.status !== 200) {
        return;
    }

    const data = res.json('data');

    check(data, {
        'chat room ID matches': (v) =>
            String(v.chatRoomId) === String(chatRoomId),
    });
}

// ============================================================
// STOMP Frame 생성
// ============================================================

function stompFrame(command, headers = {}, body = '') {
    const headerText = Object.entries(headers)
        .map(([key, value]) => `${key}:${value}`)
        .join('\n');

    return `${command}\n${headerText}\n\n${body}\u0000`;
}

// ============================================================
// STOMP 메시지 파싱
// ============================================================

function parseStompFrame(raw) {
    const frames = raw.split('\u0000');
    const parsed = [];

    for (const frame of frames) {
        const separator = frame.indexOf('\n\n');

        if (separator === -1) {
            continue;
        }

        const headerPart = frame.substring(0, separator);
        const body = frame.substring(separator + 2);

        const lines = headerPart.split('\n');
        const command = lines[0];

        if (command === 'CONNECTED') {
            parsed.push({ command, body: null, headers: headerPart });
            continue;
        }

        if (command === 'ERROR') {
            parsed.push({ command, body, headers: headerPart });
            continue;
        }

        if (command === 'MESSAGE') {
            try {
                parsed.push({ command, body: JSON.parse(body), headers: headerPart });
            } catch (_) {
                parsed.push({ command, body: null, headers: headerPart });
            }
        }
    }

    return parsed;
}

// ============================================================
// 메시지 응답에서 content 추출
// ============================================================

function extractContent(message) {
    if (!message) {
        return null;
    }

    // ChatMessageResponse 직접 반환
    if (message.content != null) {
        return message.content;
    }

    // ApiResponse 형태로 감싸진 경우
    if (message.data && message.data.content != null) {
        return message.data.content;
    }

    return null;
}

// ============================================================
// WebSocket 메시지 송신
// ============================================================

function sendChatMessage(chatRoomId, jwt) {
    const userId = jwt.userId;

    const uniqueContent =
        `[${RUN}] user=${userId} vu=${exec.vu.idInTest} iter=${exec.vu.iterationInScenario} time=${Date.now()}`;

    let connected = false;
    let sent = false;
    let received = false;

    const startedAt = Date.now();

    const response = ws.connect(
        WS_URL,
        {
            headers: {
                Origin: WS_ORIGIN,
            },
            tags: {
                test_type: 'chat',
                operation: 'websocket_connect',
                migration_phase: MIGRATION_PHASE,
            },
        },
        function (socket) {
            // ------------------------------------------------
            // WebSocket 연결
            // ------------------------------------------------

            socket.on('open', function () {
                // STOMP CONNECT
                socket.send(
                    stompFrame('CONNECT', {
                        'accept-version': '1.2',
                        host: STOMP_HOST,
                        'heart-beat': '0,0',
                        Authorization: `Bearer ${jwt.token}`,
                    })
                );
            });

            // ------------------------------------------------
            // STOMP 수신
            // ------------------------------------------------

            socket.on('message', function (raw) {
                const messages = parseStompFrame(raw);

                for (const message of messages) {
                    if (message.command === 'ERROR') {
                        console.error(
                            `[STOMP ERROR] headers=${message.headers} body=${String(message.body).substring(0, 1000)}`
                        );
                        socket.close();
                        break;
                    }

                    // STOMP 연결 성공
                    if (message.command === 'CONNECTED') {
                        connected = true;

                        socket.send(
                            stompFrame('SUBSCRIBE', {
                                id: `sub-${exec.vu.idInTest}`,
                                destination: `/topic/chat/rooms/${chatRoomId}`,
                                ack: 'auto',
                            })
                        );

                        socket.setTimeout(function () {
                            const requestBody = JSON.stringify({
                                content: uniqueContent,
                            });

                            socket.send(
                                stompFrame(
                                    'SEND',
                                    {
                                        destination: `/app/chat/rooms/${chatRoomId}/messages`,
                                        'content-type': 'application/json',
                                    },
                                    requestBody
                                )
                            );

                            sent = true;
                            wsMessageSent.add(1);
                        }, 100);
                        continue;
                    }

                    if (message.command === 'MESSAGE' && message.body) {
                        const receivedContent = extractContent(message.body);

                        if (receivedContent === uniqueContent) {
                            received = true;
                            wsMessageReceived.add(1);

                            check(message.body, {
                                'received message content matches': (v) =>
                                    extractContent(v) === uniqueContent,
                            });

                            socket.close();
                        }
                    }
                }
            });

            // ------------------------------------------------
            // WebSocket 오류
            // ------------------------------------------------

            socket.on('error', function (e) {
                console.error(
                    `WebSocket error: ${JSON.stringify(e)}`
                );
            });

            // ------------------------------------------------
            // 타임아웃
            // ------------------------------------------------

            socket.setTimeout(function () {
                if (!received) {
                    console.error(
                        `[STOMP TIMEOUT] room=${chatRoomId} sent=${sent} connected=${connected}`
                    );
                }
                socket.close();
            }, WS_TIMEOUT_MS);
        }
    );

    // --------------------------------------------------------
    // 연결 결과 검증
    // --------------------------------------------------------

    const connectionOK = response && response.status === 101;

    if (!connectionOK) {
        console.error(
            `[WS HANDSHAKE FAILED] status=${response ? response.status : 'no response'} ` +
            `body=${String(response && response.body ? response.body : '').substring(0, 500)}`
        );
    }

    wsConnectionSuccess.add(connectionOK);

    check(response, {
        'websocket connection established': (r) =>
            r && r.status === 101,
    });

    wsSessionDuration.add(Date.now() - startedAt);

    check(
        {
            connected,
            sent,
            received,
        },
        {
            'STOMP connected': (v) => v.connected,
            'message sent': (v) => v.sent,
            'message received': (v) => v.received,
        }
    );
    wsMessageReceivedRate.add(Boolean(connectionOK && connected && sent && received));
}

function connectPairSocket(fixture, role, pairIndex) {
    const userId = role === 'sender' ? fixture.requesterId : fixture.ownerId;
    const jwt = token(userId);
    const content = `[${RUN}] pair=${pairIndex} message=sender`;
    let connected = false;
    let sent = false;
    let delivered = false;
    const startedAt = Date.now();

    const response = ws.connect(
        WS_URL,
        {
            headers: { Origin: WS_ORIGIN },
            tags: {
                test_type: 'migration_pair',
                operation: `pair_${role}_connect`,
                migration_phase: MIGRATION_PHASE,
            },
        },
        function (socket) {
            socket.on('open', function () {
                socket.send(stompFrame('CONNECT', {
                    'accept-version': '1.2',
                    host: STOMP_HOST,
                    'heart-beat': '0,0',
                    Authorization: `Bearer ${jwt}`,
                }));
            });

            socket.on('message', function (raw) {
                for (const message of parseStompFrame(raw)) {
                    if (message.command === 'ERROR') {
                        console.error(
                            `[PAIR STOMP ERROR] role=${role} headers=${message.headers} body=${String(message.body).substring(0, 1000)}`
                        );
                        socket.close();
                        return;
                    }

                    if (message.command === 'CONNECTED') {
                        connected = true;
                        socket.send(stompFrame('SUBSCRIBE', {
                            id: `pair-${role}-${pairIndex}`,
                            destination: `/topic/chat/rooms/${fixture.chatRoomId}`,
                            ack: 'auto',
                        }));

                        if (role === 'sender') {
                            socket.setTimeout(function () {
                                socket.send(stompFrame(
                                    'SEND',
                                    {
                                        destination: `/app/chat/rooms/${fixture.chatRoomId}/messages`,
                                        'content-type': 'application/json',
                                    },
                                    JSON.stringify({ content })
                                ));
                                sent = true;
                            }, 500);
                        }
                        continue;
                    }

                    if (role === 'receiver' &&
                        message.command === 'MESSAGE' &&
                        extractContent(message.body) === content) {
                        delivered = true;
                        socket.close();
                    }
                }
            });

            socket.on('error', function (error) {
                console.error(`[PAIR WS ERROR] role=${role} ${JSON.stringify(error)}`);
                socket.close();
            });

            socket.setTimeout(function () {
                if (role === 'receiver' && !delivered) {
                    console.error(
                        `[PAIR TIMEOUT] room=${fixture.chatRoomId} pair=${pairIndex}`
                    );
                }
                socket.close();
            }, role === 'receiver' ? PAIR_HOLD_SECONDS * 1000 : WS_TIMEOUT_MS);
        }
    );

    const connectedAtTransport = response && response.status === 101;
    wsSessionDuration.add(Date.now() - startedAt);

    if (role === 'sender') {
        const success = Boolean(connectedAtTransport && connected && sent);
        pairSenderSuccess.add(success);
        check({ success }, {
            'pair sender delivered SEND': (value) => value.success,
        });
    } else {
        const success = Boolean(connectedAtTransport && connected && delivered);
        pairReceiverSuccess.add(Boolean(connectedAtTransport && connected));
        pairMessageDelivered.add(success);
        check({ success }, {
            'pair receiver got sender message': (value) => value.success,
        });
    }
}

// ============================================================
// Scenarios
// ============================================================

const pairScenarios = {};

if (PAIR_ENABLED) {
    for (let pairIndex = 0; pairIndex < PAIR_COUNT; pairIndex++) {
        pairScenarios[`pair_receiver_${pairIndex}`] = {
            executor: 'constant-vus',
            exec: 'pairReceiver',
            vus: 1,
            duration: TEST_DURATION,
            gracefulStop: `${PAIR_HOLD_SECONDS + 5}s`,
        };

        pairScenarios[`pair_sender_${pairIndex}`] = {
            executor: 'constant-vus',
            exec: 'pairSender',
            startTime: `${PAIR_START_DELAY_SECONDS}s`,
            vus: 1,
            duration: TEST_DURATION,
            gracefulStop: '5s',
        };
    }
}

export const options = {
    scenarios: {
        migration_e2e: {
            executor: 'constant-arrival-rate',
            exec: 'migrationE2E',
            rate: CHAT_FLOW_RATE,
            timeUnit: '1s',
            duration: TEST_DURATION,
            preAllocatedVUs: 10,
            maxVUs: 50,
        },
        http_fill: {
            executor: 'constant-arrival-rate',
            exec: 'httpFill',
            rate: HTTP_FILL_RATE,
            timeUnit: '1s',
            duration: TEST_DURATION,
            preAllocatedVUs: 10,
            maxVUs: 50,
        },
        ...pairScenarios,
    },

    summaryTrendStats: [
        'avg',
        'min',
        'med',
        'max',
        'p(90)',
        'p(95)',
        'p(99)',
    ],

    thresholds: {
        checks: ['rate==1'],
        http_req_failed: ['rate==0'],
        'http_req_duration{operation:message_query}': ['p(95)<1000'],
        dropped_iterations: ['count==0'],
        exchange_created: ['rate==1'],
        exchange_cancelled: ['rate==1'],
        'http_req_duration{operation:http_fill}': ['p(95)<1000'],
        ws_connection_success: ['rate==1'],
        ws_message_received_rate: ['rate==1'],
        ...(PAIR_ENABLED ? {
            pair_sender_success: ['rate==1'],
            pair_receiver_success: ['rate==1'],
            pair_message_delivered: ['rate==1'],
        } : {}),
    },
};

// ============================================================
// Scenario Functions
// ============================================================

export function setup() {
    const pairs = loadFixturePairs();
    return {
        pairs,
        pairFixtures: PAIR_ENABLED ? createPairFixtures(pairs) : [],
    };
}

export function migrationE2E(data) {
    const index = (exec.scenario.iterationInTest +
        (PAIR_ENABLED ? PAIR_COUNT : 0)) % data.pairs.length;
    const pair = data.pairs[index];
    check(pair, {
        'unique fixture pair is available': (value) => !!value,
    });
    if (!pair) {
        return;
    }

    const exchange = createExchange(pair);
    if (!exchange) {
        return;
    }

    const jwt = {
        userId: exchange.requesterId,
        token: token(exchange.requesterId),
    };
    fetchChatRoomDetail(exchange.chatRoomId, jwt.token);
    sendChatMessage(exchange.chatRoomId, jwt);
    fetchMessages(exchange.chatRoomId, jwt.token);
    cancelExchange(exchange.exchangeRequestId, exchange.requesterId);
}

export function httpFill() {
    const res = http.get(
        `${BASE_URL}/groups/${GROUP_ID}/items?size=20`,
        {
            ...httpParams(token(SETUP_USER_ID)),
            tags: {
                test_type: 'http_fill',
                operation: 'http_fill',
                migration_phase: MIGRATION_PHASE,
            },
        }
    );
    const data = responseData(res);
    check(res, {
        'http fill status is 200': (response) => response.status === 200,
        'http fill response is valid': () =>
            data && Array.isArray(data.items),
    });
}

function pairIndexFromScenario(role) {
    const prefix = `pair_${role}_`;
    const name = exec.scenario.name;

    if (!name.startsWith(prefix)) {
        return -1;
    }

    const index = Number(name.slice(prefix.length));
    return Number.isInteger(index) && index >= 0 && index < PAIR_COUNT
        ? index
        : -1;
}

export function pairReceiver(data) {
    const pairIndex = pairIndexFromScenario('receiver');
    const fixture = data.pairFixtures[pairIndex];
    check(fixture, {
        'pair receiver fixture is available': (value) => !!value,
    });
    if (fixture) {
        connectPairSocket(fixture, 'receiver', pairIndex);
    }
}

export function pairSender(data) {
    const pairIndex = pairIndexFromScenario('sender');
    const fixture = data.pairFixtures[pairIndex];
    check(fixture, {
        'pair sender fixture is available': (value) => !!value,
    });
    if (fixture) {
        connectPairSocket(fixture, 'sender', pairIndex);
    }
}

// ============================================================
// Summary
// ============================================================

export function handleSummary(data) {
    return {
        [`${RUN}-${MIGRATION_PHASE}-summary.json`]: JSON.stringify(data, null, 2),
    };
}
