#!/usr/bin/env python3
"""전환 실행자와 k6가 같은 서버 시계를 사용하도록 전환 시점을 기록한다."""
import argparse
import json
from pathlib import Path
import time

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--run', required=True)
    parser.add_argument('phase', choices=['switch_start', 'switch_complete', 'rollback_start', 'rollback_complete'])
    args = parser.parse_args()
    if not args.run.isalnum() or not 1 <= len(args.run) <= 10:
        parser.error('유효한 RUN_ID 필요')
    folder = Path(__file__).resolve().parents[2] / 'results' / args.run
    if not folder.is_dir():
        parser.error('k6를 실행한 서버의 기존 결과 폴더가 필요합니다')
    path = folder / f'{args.run}-phases.jsonl'
    with path.open('a') as out:
        out.write(json.dumps({'run': args.run, 'phase': args.phase, 'at': time.time_ns() // 1_000_000}) + '\n')
