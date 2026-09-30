# Terraform 인수인계

## 1. 전달 항목

| 항목 | 내용 | 비고 |
|---|---|---|
| AWS 액세스 키 | IAM 사용자 `bootstrap-admin` (AdministratorAccess) | 계정 전체 관리자 권한이다. `~/.aws/credentials`에 프로필로 저장 |
| 리전 | `ap-northeast-2` | `~/.aws/config` |
| Terraform | 1.16.x (코드 요구사항은 `>= 1.7`) | AWS provider는 `.terraform.lock.hcl`로 5.100.0 고정 |
| 저장소 | `100-hours-a-week/KTB4-1st-CLOUD`, 작업 디렉터리 `infra/v1` | |
| `terraform.tfvars` | `terraform.tfvars.example`을 복사 | 커밋 금지(.gitignore 처리됨) |
| SSH 공개키 | `~/.ssh/bakkucca_v1.pub` | `compute.tf`가 이 파일을 직접 읽는다. 없으면 plan 실패, 내용이 다르면 key pair가 교체된다. 아래 명령으로 AWS에 등록된 것과 같은 키를 받는다 |

### 첫 설정 확인

```bash
# 0) 전달받은 키를 bakkucca 프로필로 저장 (region: ap-northeast-2)
aws configure --profile bakkucca

# 1) 자격 증명 확인 - Arn이 user/bootstrap-admin 으로 나와야 한다
aws sts get-caller-identity --profile bakkucca

# 2) SSH 공개키를 AWS에 등록된 것과 동일하게 받기
aws ec2 describe-key-pairs --key-names bakkucca-v1 --include-public-key \
  --query 'KeyPairs[0].PublicKey' --output text --profile bakkucca > ~/.ssh/bakkucca_v1.pub

# 3) 초기화 후 plan - "No changes"가 나와야 정상
cd infra/v1
export AWS_PROFILE=bakkucca
terraform init
terraform plan
```

plan을 했을 때 변경 사항이 있으면 안됩니다.

## 2. 작업 규칙 (Terraform으로 할 때)

- **State 잠금이 없다.** plan/apply 전에 채팅으로 알리고, 두 사람이 동시에 apply하지 않는다.
- 시작 전 `git pull`. 코드가 main보다 뒤처진 상태로 apply하면 다른 사람이 추가한 리소스를 지우는 plan이 나온다.
- `terraform destroy`, `terraform state rm/mv`, `terraform import` 지양
- plan에서 아래가 보이면 **즉시 중단**:
  - `aws_instance.v1 must be replaced` (`-/+`) → MySQL 데이터가 EC2 루트 볼륨에 있어 **DB가 사라진다**
  - `aws_key_pair.v1` 교체 → 공개키 파일이 다르다는 뜻
  - `aws_iam_access_key.backend_dev` 교체 → 백엔드 개발자 키가 바뀐다
- `.terraform.lock.hcl`이 바뀌면 같이 커밋한다.