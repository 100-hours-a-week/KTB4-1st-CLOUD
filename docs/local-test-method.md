# 🚀 로컬 환경 실행 및 테스트 가이드 (Mac 기준)

본 문서는 `docker-compose.local.yml`과 `nginx/local.conf` 설정을 활용하여 로컬 개발/테스트 환경을 구축하고, GitHub Container Registry(GHCR)의 최신 이미지를 반영하는 방법을 안내합니다.

---

## 1. 사전 준비: Docker 설치 (Mac)

### 1-1. Docker Desktop 설치
1. **Homebrew를 이용한 설치 (권장)**:
   터미널을 열고 아래 명령어를 실행합니다.
   ```bash
   brew install --cask docker
   ```
2. **수동 다운로드 (Homebrew 미사용 시)**:
    - [Docker 공식 홈페이지](https://www.docker.com/products/docker-desktop/) 접속
    - 본인 Mac 칩셋에 맞는 버전 선택 (**Apple Silicon (M1/M2/M3/M4)** 또는 **Intel**) 다운로드 후 설치

### 1-2. Docker Desktop 실행 및 리소스 설정
1. `Applications(응용 프로그램)` 폴더에서 **Docker Desktop**을 실행합니다.
2. 상단 메뉴 바의 고래 아이콘 → **Settings(설정)** → **Resources**로 이동합니다.
3. 서비스 전체 구동을 위해 메모리를 **최소 4GB 이상 (권장 6GB~8GB)**으로 설정 후 **Apply & Restart**를 클릭합니다.
4. 터미널에서 정상 구동 여부를 확인합니다.
   ```bash
   docker --version
   docker compose version
   ```

---

## 2. GHCR (GitHub Packages) 로그인

프로젝트 컨테이너 이미지를 ghcr.io에서 다운로드(pull)받기 위해 1회 로그인이 필요합니다.

1. **GitHub Personal Access Token(PAT) 준비**:
    - GitHub > Settings > Developer settings > Personal access tokens (classic)
    - 권한 중 **`read:packages`** 체크 후 토큰 생성 및 복사
2. **터미널에서 Docker 로그인**:
   ```bash
   echo "YOUR_GITHUB_PAT" | docker login ghcr.io -u "YOUR_GITHUB_USERNAME" --password-stdin
   ```
   > `Login Succeeded` 문구가 출력되면 완료됩니다.

---

## 3. 디렉토리 구조 및 `.env` 파일 설정

### 3-1. 필수 파일 위치 확인
프로젝트 루트 디렉토리 구조가 아래와 같은지 확인합니다.
```text
프로젝트_루트/
├── .env                        # 팀 내 공유받은 환경 변수 파일 (신규 생성)
├── docker-compose.local.yml
└── nginx/
    └── local.conf
```

### 3-2. `.env` 파일 생성
프로젝트 루트 경로에서 `.env` 파일을 생성하고 팀 노션에 공유된 내용을 그대로 붙여넣습니다.

```bash
# 루트 경로에서 파일 생성
vi .env
```

> **참고 (`.env` 포함 항목):**
> - GHCR 이미지 경로: `FASTAPI_IMAGE`, `SPRINGBOOT_IMAGE`, `NEXTJS_IMAGE`
> - 데이터베이스: `MYSQL_ROOT_PASSWORD`, `MYSQL_DATABASE`, `MYSQL_USER`, `MYSQL_PASSWORD`
> - 백엔드/AI 키: `ANTHROPIC_API_KEY`, `JWT_SECRET`, `KAKAO_*` 등 

특정 버전을 지정하여 테스트할 경우 [Docker Build Images]에서 이미지 태그(현재 latest)를 수정합니다.<br>
예) `latest` --> `v1.0.0`<br>
사용 가능한 컨테이너 이미지는 각 파트 repository의 packages에서 확인할 수 있습니다.

---

## 4. 로컬 환경 구동

### 4-1. 서비스 실행 (백그라운드)
프로젝트 루트 디렉토리에서 다음 명령어를 실행합니다.

```bash
docker compose -f docker-compose.local.yml up -d
```

> **구동 순서 안내:**
> MySQL 및 FastAPI의 헬스체크 통과 → Spring Boot 기동 → Next.js 및 Nginx 기동 순으로 순차 실행됩니다. Spring Boot의 초기 웜업으로 인해 최종 정상 상태까지 약 40~60초가 소요될 수 있습니다.

### 4-2. 구동 상태 확인
모든 컨테이너의 STATUS가 `Up (healthy)` 상태인지 확인합니다.

```bash
docker compose -f docker-compose.local.yml ps
```

### 4-3. 접속 확인
브라우저를 열고 서비스에 접속합니다.
- **웹 서비스 (Next.js)**: `http://localhost` 또는 `http://127.0.0.1`
- **백엔드 API 직접 호출**: `http://localhost/api/{엔드포인트}`

---

## 5. 새로운 컨테이너 이미지 반영 (배포 업데이트)

GitHub Actions를 통해 새 이미지가 GHCR에 push되었을 때, 로컬에 최신 버전을 반영하는 방법입니다.

```bash
# 1. 최신 이미지 일괄 다운로드
docker compose -f docker-compose.local.yml pull

# 2. 새 이미지 기반 컨테이너 재생성 및 재시작
docker compose -f docker-compose.local.yml up -d

# 3. (선택) 이전 버전의 사용하지 않는 댕글링(Dangling) 이미지 정리
docker image prune -f
```

특정 서비스만 새로 내려받고 재시작하려는 경우:
```bash
# 예: 백엔드(springboot)만 새로 반영할 때
docker compose -f docker-compose.local.yml pull springboot
docker compose -f docker-compose.local.yml up -d springboot
```

---

## 6. 일상 작업 및 유용한 명령어

### 로그 모니터링
```bash
# 전체 로그 실시간 확인
docker compose -f docker-compose.local.yml logs -f

# 특정 컨테이너 로그만 확인 (예: springboot, fastapi, nextjs)
docker compose -f docker-compose.local.yml logs -f springboot
```

### 컨테이너 중지
```bash
# 데이터(DB 볼륨)는 보존하고 컨테이너만 중지
docker compose -f docker-compose.local.yml down
```

### DB 데이터 초기화 (완전 리셋 필요 시)
```bash
# 컨테이너 및 볼륨(mysql-data 등)을 모두 삭제 후 초기화
docker compose -f docker-compose.local.yml down -v
```

---

## 7. 자주 발생하는 문제 해결 (Troubleshooting)

### Q1. `Bind for 0.0.0.0:80 failed: port is already allocated` 에러 발생 시
- Mac의 로컬 웹 서버(Apache 등)나 다른 프로그램이 80 포트를 점유 중인 상태입니다.
- 점유 프로세스 확인 후 종료:
  ```bash
  sudo lsof -i :80
  # 확인된 PID를 종료: kill -9 <PID>
  ```

### Q2. Spring Boot 컨테이너가 계속 `starting`이거나 재부팅되는 경우
- Docker Desktop의 메모리가 부족하여 JVM 구동 중 OOM(Out of Memory)이 발생했을 수 있습니다.
- Docker Desktop 설정에서 할당 메모리를 **6GB 이상**으로 상향 조정하세요.

### Q3. GHCR Pull 시 `denied: denied to access the resource` 에러 발생 시
- GHCR 토큰 권한이 만료되었거나 `read:packages` 권한이 누락된 경우입니다.
- **2. GHCR 로그인** 단계를 다시 수행하세요.