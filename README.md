# 바꾸까 - 인프라 레포

바꾸까 프로젝트 인프라 레포. IaC 코드와 배포 버전 조합을 관리한다.

## 이 레포가 하는 일

- FE/BE/AI 등 멀티 레포에서 배포 가능한 버전 조합(Release Bundle)을 기록
- IaC 코드 관리 (`infra/`)

## 디렉토리 구조

```
KTB4-1st-CLOUD/
├── infra/
│   └── v1/
│       ├── main.tf
│       ├── variables.tf
│       ├── network.tf
│       ├── iam.tf
│       ├── s3.tf
│       ├── compute.tf
│       ├── dns.tf
│       ├── outputs.tf
│       └── terraform.tfvars.example
├── docker-compose.yml
├── nginx
└── README.md
```

- `infra/` : IaC(Terraform) 코드. 단계별 설계·구성 이유는 위키의 [v1 IaC 도입 및 구성](https://github.com/100-hours-a-week/KTB4-1st-CLOUD/wiki/Cloud-Dev-1st-IaC) 문서를 따른다
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
