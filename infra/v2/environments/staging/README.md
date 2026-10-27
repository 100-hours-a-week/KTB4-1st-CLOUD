# 스테이징 재구축

- 목적: prod와 같은 ECS·ASG·ALB·Kafka·Valkey·RDS 구성으로 전환 리허설
- 환경 분리: staging VPC·도메인·SSM·업로드 버킷·state 사용
- 기존 DB 네트워크·RDS 보존, DB 복제본·이관 스크립트는 DB 담당자 관리
- 실행 조건: 초기 이미지·SSM 설정·보존 자원 인계 확인 후 전체 plan 검토

## 준비

| 항목 | 확인 내용 |
|---|---|
| state | `v2/staging/terraform.tfstate`, DB 네트워크는 `moved.tf`로 platform 주소에 인계 |
| 기존 자원 | AWS에 남은 CloudFront·S3·OAC·서명키·인증서·DNS의 실제 ID와 state 소유권 확인 |
| state 인계 | 다른 state에서 관리하지 않는 기존 자원은 정확한 platform 주소에 import 후 plan 실행 |
| RDS | 기존 DB 인스턴스·VPC·private subnet·데이터 유지. 교체·삭제 계획 시 적용 중지 |
| 이미지 | `initial_image_digests`에 be·fe·ai 지정. FE는 staging URL로 빌드 |
| 런타임 | staging SSM의 필수 일반값·비밀값, Valkey 암호·이미지 서명키 준비 |
| DNS | `publish_service_dns=false` 기본값 유지. 시험 서비스 DNS·CloudFront 원본은 별도 전환 |
| 배포 | 재구축 후 staging GitHub Environment의 역할 ARN·FE 버킷·CloudFront ID 확인 |

- state에 없는 기존 CloudFront·버킷을 그대로 생성하면 충돌할 수 있으므로 먼저 인계
- `moved.tf`는 state 주소 이전 선언. 파일 수정만으로 AWS나 원격 state를 변경하지 않음
- CloudFront 원본은 DNS와 별개이므로 재구축 plan에서 수동 원본 변경도 확인

<details>
<summary>로컬 실행 명령</summary>

```bash
terraform -chdir=infra/v2/environments/staging init
terraform -chdir=infra/v2/environments/staging validate
terraform -chdir=infra/v2/environments/staging plan -out=tfplan
# 기존 자원 인계·DB 보존·원본/DNS 변경 검토 후 실행
terraform -chdir=infra/v2/environments/staging apply tfplan
```

</details>
