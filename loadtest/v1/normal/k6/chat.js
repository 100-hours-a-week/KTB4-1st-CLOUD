// STOMP 채팅 연결을 유지하고 메시지 지표를 기록한다.
import { WebSocket } from 'k6/websockets';
import { setTimeout, clearTimeout } from 'k6/timers';
import { Counter, Trend } from 'k6/metrics';

export const chatMetrics = {
  connected: new Counter('stomp_connected'),
  closed: new Counter('stomp_closed'),
  unexpectedClose: new Counter('stomp_unexpected_close'),
  errors: new Counter('stomp_errors'),
  connectTime: new Trend('stomp_connect_time', true),
  rtt: new Trend('stomp_message_rtt', true),
  sent: new Counter('stomp_messages_sent'),
  received: new Counter('stomp_messages_received'),
};

// STOMP 프레임을 생성한다.
function frame(command, headers, body) {
  const head = Object.entries(headers).map(([k, v]) => `${k}:${v}\n`).join('');
  return `${command}\n${head}\n${body || ''}\0`;
}

// 수신 데이터를 STOMP 프레임으로 나눈다.
function parseFrames(data) {
  const frames = [];
  for (const chunk of String(data).split('\0')) {
    const text = chunk.replace(/^[\r\n]+/, '');
    if (!text) continue;
    const headerEnd = text.indexOf('\n\n');
    const head = (headerEnd >= 0 ? text.slice(0, headerEnd) : text).split('\n');
    const headers = {};
    for (const line of head.slice(1)) {
      const i = line.indexOf(':');
      if (i > 0) headers[line.slice(0, i)] = line.slice(i + 1);
    }
    frames.push({ command: head[0].trim(), headers, body: headerEnd >= 0 ? text.slice(headerEnd + 2) : '' });
  }
  return frames;
}

export function openChat(user, connId, opts) {
  const m = chatMetrics;
  const startedAt = Date.now();
  let isConnected = false;
  let closing = false;
  let finished = false;
  let seq = 0;
  let sendTimer = null;
  let holdTimer = null;

  const ws = new WebSocket(opts.url, 'v12.stomp', { headers: { Origin: opts.origin }, tags: { name: 'WS /ws' } });

  function sendMessage() {
    seq += 1;
    opts.onEvent();
    ws.send(frame('SEND', { destination: `/app/chat/rooms/${user.r}/messages`, 'content-type': 'application/json' },
      JSON.stringify({ content: `lt|${connId}|${Date.now()}|${seq}` })));
    m.sent.add(1);
    sendTimer = setTimeout(sendMessage, opts.messageIntervalSeconds * 1000);
  }

  function finish(reason) {
    if (finished) return;
    finished = true;
    opts.onEvent();
    clearTimeout(sendTimer);
    clearTimeout(holdTimer);
    if (isConnected) {
      m.closed.add(1);
      if (closing) return;
      m.unexpectedClose.add(1);
    } else {
      m.errors.add(1, { reason });
    }

    holdTimer = setTimeout(() => {}, opts.reconnectDelayMs);
  }

  ws.onopen = () => {
    ws.send(frame('CONNECT', { 'accept-version': '1.2', host: 'bakkucca.com', 'heart-beat': '0,0', Authorization: `Bearer ${user.t}` }));
  };

  ws.onmessage = (event) => {
    opts.onEvent();
    for (const f of parseFrames(event.data)) {
      if (f.command === 'CONNECTED') {
        isConnected = true;
        m.connected.add(1);
        m.connectTime.add(Date.now() - startedAt);
        ws.send(frame('SUBSCRIBE', { id: 'sub-0', destination: `/topic/chat/rooms/${user.r}` }));
        sendTimer = setTimeout(sendMessage, Math.random() * opts.messageIntervalSeconds * 1000);
      } else if (f.command === 'MESSAGE') {
        m.received.add(1);
        try {
          const parts = JSON.parse(f.body).content.split('|');
          if (parts[0] === 'lt' && parts[1] === connId) m.rtt.add(Date.now() - Number(parts[2]));
        } catch (e) {

        }
      } else if (f.command === 'ERROR') {
        m.errors.add(1, { reason: (f.headers.message || 'stomp_error').slice(0, 60) });
      }
    }
  };

  ws.onerror = () => finish('ws_error');
  ws.onclose = () => finish('closed_before_connected');

  holdTimer = setTimeout(() => {
    closing = true;
    if (isConnected) ws.send(frame('DISCONNECT', {}));
    ws.close();
  }, opts.holdSeconds * 1000 * (0.9 + 0.2 * Math.random()));
}
