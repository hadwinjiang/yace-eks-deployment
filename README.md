# EKS 上部署 YACE + Prometheus + Grafana

把 CloudWatch 指标接入自建 Grafana 的完整可复现部署。
凭证走 **AK/SK**，便于后续扩展到跨账号采集。

- Region：`us-west-2`
- 集群：`g2610-yace`（EKS 1.34，2 × t3.large，私有子网）
- Namespace：`monitoring`

## 架构

```
                     ┌──────────────── EKS: g2610-yace (us-west-2) ────────────────┐
                     │                                                              │
  CloudWatch API ◄───┤  YACE (1 副本)                                              │
  ├ 本账号           │   └─ Secret: yace-aws-credentials (AK/SK)                   │
  └ 跨账号           │   └─ ServiceMonitor ──┐                                     │
    (AssumeRole)     │                        ▼                                     │
                     │                   Prometheus ──► Grafana                     │
                     │                  (30Gi gp2)      (10Gi gp2, ClusterIP)      │
                     └──────────────────────────────────────────────────────────────┘
```

YACE 后台按固定间隔拉 CloudWatch 并缓存，Prometheus 抓 `/metrics` 读的是缓存 ——
所以 Prometheus 的抓取频率**不会**放大 CloudWatch API 调用，成本只由 `scraping-interval` 决定。

## 文件说明

| 文件 | 用途 |
|---|---|
| `cluster.yaml` | eksctl 集群定义 |
| `iam-policy-yace.json` | YACE 所需的最小只读权限 + 跨账号 AssumeRole |
| `yace-values.yaml` | YACE Helm values，含 7 个 discovery job |
| `kube-prometheus-stack-values.yaml` | Prometheus + Grafana + Alertmanager |
| `dashboards/yace-cloudwatch.json` | Grafana 看板（EC2/OpenSearch/SQS/EBS/S3 + API 成本） |
| `cross-account-target-role.md` | 跨账号目标账号侧的角色配置步骤 |
| `新增采集的AWS服务指标.md` | **如何给 YACE 加新的 AWS 服务/指标**（含常用服务配方、排错表） |
| `构建新的Grafana看板.md` | **如何构建新看板**（面板选型、YACE 查询惯用法、配色、落库发布） |
| `teardown.sh` | 拆除全部资源 |

## 部署步骤

### 1. 建集群（约 15–20 分钟）

```bash
eksctl create cluster -f cluster.yaml
kubectl get nodes
```

### 2. 建 IAM 身份与 AK/SK

```bash
aws iam create-policy --policy-name g2610-yace-cloudwatch-readonly \
  --policy-document file://iam-policy-yace.json

aws iam create-user --user-name g2610-yace-exporter
aws iam attach-user-policy --user-name g2610-yace-exporter \
  --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/g2610-yace-cloudwatch-readonly

aws iam create-access-key --user-name g2610-yace-exporter > /tmp/yace-ak.json
```

### 3. 把 AK/SK 写成 K8s Secret

字段名必须是 `access_key` / `secret_key` —— 这是 YACE chart 约定的。

```bash
kubectl create namespace monitoring

kubectl -n monitoring create secret generic yace-aws-credentials \
  --from-literal=access_key="$(jq -r .AccessKey.AccessKeyId   /tmp/yace-ak.json)" \
  --from-literal=secret_key="$(jq -r .AccessKey.SecretAccessKey /tmp/yace-ak.json)"
```

### 4. 建 gp3 StorageClass

eksctl 默认只给一个 in-tree 的 `gp2`。gp3 更便宜、基线性能更好，且走 EBS CSI driver。

```bash
kubectl apply -f storageclass-gp3.yaml
kubectl annotate sc gp2 storageclass.kubernetes.io/is-default-class=false --overwrite
```

### 5. 装 Prometheus + Grafana

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --version 92.2.0 -n monitoring \
  -f kube-prometheus-stack-values.yaml \
  --set grafana.adminPassword='<自己设一个强密码>' \
  --wait --timeout 15m
```

### 6. 导入 Grafana 看板

```bash
kubectl -n monitoring create configmap yace-dashboard \
  --from-file=yace-cloudwatch.json=dashboards/yace-cloudwatch.json
kubectl -n monitoring label configmap yace-dashboard grafana_dashboard=1
```

sidecar 会在 30 秒内自动加载，不需要重启 Grafana。

### 7. 装 YACE

```bash
helm upgrade --install yace \
  prometheus-community/prometheus-yet-another-cloudwatch-exporter \
  --version 0.48.0 -n monitoring \
  -f yace-values.yaml --wait
```

### 8. 验证

实际部署出来的 Service 名字和端口（和 chart 文档里的示例不一致，按这个来）：

| 组件 | Service | 端口 |
|---|---|---|
| YACE | `yace-prometheus-yet-another-cloudwatch-exporter` | **80** → 容器 5000 |
| Prometheus | `kps-prometheus` | 9090 |
| Grafana | `kube-prometheus-stack-grafana` | 80 |

```bash
# 1) YACE 正常导出指标
kubectl -n monitoring logs -l app.kubernetes.io/instance=yace --tail=20
kubectl -n monitoring port-forward svc/yace-prometheus-yet-another-cloudwatch-exporter 5000:80 &
curl -s --noproxy '*' http://127.0.0.1:5000/metrics | grep -c '^aws_'

# 2) Prometheus 已抓到 YACE target（应为 up）
kubectl -n monitoring port-forward svc/kps-prometheus 9090:9090 &
curl -s --noproxy '*' 'http://127.0.0.1:9090/api/v1/targets?state=active' \
  | jq -r '.data.activeTargets[] | select(.labels.job|test("cloudwatch")) | "\(.health) \(.scrapeUrl)"'

# 3) Grafana
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
# → http://127.0.0.1:3000  (admin / 你设的密码)
```

> **macOS 踩坑**：curl 访问 port-forward 端口返回 `403` 且 size=0，是本机代理设置拦了
> localhost 请求。加 `--noproxy '*'` 并用 `127.0.0.1` 而不是 `localhost`。

> **看板 datasource 踩坑**：kube-prometheus-stack 创建的 Prometheus 数据源 uid 是小写
> `prometheus`。看板里 datasource 变量的 `current.value` 必须填这个 uid（不是显示名
> `Prometheus`），否则所有面板都取不到数。

## 跨账号扩展

见 `cross-account-target-role.md`。要点：目标账号建名为 `yace-cloudwatch-readonly`
的角色，信任监控账号的 IAM user，然后在 `yace-values.yaml` 的 job 里列 `roles[].roleArn`。
指标自带 `account_id` label，Grafana 可按账号筛选。

## 生产化待办

当前是 POC 配置，上生产前需要补：

| 项 | 现状 | 生产建议 |
|---|---|---|
| 凭证 | AK/SK 长期凭证 | 改 IRSA；若必须用 AK/SK，配 90 天轮转 |
| Grafana 访问 | ClusterIP + port-forward | 内网 NLB 或 ALB + OIDC/SSO 认证，不要直接开公网 |
| Grafana 密码 | helm `--set` 传入 | 外部 Secret Manager + External Secrets Operator |
| 抓取间隔 | 120s | 300s（降低 CloudWatch API 费用） |
| 高可用 | YACE 单副本 | 保持单副本（多副本会让 API 费用翻倍）；靠 K8s 自愈 |
| 数据留存 | Prometheus 本地 15d | 长期留存接 Thanos / Mimir / AMP |
| 告警 | Alertmanager 装了但没配 receiver | 接 Slack / 钉钉 / PagerDuty |
| 成本监控 | 看板上有预估 | 对 `yace_cloudwatch_getmetricdata_metrics_requested_total` 配告警 |

## 拆除

```bash
./teardown.sh
```

EKS 集群 + 2 节点约 **$6.5/天**，验证完记得拆。
