#!/usr/bin/env bash
# 拆掉 POC 的全部资源。请逐段确认后执行，不要无脑 bash 一把梭。
set -euo pipefail

REGION=us-west-2
CLUSTER=g2610-yace
ACCOUNT=123456789012
IAM_USER=g2610-yace-exporter
POLICY_ARN="arn:aws:iam::${ACCOUNT}:policy/g2610-yace-cloudwatch-readonly"

echo ">>> 1/4 卸载 Helm releases（先删，让 LB / PVC 能被正常回收）"
helm -n monitoring uninstall yace            || true
helm -n monitoring uninstall kube-prometheus-stack || true

echo ">>> 2/4 删掉 PVC（Helm 不会自动删 StatefulSet 的 PVC，留着会一直计 EBS 费用）"
kubectl -n monitoring delete pvc --all --ignore-not-found

echo ">>> 3/4 删除 EKS 集群（含 VPC/NAT/节点组，约 10-15 分钟）"
eksctl delete cluster --name "${CLUSTER}" --region "${REGION}" --wait

echo ">>> 4/4 删除 IAM user / access key / policy"
for AK in $(aws iam list-access-keys --user-name "${IAM_USER}" \
              --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null || true); do
  echo "    删除 access key ${AK}"
  aws iam delete-access-key --user-name "${IAM_USER}" --access-key-id "${AK}"
done
aws iam detach-user-policy --user-name "${IAM_USER}" --policy-arn "${POLICY_ARN}" 2>/dev/null || true
aws iam delete-user --user-name "${IAM_USER}" 2>/dev/null || true
aws iam delete-policy --policy-arn "${POLICY_ARN}" 2>/dev/null || true

echo ">>> 本地残留凭证"
rm -f /tmp/yace-ak.json

echo "完成。建议到 Cost Explorer 确认次日无残留计费。"
echo "注意：目标账号里手工建的 yace-cloudwatch-readonly 角色需要在各账号单独删除。"
