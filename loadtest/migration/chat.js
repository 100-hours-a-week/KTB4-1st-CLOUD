// 한 VU에서 두 사용자를 같은 방에 연결하고 각 송신의 양쪽 수신을 대조한다.
import { WebSocket } from 'k6/websockets';
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
    opts.users.forEach((user, i) => {
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
  opts.users.forEach((user, i) => {
    const ws = new WebSocket(opts.url, [], { headers: { Origin: opts.origin, 'Sec-WebSocket-Protocol': 'v12.stomp' } });
    sockets[i] = ws;
    ws.onopen = () => ws.send(frame('CONNECT', { 'accept-version': '1.2', host: opts.origin,
      'heart-beat': '0,0', Authorization: `Bearer ${opts.token(user)}` }));
    ws.onmessage = event => {
      for (const f of frames(event.data)) {
        if (f.command === 'CONNECTED') {
          ws.send(frame('SUBSCRIBE', { id: `user-${user}`, destination: `/topic/chat/rooms/${opts.room}` }));
          ready.add(user);
          // 두 사용자의 연결을 확인한 뒤 송신을 시작한다.
          if (ready.size === 2 && !sending) {
            sending = true;
            timers.push(setTimeout(send, 500));
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
    ws.onclose = () => { if (!closing) error('unexpected_close'); };
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
