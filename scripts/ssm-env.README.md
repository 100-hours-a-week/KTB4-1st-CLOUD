# 로컬 SSM 환경변수 편집

`ssm-env.py`는 Parameter Store의 환경·서비스별 값을 `.env` 파일로 가져오고, 편집한 값만 반영한다. 로컬 AWS CLI 인증을 사용하며 GitHub Actions가 필요하지 않다.

## 준비

- Python 3.9 이상과 AWS CLI v2.
- 로컬 AWS 인증과 대상 환경의 SSM 조회·수정 권한.
- SecureString 조회·수정에 필요한 KMS 복호화·암호화 권한.

SSM 권한은 `ssm:DescribeParameters`, `ssm:GetParametersByPath`, `ssm:PutParameter`를 사용한다. IAM 정책에서는 대상 환경 경로와 KMS 키에 맞게 범위를 제한한다.

## 기본 사용

CLOUD 저장소 루트에서 실행한다.

```bash
# /bakkucca-v2-staging/be/ → .env.staging.be
python3 scripts/ssm-env.py pull staging be

# 같은 파일에서 여러 값 편집
vi .env.staging.be

# 변경할 키 이름과 타입 확인. AWS 값은 변경하지 않음
python3 scripts/ssm-env.py push staging be --dry-run

# 변경된 값만 반영
python3 scripts/ssm-env.py push staging be
```

환경은 `dev`, `staging`, `prod`, 서비스는 `be`, `fe`, `ai` 중 선택한다. 기본 파일은 실행 위치와 관계없이 CLOUD 저장소 루트의 `.env.<환경>.<서비스>`이다.

생성 파일은 권한 `600`이며 Git에서 제외한다. 계정·리전·경로 헤더와 `# ssm-version` 주석은 유지한다. 다른 AWS 계정이나 환경에 반영하거나, pull 이후 변경된 원격 값을 덮어쓰는 것을 검사하는 데 사용한다.

## 옵션

```bash
# AWS 프로필 지정: pull과 push에 같은 프로필 사용
python3 scripts/ssm-env.py pull staging be --profile my-profile
python3 scripts/ssm-env.py push staging be --profile my-profile

# 별도 파일과 리전 지정
python3 scripts/ssm-env.py pull staging fe \
  --file /private/tmp/.env.staging.fe --region ap-northeast-2

# 로컬 편집을 버리고 다시 가져올 때만 사용
python3 scripts/ssm-env.py pull staging be --force
```

기본 리전은 `AWS_REGION`, `AWS_DEFAULT_REGION`, `ap-northeast-2` 순서로 결정한다. `--profile`을 생략하면 AWS CLI의 기존 인증 설정을 사용한다.

## 값 편집 형식

생성된 큰따옴표 문자열에서 값만 수정한다. 줄바꿈·따옴표·역슬래시는 JSON 이스케이프를 사용한다.

```dotenv
CORS_ALLOWED_ORIGINS="https://staging.bakkucca.com"
JAVA_TOOL_OPTIONS="-Xms256m -Xmx512m"
CLOUDFRONT_PRIVATE_KEY_PEM="-----BEGIN PRIVATE KEY-----\n내용\n-----END PRIVATE KEY-----\n"
```

`$`와 `${...}`는 그대로 저장하며 셸 변수로 치환하지 않는다. 이 파일은 스크립트 편집용이므로 `source`하거나 셸에서 실행하지 않는다. 큰따옴표 뒤의 인라인 주석은 지원하지 않으며 설명은 별도 `#` 행으로 작성한다.

## 반영 범위

- 기존 키의 변경된 값만 업데이트한다. 새 키 생성, 누락 키 삭제, 빈 값 입력은 지원하지 않는다.
- 기존 String·SecureString 타입과 KMS 키·계층 등 메타데이터를 유지한다.
- `ManagedBy=terraform` 태그가 있는 파라미터는 읽기 전용 주석으로 출력한다. 주석을 해제해도 push에서 차단한다. 태그가 없는 별도 IaC 관리 값은 이 방식으로 자동 판별할 수 없다.
- Secrets Manager 값은 조회·수정하지 않는다. RDS 비밀번호를 Secrets Manager에서 직접 주입한다면 해당 값은 파일에 포함되지 않는다.
- 비밀값은 명령행 인자·로그에 출력하지 않는다. AWS CLI 요청은 권한 `600` 임시 JSON 파일로 전달하고, 성공·실패 시 모두 삭제한다. 프로세스를 강제 종료하면 임시 파일이 남을 수 있다.
- push는 항목별 실행이므로 트랜잭션이 아니다. 중간 실패 시 일부만 반영될 수 있다. 버전 확인과 쓰기도 원자적이지 않으므로 여러 사람이 동시에 같은 키를 편집하지 않는다.
- SSM 반영만으로 실행 중인 ECS 컨테이너 값이 바뀌지 않는다. 앱 반영은 기존 CD 절차로 별도 재배포한다.

## 오류 처리

| 메시지 | 조치 |
|---|---|
| 기존 파일은 덮어쓰지 않습니다 | 편집을 유지하려면 기존 파일 사용. 버려도 되면 `pull --force` |
| 파일 권한이 넓습니다 | `chmod 600 .env.staging.be` 후 실행 |
| 계정·리전·환경 경로가 다릅니다 | pull 당시 프로필·리전·환경 확인 |
| pull 이후 AWS 값이 변경됐습니다 | 편집 내용을 별도로 보관하고 다시 pull한 뒤 변경분 재적용 |
| Terraform 관리 값입니다 | 해당 키의 주석을 복구하고 Terraform에서 수정 |
| AWS … 실패 (AccessDenied…) | 지정 프로필의 SSM·KMS 권한 확인 |
| AWS describe-parameters 실패 (ParamValidation) | 최신 스크립트 사용. 이전 `/dev/stdin` JSON 전달 방식은 일부 macOS AWS CLI에서 파싱 실패 |

실패한 push를 다시 실행하면 이미 반영된 동일 값은 건너뛴다. 반영 도중 실패했거나 다른 사람이 값을 변경했다면 다시 pull해 원격 상태와 대조한다. `--force`는 로컬 파일 덮어쓰기 옵션이며 원격 충돌을 무시하는 옵션이 아니다.

## 로컬 검증

```bash
python3 -m unittest discover -s scripts -p test_ssm_env.py -v
```

실제 SSM 값은 읽거나 변경하지 않는다. AWS CLI가 설치돼 있으면 `--generate-cli-skeleton output`으로 실제 CLI의 JSON 요청 파일 파싱도 오프라인 검증한다.
