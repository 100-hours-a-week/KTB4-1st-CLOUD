# v1 state에서 removed 적용 후 기존 계정과 그룹을 인계
import {
  to = aws_iam_group.infra_admin
  id = "Infra-Admin"
}

import {
  for_each = toset(["tobby", "janna"])
  to       = aws_iam_user.infra_admin[each.value]
  id       = each.value
}

import {
  for_each = toset(["tobby", "janna"])
  to       = aws_iam_user_group_membership.infra_admin[each.value]
  id       = "${each.value}/Infra-Admin"
}

import {
  to = aws_iam_group_policy.infra_admin
  id = "Infra-Admin:infra-admin-policy"
}
