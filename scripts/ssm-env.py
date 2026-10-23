#!/usr/bin/env python3
"""로컬 AWS CLI 인증으로 SSM과 .env 파일을 동기화한다.

python3 scripts/ssm-env.py pull staging be
python3 scripts/ssm-env.py push staging be --dry-run
python3 scripts/ssm-env.py push staging be

기존 파라미터만 수정한다. 삭제/생성, Secrets Manager 수정, 재배포는 하지 않는다.
값은 JSON 큰따옴표 문자열로 저장한다. PEM 줄바꿈은 \\n으로 표현하며,
파일을 source하거나 셸에서 실행하지 않는다. Python 표준 라이브러리와 AWS CLI만 필요하다.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
KEY = re.compile(r'[A-Z_][A-Z0-9_]*\Z')
HEADER = '# ssm-env: '
VERSION = re.compile(r'# ssm-version ([A-Z_][A-Z0-9_]*)=(\d+)\Z')


class EnvError(Exception):
    pass


def aws(args, service, operation, payload=None):
    command = ['aws', '--region', args.region, '--output', 'json', '--no-cli-pager']
    if args.profile:
        command += ['--profile', args.profile]
    command += [service, operation]
    def invoke(argv):
        return subprocess.run(argv, text=True, capture_output=True,
                              env={**os.environ, 'AWS_PAGER': '', 'AWS_CLI_AUTO_PROMPT': 'off'})
    try:
        if payload is None:
            result = invoke(command)
        else:
            # macOS AWS CLI의 /dev/stdin JSON 읽기 실패를 피한다.
            # 값은 프로세스 인자에 넣지 않고, 권한 600 임시 파일을 실행 후 삭제한다.
            with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', prefix='ssm-env-', suffix='.json') as request:
                os.fchmod(request.fileno(), 0o600)
                json.dump(payload, request, ensure_ascii=False)
                request.flush()
                result = invoke(command + ['--cli-input-json', f'file://{request.name}'])
    except FileNotFoundError:
        raise EnvError('AWS CLI가 필요합니다.') from None
    if result.returncode:
        # AWS 오류 문구가 입력값을 포함할 수 있으므로 원문은 출력하지 않는다.
        code = re.search(r'\(([A-Za-z0-9_.]+)\)', result.stderr)
        raise EnvError(f'AWS {operation} 실패 ({code[1] if code else "인증·권한·연결 확인"}).')
    return json.loads(result.stdout or '{}')


def inventory(args):
    prefix = f'/bakkucca-v2-{args.environment}/{args.service}/'
    path_filter = {'Key': 'Path', 'Option': 'Recursive', 'Values': [prefix.rstrip('/')]}
    meta = aws(args, 'ssm', 'describe-parameters', {'ParameterFilters': [path_filter]})['Parameters']
    managed = aws(args, 'ssm', 'describe-parameters', {'ParameterFilters': [path_filter,
        {'Key': 'tag:ManagedBy', 'Values': ['terraform']}]})['Parameters']
    values = aws(args, 'ssm', 'get-parameters-by-path', {
        'Path': prefix, 'Recursive': True, 'WithDecryption': True})['Parameters']
    readonly = {p['Name'] for p in managed}
    metadata = {p['Name']: p for p in meta}
    items = {}
    for parameter in values:
        name = parameter['Name']
        key = name.removeprefix(prefix)
        if not name.startswith(prefix) or not KEY.fullmatch(key):
            raise EnvError('이 경로에 .env 키로 표현할 수 없는 파라미터가 있습니다.')
        if name not in metadata:
            raise EnvError('조회 도중 파라미터가 변경됐습니다. 다시 실행하세요.')
        items[key] = {**metadata[name], **parameter, 'readonly': name in readonly}
    return prefix, items


def read_env(path):
    if path.is_symlink() or not path.is_file():
        raise EnvError('일반 .env 파일이 필요합니다. 먼저 pull을 실행하세요.')
    if path.stat().st_mode & 0o077:
        raise EnvError('파일 권한이 넓습니다. chmod 600으로 변경하세요.')
    content = path.read_text()
    context, values, versions = None, {}, {}
    for number, line in enumerate(content.splitlines(), 1):
        line = line.strip()
        if line.startswith(HEADER):
            if context is not None:
                raise EnvError('중복된 ssm-env 헤더입니다.')
            context = json.loads(line[len(HEADER):])
        elif match := VERSION.fullmatch(line):
            if match[1] in versions:
                raise EnvError('중복된 버전 정보입니다.')
            versions[match[1]] = int(match[2])
        elif line and not line.startswith('#'):
            key, separator, raw = line.partition('=')
            key, raw = key.strip(), raw.strip()
            if not separator or not KEY.fullmatch(key) or key in values:
                raise EnvError(f'{number}행: 잘못된 형식 또는 중복 키입니다.')
            if raw.startswith('"'):
                try:
                    value = json.loads(raw)
                except ValueError:
                    raise EnvError(f'{number}행: 큰따옴표와 줄바꿈 이스케이프를 확인하세요.') from None
            elif raw.startswith("'"):
                if not raw.endswith("'") or len(raw) < 2:
                    raise EnvError(f'{number}행: 닫는 작은따옴표가 필요합니다.')
                value = raw[1:-1]
            else:
                value = raw
            if not isinstance(value, str):
                raise EnvError(f'{number}행: 문자열 값이 필요합니다.')
            values[key] = value
    if context is None:
        raise EnvError('pull로 생성한 ssm-env 헤더가 필요합니다.')
    return content, context, values, versions


def changes(items, values, versions):
    updates = []
    for key, value in values.items():
        if key not in items:
            raise EnvError(f'{key}: 기존 파라미터가 아닙니다. 새 키 생성은 지원하지 않습니다.')
        current = items[key]
        if current['readonly']:
            raise EnvError(f'{key}: Terraform 관리 값입니다. 주석을 유지하세요.')
        if value == current['Value']:
            continue
        if versions.get(key) != current['Version']:
            raise EnvError(f'{key}: pull 이후 AWS 값이 변경됐습니다. 다시 pull하고 편집하세요.')
        if not value:
            raise EnvError(f'{key}: SSM은 빈 값을 지원하지 않습니다.')
        updates.append((key, value, current))
    return updates


def pull(args, path, context, items):
    lines = [HEADER + json.dumps(context), '# 값은 JSON 큰따옴표 문자열. PEM 줄바꿈은 \\n.',
             '# Terraform 값은 주석 유지. 누락 키는 삭제하지 않음. source하지 말 것.', '']
    for key, item in sorted(items.items()):
        lines.append(f'# ssm-version {key}={item["Version"]}')
        if item['readonly']:
            lines.append('# Terraform 관리: 읽기 전용')
        lines.append(('# ' if item['readonly'] else '') + key + '=' + json.dumps(item['Value'], ensure_ascii=False))
        lines.append('')
    if path.is_symlink() or (path.exists() and not args.force):
        raise EnvError('기존 파일은 덮어쓰지 않습니다. 덮어쓰려면 pull --force를 사용하세요.')
    flags = os.O_WRONLY | os.O_CREAT | getattr(os, 'O_NOFOLLOW', 0)
    flags |= os.O_TRUNC if args.force else os.O_EXCL
    fd = os.open(path, flags, 0o600)
    with os.fdopen(fd, 'w') as out:
        os.fchmod(out.fileno(), 0o600)
        out.write('\n'.join(lines))
    print(f'{path}: {len(items)}개 조회, 파일 권한 600')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('action', choices=['pull', 'push'])
    parser.add_argument('environment', choices=['dev', 'staging', 'prod'])
    parser.add_argument('service', choices=['be', 'fe', 'ai'])
    parser.add_argument('--file', type=Path, help='기본: CLOUD 루트의 .env.환경.서비스')
    parser.add_argument('--region', default=os.getenv('AWS_REGION', os.getenv('AWS_DEFAULT_REGION', 'ap-northeast-2')))
    parser.add_argument('--profile', help='생략하면 로컬 AWS CLI 인증 사용')
    parser.add_argument('--force', action='store_true', help='pull 시 기존 로컬 파일 덮어쓰기')
    parser.add_argument('--dry-run', action='store_true', help='push 시 변경할 키 이름만 확인')
    args = parser.parse_args()
    if (args.force and args.action != 'pull') or (args.dry_run and args.action != 'push'):
        parser.error('--force는 pull, --dry-run은 push에서 사용합니다.')
    path = args.file or ROOT / f'.env.{args.environment}.{args.service}'
    parsed = read_env(path) if args.action == 'push' else None
    account = aws(args, 'sts', 'get-caller-identity')['Account']
    expected_path = f'/bakkucca-v2-{args.environment}/{args.service}/'
    context = {'account': account, 'region': args.region, 'path': expected_path}
    if parsed and parsed[1] != context:
        raise EnvError('파일의 AWS 계정·리전·환경 경로가 실행 대상과 다릅니다.')
    _, items = inventory(args)
    if not items:
        raise EnvError('경로에 파라미터가 없습니다.')
    if args.action == 'pull':
        pull(args, path, context, items)
        return
    content, _, values, versions = parsed
    updates = changes(items, values, versions)
    for key, _, current in updates:
        print(f'{key} ({current["Type"]})')
    if args.dry_run or not updates:
        print(f'{len(updates)}개 변경 예정' if args.dry_run else '변경 없음')
        return
    updated = {}
    try:
        for key, value, current in updates:
            payload = {'Name': current['Name'], 'Value': value, 'Type': current['Type'], 'Overwrite': True}
            for field in ['KeyId', 'Tier', 'DataType', 'Description', 'AllowedPattern']:
                if current.get(field):
                    payload[field] = current[field]
            result = aws(args, 'ssm', 'put-parameter', payload)
            updated[key] = result['Version']
    except EnvError:
        print(f'{len(updated)}/{len(updates)}개 반영됨. 일부만 반영됐을 수 있습니다.', file=sys.stderr)
        raise
    # 로컬 편집 내용과 주석을 유지하고 성공한 항목의 버전만 갱신한다.
    content = re.sub(r'^# ssm-version ([A-Z_][A-Z0-9_]*)=(\d+)$',
                     lambda m: f'# ssm-version {m[1]}={updated.get(m[1], m[2])}', content, flags=re.M)
    with path.open('w') as out:
        out.write(content)
    print(f'{len(updated)}개 반영 완료. 실행 중인 앱에 적용하려면 별도 재배포가 필요합니다.')


if __name__ == '__main__':
    try:
        main()
    except (EnvError, OSError, ValueError):
        # JSON/파일 오류도 값이나 비밀값이 담긴 traceback 없이 처리한다.
        error = sys.exc_info()[1]
        print(str(error) if isinstance(error, EnvError) else '파일·JSON 형식 또는 로컬 실행 환경을 확인하세요.', file=sys.stderr)
        sys.exit(1)
