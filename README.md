# 바꾸까 인프라

- 운영: `infra/v2/environments/prod`의 ECS on EC2·ALB·CloudFront·RDS·Valkey
- 개발: `infra/v2/environments/dev`의 앱 인프라와 데이터 EC2
- 운영 서비스 DNS: 수동 관리. Terraform 정의와 실제 연결이 다를 수 있음
- 서비스 배포: 각 FE·BE·AI 저장소의 GitHub Actions와 CodeDeploy

## 작업별 안내

| 작업 | 문서 |
|---|---|
| 인프라 구성·Terraform 실행 | [v2 인프라](infra/v2/README.md) |
| 담당자 IAM 권한 | [IAM](infra/iam/README.md) |
| 환경변수 조회·수정 | [SSM 편집](scripts/ssm-env.README.md) |
| 인프라 전환용 v1 EC2 준비 | [cutover 환경](infra/cutover-staging/README.md) |
| 원본 전환·롤백 검증 | [cutover 시험](loadtest/cutover/README.md) |

## 파일 구조

```text
infra/
├── iam/                    # 담당자 IAM
├── v1/                     # 기존 EC2·S3·DNS 등
├── v2/
│   ├── environments/prod/  # 운영 앱·RDS·Valkey
│   ├── environments/dev/   # 개발 앱·데이터 EC2
│   ├── environments/staging/ # prod 동등 구성의 전환 시험 환경
│   └── modules/            # 공통 인프라 모듈
├── cutover-staging/        # 인프라 전환용 v1 EC2
└── migration-staging/      # DB 담당자 관리
loadtest/
├── cutover/                # 인프라 전환 시험
├── migration/              # DB 담당자 관리
└── v1/                     # 기존 부하 시험
scripts/                    # 설정 편집·배포·DB 작업 도구
.github/workflows/          # 릴리즈 번들과 배포 워크플로
releases/                   # 서비스별 배포 버전 조합
```

## 관리 범위

- Terraform: 인프라와 최초 태스크 정의·서비스 생성
- 서비스 CD: 이후 이미지·태스크 리비전 배포
- DNS·CloudFront: 서비스 도메인의 DNS 대상과 CloudFront 요청 원본을 각각 확인한 뒤 변경
- `infra/v1/dns.tf`: 루트 도메인을 v1 EIP로 정의하므로 수동 운영 DNS와 대조 후 적용
- DB 복제·데이터 이관·DB 롤백: DB 담당자가 관리
- 비밀값: Git에 저장하지 않고 SSM·Secrets Manager 또는 EC2 환경파일로 주입

<details>
<summary>기존 v1 배포와 Release Bundle</summary>

- `docker-compose.yml`: EC2의 FE·BE·AI·MySQL·Nginx 구성
- `docker-compose.local.yml`: 로컬 개발 구성
- `nginx/`, `scripts/deploy.sh`, `scripts/rollback.sh`: 기존 EC2 배포
- `releases/v*.yaml`: 서비스 이미지 태그·digest·커밋 정보
- `.github/workflows/create-release-bundle.yml`: 릴리즈 번들 생성

</details>
