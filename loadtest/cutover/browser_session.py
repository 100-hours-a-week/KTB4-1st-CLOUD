#!/usr/bin/env python3
"""로컬 브라우저에 전용 fixture의 staging 시험 로그인 명령을 복사한다.

JWT/서명 키를 파일이나 로그에 남기지 않는다. OAuth·인증 저장소는 변경하지 않는다.
"""
import argparse
import base64
import hashlib
import hmac
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
from pathlib import Path
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', required=True, help='시험 EC2 공인 IP 또는 DNS 이름')
    parser.add_argument('--fixture', type=Path, required=True)
    parser.add_argument('--participant', type=int, choices=[0, 1], default=0)
    args = parser.parse_args()
    if not args.host or args.host.startswith('-') or any(c.isspace() for c in args.host):
        parser.error('유효한 시험 EC2 주소 필요')
    pair = next((p for p in json.loads(args.fixture.read_text()).get('pairs', []) if p.get('name') == 'reconnect'), None)
    if not pair or type(pair.get('room')) is not int or pair['room'] <= 0 or len(pair.get('users', [])) != 2 or any(type(u) is not int or u <= 0 for u in pair['users']) or len(set(pair['users'])) != 2:
        parser.error('재연결용 fixture에 room과 서로 다른 사용자 두 명이 필요합니다')
    args.room, args.user = pair['room'], pair['users'][args.participant]
    result = subprocess.run([
        'ssh', '-i', str(Path.home() / '.ssh/bakkucca_v1'), '-o', 'BatchMode=yes',
        f'ec2-user@{args.host}', "sudo docker inspect springboot --format '{{json .Config.Env}}'"
    ], capture_output=True, text=True, check=True)
    values = dict(row.split('=', 1) for row in json.loads(result.stdout))
    if not values.get('DB_URL', '').startswith('jdbc:mysql://bakkucca-v2-staging-mysql.c9acsiyqqzik.ap-northeast-2.rds.amazonaws.com:3306/market'):
        raise SystemExit('staging DB 대상이 아니므로 시험 토큰 발급 중단')
    secret = values['JWT_SECRET'].encode()
    def b64(data):
        return base64.urlsafe_b64encode(data).rstrip(b'=')
    now = int(time.time())
    header = b64(b'{"alg":"HS256","typ":"JWT"}')
    payload = b64(json.dumps(dict(sub=str(args.user), role='USER', iat=now, exp=now + 3600)).encode())
    body = header + b'.' + payload
    token = (body + b'.' + b64(hmac.new(secret, body, hashlib.sha256).digest())).decode()
    direction = 'SENT' if args.participant == 0 else 'RECEIVED'
    command = "sessionStorage.setItem('accessToken'," + json.dumps(token) + ");location.href=" + json.dumps(
        f'/pages/chat/{args.room}?direction={direction}')
    html = ('<!doctype html><meta charset="utf-8"><title>Staging 시험 세션</title>'
            '<p>재연결 전용 사용자 ' + str(args.user) + '</p>'
            '<button id="copy">staging 시험 로그인 명령 복사</button>'
            '<p id="result"></p><script>document.getElementById("copy").onclick=async()=>{'
            'await navigator.clipboard.writeText(' + json.dumps(command) + ');'
            'document.getElementById("result").textContent="복사 완료";};</script>').encode()
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != '/':
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            self.wfile.write(html)
        def log_message(self, *_):
            pass
    print('브라우저 준비: http://127.0.0.1:43187 (종료: Ctrl+C)', flush=True)
    HTTPServer(('127.0.0.1', 43187), Handler).serve_forever()


if __name__ == '__main__':
    main()
