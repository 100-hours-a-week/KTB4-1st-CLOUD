// staging 전용 peer. 브라우저 재연결/화면 성공 여부는 별도 관측한다.
import { WebSocket } from 'k6/experimental/websockets';
import { setTimeout, clearTimeout } from 'k6/timers';
import crypto from 'k6/crypto';
import encoding from 'k6/encoding';
import http from 'k6/http';
import { check } from 'k6';
const run = __ENV.RUN_ID;
const secret = __ENV.JWT_SECRET || '';
const pair = JSON.parse(__ENV.FIXTURE_JSON || '{}').pairs?.find(p => p.name === 'reconnect');
if (!pair || !Number.isInteger(pair.room) || pair.room <= 0 || pair.users?.length !== 2 ||
    pair.users.some(u => !Number.isInteger(u) || u <= 0) || pair.users[0] === pair.users[1]) {
  throw new Error('재연결용 fixture에 room과 서로 다른 사용자 두 명이 필요합니다');
}
const user = pair.users[1], room = pair.room;
const origin = 'https://staging.bakkucca.com';
if (!/^[a-z0-9]{1,10}$/.test(run || '') || secret.length < 32) throw new Error('RUN_ID/JWT_SECRET 확인');
export const options = { vus: 1, iterations: 1, maxDuration: '130s', thresholds: { checks: ['rate==1'] } };
function log(entry) { console.log(JSON.stringify({ run, at: Date.now(), user, room, ...entry })); }
function token() {
  const now = Math.floor(Date.now()/1000);
  const h = encoding.b64encode(JSON.stringify({alg:'HS256',typ:'JWT'}),'rawurl');
  const p = encoding.b64encode(JSON.stringify({sub:String(user),role:'USER',iat:now,exp:now+600}),'rawurl');
  return `${h}.${p}.${crypto.hmac('sha256',secret,`${h}.${p}`,'base64rawurl')}`;
}
function frame(command, headers, body='') {
  return `${command}\n${Object.entries(headers).map(([k,v])=>`${k}:${v}\n`).join('')}\n${body}\0`;
}
export default function () {
  const jwt = token();
  const sent = new Set(), received = new Set(), timers = [];
  let connected = false, planned = false, began = 0;
  const ws = new WebSocket('wss://staging.bakkucca.com/ws', [], {headers:{Origin:origin,'Sec-WebSocket-Protocol':'v12.stomp'}});
  const later = (fn, ms) => timers.push(setTimeout(fn,ms));
  log({kind:'peer_open', scope:'peer_only_not_frontend_pass'});
  ws.onopen = () => ws.send(frame('CONNECT', {'accept-version':'1.2',host:origin,'heart-beat':'0,0',Authorization:`Bearer ${jwt}`}));
  ws.onmessage = event => {
    for (const raw of String(event.data).split('\0')) {
      const part = raw.replace(/^[\r\n]+/,'');
      const command = part.split('\n')[0].trim();
      if (command === 'CONNECTED' && !connected) {
        connected = true; began = Date.now();
        ws.send(frame('SUBSCRIBE',{id:`reconnect-peer-${user}`,destination:`/topic/chat/rooms/${room}`}));
        log({kind:'peer_subscribed', epoch:began, schedule_seconds:{baseline:3,gap1:30,gap2:35,gap3:40,resume:80,close:105}});
        [[3,'baseline'],[30,'gap1'],[35,'gap2'],[40,'gap3'],[80,'resume']].forEach(([seconds,phase])=>later(()=>{
          const content = `rc-${run}-${phase}`;
          sent.add(content); log({kind:'peer_send',phase,content,elapsed_ms:Date.now()-began});
          ws.send(frame('SEND',{destination:`/app/chat/rooms/${room}/messages`,'content-type':'application/json'},JSON.stringify({content})));
        },seconds*1000));
        later(()=>{ planned=true; log({kind:'peer_close_requested',elapsed_ms:Date.now()-began}); ws.close(1000); },105000);
      } else if (command === 'MESSAGE') {
        try {
          const m = JSON.parse(part.slice(part.indexOf('\n\n')+2));
          if (sent.has(m.content)) { const duplicate=received.has(m.content); received.add(m.content); log({kind:'peer_self_receive',content:m.content,id:m.messageId,sender:m.userId,chatRoomId:m.chatRoomId,duplicate}); check(!duplicate,{peer_no_duplicate:v=>v}); }
        } catch (_) { log({kind:'peer_error',reason:'invalid_message'}); }
      } else if (command === 'ERROR') { log({kind:'peer_error',reason:'stomp_error'}); check(false,{stomp_ok:v=>v}); }
    }
  };
  ws.onerror = () => { log({kind:'peer_error',reason:'websocket_error'}); check(false,{websocket_ok:v=>v}); };
  ws.onclose = event => {
    timers.forEach(clearTimeout);
    log({kind:'peer_closed',code:event.code,reason:event.reason,planned,elapsed_ms:began?Date.now()-began:null,sent:sent.size,self_received:received.size});
    check(planned && sent.size===5 && received.size===5,{peer_five_self_received:v=>v});
    // 유일한 REST 호출. raw 응답은 peer의 DB history 증거일 뿐 FE 복구 증거가 아니다.
    const response = http.get(`${origin}/api/chat/rooms/${room}/messages`,{headers:{Authorization:`Bearer ${jwt}`},redirects:0,timeout:'10s'});
    log({kind:'peer_history_raw',status:response.status,body:response.body});
    let messages=[];
    try { messages=JSON.parse(response.body).data.messages; } catch (_) {}
    const matched=Array.isArray(messages)?messages.filter(m=>sent.has(m.content)):[];
    log({kind:'peer_history_match',messages:matched.map(m=>({id:m.messageId,content:m.content})),scope:'peer_API_only'});
    check(response.status===200 && new Set(matched.map(m=>m.content)).size===5,{peer_history_has_five:v=>v});
  };
  later(()=>{ planned=false; log({kind:'peer_timeout'}); ws.close(1000); },120000);
}
export function handleSummary(data) { return {[`${__ENV.RESULTS_DIR || '.'}/${run}-summary.json`]:JSON.stringify(data,null,2)}; }
