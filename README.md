# 바꾸까 - 인프라 레포

바꾸까 프로젝트 인프라 레포. IaC 코드와 배포 버전 조합을 관리한다.

## 이 레포가 하는 일

- FE/BE/AI 등 멀티 레포에서 배포 가능한 버전 조합(Release Bundle)을 기록
- IaC 코드 관리 (`infra/`)

## 디렉토리 구조

```
KTB4-1st-CLOUD/
├── .github/workflows/       # 릴리즈와 배포 워크플로
├── infra/
│   ├── iam/                 # tobby·janna 계정과 공통 운영 권한
│   ├── v1/                  # v1 인프라
│   └── v2/
│       ├── environments/    # prod와 staging 및 dev 실행 폴더
│       └── modules/         # 공통 플랫폼과 RDS 및 Serverless Valkey
├── releases/                # 서비스별 배포 버전 조합
├── scripts/                 # 배포와 롤백
├── loadtest/                # 부하 테스트
├── docker-compose.yml       # v1 운영 컨테이너
├── docker-compose.local.yml # 로컬 개발 컨테이너
├── nginx/                   # v1 프록시 설정
└── README.md
```

- `infra/` : IaC(Terraform) 코드. 단계별 설계·구성 이유는 위키의 [v1 IaC 도입 및 구성](https://github.com/100-hours-a-week/KTB4-1st-CLOUD/wiki/Cloud-Dev-1st-IaC) 문서를 따른다
- 인프라 담당자 계정과 권한은 [infra/iam](infra/iam/README.md), v2 인프라는 [infra/v2](infra/v2/README.md)에서 관리한다.
- `docker-compose.yml` : v1 EC2 위에서 띄울 컨테이너 정의. 비밀값은 `.env`(커밋 안 함)로 주입

`releases/`는 배포 버전 조합, `.github/workflows/`는 릴리즈와 배포 워크플로, `nginx/`는 프록시 설정, `scripts/`는 배포와 롤백 스크립트를 관리한다.

## 배포 버전 관리 (Release Bundle)
- `releases/` 아래 릴리즈마다 새 파일(`v{MAJOR}.{MINOR}.{PATCH}.yaml`)을 만든다.
- 이유
  - 롤백 시 과거 여러 버전을 동시에 참조해야 하는데, 파일이 나뉘어 있으면 디렉토리 정렬만으로 순회 가능
  - 과거 버전들이 각각 독립 파일로 남아 "언제든 배포 가능한 후보" 역할을 수행
- 파일 내용: 각 서비스(FE/BE/AI)의 이미지 태그, 커밋 SHA, 빌드 시각 등 (`create-release-manifest` 워크플로우로 자동 생성)
- 상세 배포/롤백 정책은 위키의 [CD(지속적 배포) 설계](https://github.com/100-hours-a-week/KTB4-1st-wiki/wiki/Cloud-Design-3rd) 문서를 따른다.

## 브랜치 보호 규칙
- main에 직접 push 불가, PR 필수
