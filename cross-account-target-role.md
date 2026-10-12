# 跨账号采集配置（目标账号侧）

AK/SK 方案下，监控账号（`123456789012`）的 IAM user `g2610-yace-exporter` 作为**基础身份**，
再去各目标账号 AssumeRole。**每个被监控的目标账号**都要做下面两步。

角色名必须是 `yace-cloudwatch-readonly` —— 监控账号侧的策略里按这个名字授权了
`sts:AssumeRole`（`arn:aws:iam::*:role/yace-cloudwatch-readonly`）。要换名字就同步改 `iam-policy-yace.json`。

## 1. 信任策略（trust policy）

`trust-policy.json`：

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::123456789012:user/g2610-yace-exporter"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "sts:ExternalId": "g2610-yace"
        }
      }
    }
  ]
}
```

> `ExternalId` 不是必须的，但强烈建议加上防混淆代理（confused deputy）。
> 加了之后 YACE 配置里对应的 role 也要写 `externalId`。

## 2. 权限策略 + 建角色

在**目标账号**执行：

```bash
aws iam create-role \
  --role-name yace-cloudwatch-readonly \
  --assume-role-policy-document file://trust-policy.json

# 权限策略直接复用监控账号的那份（去掉 AssumeRole 那条 statement 即可）
aws iam put-role-policy \
  --role-name yace-cloudwatch-readonly \
  --policy-name yace-cloudwatch-readonly \
  --policy-document file://iam-policy-yace.json
```

## 3. YACE 侧配置

在 `yace-values.yaml` 的每个 job 下加 `roles`：

```yaml
jobs:
  - type: AWS/EC2
    regions: [us-west-2]
    roles:
      # 不写 roleArn = 用基础身份采集监控账号自己（123456789012）
      - {}
      # 各目标账号
      - roleArn: "arn:aws:iam::111111111111:role/yace-cloudwatch-readonly"
        externalId: "g2610-yace"
      - roleArn: "arn:aws:iam::222222222222:role/yace-cloudwatch-readonly"
        externalId: "g2610-yace"
    metrics:
      - name: CPUUtilization
```

采集到的指标自带 `account_id` label，Grafana 里可以直接按账号筛选/分组。
把 `iam:ListAccountAliases` 权限留着的话，还会有 `aws_account_info` 指标带出账号别名，
看板上就能显示人类可读的账号名而不是 12 位数字。

## 成本提醒

跨账号是**按账号数线性放大** CloudWatch API 调用的。N 个账号 = N 倍 `GetMetricData` 请求。
铺开前先用 `yace_cloudwatch_getmetricdata_metrics_requested_total` 在单账号实测，再乘以账号数估算。

## 关于 AK/SK 的安全建议

当前方案用的是长期凭证，需要配套：

1. **定期轮转** —— 90 天一轮，用两把 key 交替（创建新 key → 更新 Secret → 滚动重启 YACE → 删旧 key）。
2. **不要把 AK/SK 提交进 Git** —— 本仓库的 Secret 是用 `kubectl create secret` 命令行创建的，没有落盘到仓库。
3. **生产更推荐 IRSA**：给 YACE 的 ServiceAccount 绑一个 IAM Role，再由该 Role 去 AssumeRole 到各目标账号。
   这样集群内没有任何长期凭证，跨账号能力完全一样。切换方式：
   - 删掉 `yace-values.yaml` 里的 `aws.secret`
   - 改为 `serviceAccount.annotations: eks.amazonaws.com/role-arn: <IRSA role arn>`
   - 目标账号的 trust policy 把 Principal 从 user ARN 换成该 IRSA role ARN
