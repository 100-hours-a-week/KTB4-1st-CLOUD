// 한 VU에서 두 사용자를 같은 방에 연결하고 각 송신의 양쪽 수신을 대조한다.
import { WebSocket } from 'k6/experimental/websockets';
import { setTimeout, clearTimeout } from 'k6/timers';
import { Counter } from 'k6/metrics';
import { check } from 'k6';

const errors = new Counter('chat_errors');
const sent = new Counter('chat_messages_sent');
const started = new Counter('chat_sessions_started');
const completed = new Counter('chat_sessions_completed');

function frame(command, headers, body = '') {
  return `${command}\n${Object.entries(headers).map(([k, v]) => `${k}:${v}\n`).join('')}\n${body}\0`;
}
function frames(data) {
  return String(data).split('\0').map(part => part.replace(/^[\r\n]+/, '')).filter(Boolean).map(part => {
    const end = part.indexOf('\n\n');
    return { command: part.split('\n')[0].trim(), body: end < 0 ? '' : part.slice(end + 2) };
  });
}

export function chatPair(opts) {
  const sockets = [];
  const ready = new Set();
  // 메시지 식별값별로 수신한 사용자 ID를 저장한다.
  const pending = new Map();
  const timers = [];
  const began = Date.now();
  let closing = false;
  let sending = false;
  let seq = 0;
  started.add(1);
  errors.add(0);
  opts.log({ kind: 'chat_open', session: opts.session, room: opts.room, users: opts.users });
  function error(reason) {
    errors.add(1);
    opts.log({ kind: 'chat_error', session: opts.session, reason });
    check(false, { chat_ok: v => v });
  }
  function send() {
    if (closing || Date.now() - began > (opts.hold - 5) * 1000) return;
    // PubSub 시험은 이전 메시지 양쪽 수신 후 한 사용자만 교대로 송신한다.
    if (opts.alternating && !opts.continueOnMissing && [...pending.values()].some(receivers => receivers.size !== 2)) {
      timers.push(setTimeout(send, opts.interval * 1000));
      return;
    }
    const writers = opts.alternating ? [seq % 2] : [0, 1];
    writers.forEach(i => {
      const user = opts.users[i];
      const key = `mg-${opts.run}-chat-${opts.session}-${seq++}`;
      pending.set(key, new Set());
      // SEND 전에 원장에 기록해 송신 실패도 누락으로 검출한다.
      opts.log({ kind: 'chat_send', session: opts.session, key, user, room: opts.room, receivers: opts.users });
      sent.add(1);
      sockets[i].send(frame('SEND', { destination: `/app/chat/rooms/${opts.room}/messages`, 'content-type': 'application/json' },
        JSON.stringify({ content: key })));
    });
    timers.push(setTimeout(send, opts.interval * 1000));
  }
  // 두 사용자가 각각 WebSocket 연결과 STOMP 인증·구독을 수행한다.
  function connect(user, i) {
    const ws = new WebSocket(opts.urls ? opts.urls[i] : opts.url, [], { headers: { Origin: opts.origin, 'Sec-WebSocket-Protocol': 'v12.stomp' } });
    sockets[i] = ws;
    function heartbeat() {
      if (closing) return;
      if (ws.readyState === 1) ws.send('\n');
      timers.push(setTimeout(heartbeat, 20000));
    }
    ws.onopen = () => {
      ws.send(frame('CONNECT', { 'accept-version': '1.2', host: opts.origin,
        'heart-beat': '0,0', Authorization: `Bearer ${opts.token(user)}` }));
      timers.push(setTimeout(heartbeat, 20000));
    };
    ws.onmessage = event => {
      for (const f of frames(event.data)) {
        if (f.command === 'CONNECTED') {
          if (opts.observe) opts.log({ kind: 'chat_connected', session: opts.session, user, room: opts.room, url: opts.urls ? opts.urls[i] : opts.url });
          ws.send(frame('SUBSCRIBE', { id: `user-${user}`, destination: `/topic/chat/rooms/${opts.room}` }));
          ready.add(user);
          // 두 사용자의 연결을 확인한 뒤 송신을 시작한다.
          if (ready.size === 2 && !sending) {
            sending = true;
            timers.push(setTimeout(send, opts.subscribeWaitMs || 500));
          }
        } else if (f.command === 'MESSAGE') {
          try {
            const message = JSON.parse(f.body);
            // 다른 연결에서 보낸 메시지는 제외하고 중복 수신을 검출한다.
            if (!pending.has(message.content)) continue;
            const received = pending.get(message.content);
            if (received.has(user)) error('duplicate_delivery');
            received.add(user);
            opts.log({ kind: 'chat_receive', session: opts.session, key: message.content, receiver: user,
              user: message.userId, room: message.chatRoomId, id: message.messageId });
          } catch (_) { error('invalid_message'); }
        } else if (f.command === 'ERROR') error('stomp_error');
      }
    };
    ws.onerror = () => error('websocket_error');
    ws.onclose = () => {
      opts.log({ kind: 'chat_disconnected', session: opts.session, user, room: opts.room, planned: closing });
      if (!closing) error('unexpected_close');
    };
  }
  opts.users.forEach((user, i) => {
    const delay = i === 1 ? (opts.secondDelay || 0) * 1000 : 0;
    if (delay) timers.push(setTimeout(() => { if (!closing) connect(user, i); }, delay));
    else connect(user, i);
  });
  timers.push(setTimeout(() => {
    closing = true;
    timers.forEach(clearTimeout);
    // 종료 전에 모든 송신 메시지를 두 사용자 모두 받았는지 확인한다.
    const valid = ready.size === 2 && pending.size > 0 && [...pending.values()].every(users => users.size === 2);
    check(valid, { chat_both_users_received: v => v });
    if (!valid) error('missing_delivery_or_connection');
    sockets.forEach(ws => ws.close());
    opts.log({ kind: 'chat_end', session: opts.session, valid, sent: pending.size });
    completed.add(1);
  }, opts.hold * 1000));
}
