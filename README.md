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
└── releases/
    ├── v1.0.0.yaml
    ├── v1.1.0.yaml # 릴리즈마다 새 파일 생성
    └── ...
```

- `infra/` : IaC 코드
- `releases/` : 배포 시점별 버전 조합 매니페스트

## 배포 버전 관리 (Release Bundle)
- `releases/` 아래 릴리즈마다 새 파일(`v{MAJOR}.{MINOR}.{PATCH}.yaml`)을 만든다.
- 이유
  - 롤백 시 과거 여러 버전을 동시에 참조해야 하는데, 파일이 나뉘어 있으면 디렉토리 정렬만으로 순회 가능
  - 과거 버전들이 각각 독립 파일로 남아 "언제든 배포 가능한 후보" 역할을 수행
- 파일 내용: 각 서비스(FE/BE/AI)의 이미지 태그, 커밋 SHA, 빌드 시각 등 (`create-release-manifest` 워크플로우로 자동 생성)
- 상세 배포/롤백 정책은 위키의 [CD(지속적 배포) 설계](https://github.com/100-hours-a-week/KTB4-1st-wiki/wiki/Cloud-Design-3rd) 문서를 따른다.

## 브랜치 보호 규칙
- main에 직접 push 불가, PR 필수