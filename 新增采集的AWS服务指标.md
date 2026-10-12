# 如何给 YACE 新增要采集的 AWS 服务指标

适用于本仓库在 EKS 上的部署。改配置 = 改 `yace-values.yaml` 的 `config` 块 + `helm upgrade`。

贯穿全文的一条原则：**不要凭记忆写指标名和维度，先用 CLI 查实际有什么**。
CloudWatch 里不存在的指标名不会报错，只会静默返回空 —— 这是最常见的「配了但没数据」的原因。

---

## 一、先选 job 类型

| 情况 | 用哪种 | 说明 |
|---|---|---|
| 服务在 YACE 支持列表里，且资源**打了 Tag** | `discovery` | 首选。自动发现资源，Tag 自动变 label |
| 服务在支持列表里，但资源**没打 Tag** | `static` | 需手工写死 dimension 值 |
| 服务**不在**支持列表里（含业务自定义指标） | `customNamespace` | 不走 Tagging API，直接按 namespace + dimension 抓 |

判断服务是否被支持：看 YACE README 的 "Supported services with auto discovery through tags" 列表，
或直接搜仓库：

```bash
curl -sL https://raw.githubusercontent.com/prometheus-community/yet-another-cloudwatch-exporter/v0.68.0/README.md \
  | grep -i 'AWS/RDS'
```

> `discovery` 的 `type` 字段既接受别名（`rds`）也接受完整 namespace（`AWS/RDS`）。
> **统一写完整 namespace**，别名在不同版本间不稳定。

---

## 二、操作流程（四步）

### 第 1 步：查这个服务实际有哪些指标

```bash
REGION=us-west-2
NS=AWS/RDS

# 列出该 namespace 下最近 3 小时有数据的指标名（去重）
aws cloudwatch list-metrics --region $REGION --namespace $NS --recently-active PT3H \
  --query 'Metrics[].MetricName' --output text | tr '\t' '\n' | sort -u
```

加 `--recently-active PT3H` 很重要：CloudWatch 会保留已删除资源的指标定义，
不加这个参数会列出一堆早就没数据的指标。

### 第 2 步：查这些指标的维度组合

维度决定了导出后的 `dimension_*` label，也决定 `dimensionNameRequirements` 怎么写。

```bash
aws cloudwatch list-metrics --region $REGION --namespace $NS \
  --metric-name CPUUtilization --recently-active PT3H \
  --query 'Metrics[].Dimensions' --output json
```

典型输出会告诉你同一个指标存在**多种维度组合**。例如 OpenSearch 的 `CPUUtilization`
同时有 `[ClientId, DomainName]`（集群聚合）和 `[ClientId, DomainName, NodeId]`（单节点）两种 ——
两种都会被导出，查询时要用 `dimension_NodeId!=""` 之类的条件区分。

如果只想要其中一种，在 job 上加：

```yaml
dimensionNameRequirements: [ClientId, DomainName]   # 精确匹配这个组合，其他丢弃
```

### 第 3 步：确认指标的发布周期（决定 period/length）

**这是最容易踩的坑。** `period` 小于指标的实际发布周期 → 曲线断断续续或完全没数据。

```bash
# 看某指标最近 1 小时的实际数据点时间戳，相邻间隔就是发布周期
aws cloudwatch get-metric-statistics --region $REGION --namespace $NS \
  --metric-name CPUUtilization \
  --dimensions Name=DBInstanceIdentifier,Value=<你的实例> \
  --start-time "$(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time   "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 60 --statistics Average \
  --query 'sort_by(Datapoints,&Timestamp)[].Timestamp' --output text | tr '\t' '\n'
```

常见规律：

| 服务类型 | 发布周期 | 建议 period / length |
|---|---|---|
| 多数服务默认 | 300s | `300` / `600` |
| EC2 开了详细监控 | 60s | `60` / `300` |
| ALB / NLB / Lambda / SQS | 60s | `60` / `300` |
| **S3 存储类指标**（BucketSizeBytes、NumberOfObjects） | **86400s（日）** | `86400` / `172800` |
| Billing | 数小时 | `86400` / `172800` |
| OpenSearch / RDS | 60s（部分 300s） | `300` / `600` |

规则：`length >= period`，且 `length` 至少覆盖 2 个周期（给 CloudWatch 出数延迟留余量）。
不确定就先用 `300/600` 跑通，再往下调。

### 第 4 步：写进配置

在 `yace-values.yaml` 的 `config:` → `discovery.jobs:` 下追加。模板：

```yaml
      - type: AWS/RDS                 # 完整 namespace
        regions: [us-west-2]
        period: 300
        length: 600
        statistics: [Average, Maximum] # job 级默认，可被单个 metric 覆盖
        nilToZero: true                # CloudWatch 返回空时导出 0 而不是 NaN
        # searchTags:                  # 只采集带指定 Tag 的资源（value 是正则）
        #   - key: Env
        #     value: ^(prod|staging)$
        # roles:                       # 跨账号
        #   - {}                       # 本账号
        #   - roleArn: "arn:aws:iam::111111111111:role/yace-cloudwatch-readonly"
        metrics:
          - name: CPUUtilization
          - name: DatabaseConnections
          - name: FreeStorageSpace
          - name: ReadLatency
            statistics: [Average, p99]  # 覆盖 job 级设置
          - name: WriteLatency
            statistics: [Average, p99]
```

如果资源没打 Tag，改用 `static`（注意 `static` 和 `discovery` 是**平级**的顶层字段）：

```yaml
  static:
    - name: nat-gateway-metrics       # 必填，任意标识
      namespace: AWS/NATGateway
      regions: [us-west-2]
      dimensions:
        - name: NatGatewayId
          value: nat-0abc123def456
      metrics:
        - name: BytesOutToDestination
          statistics: [Sum]
          period: 300
          length: 600
```

业务自定义指标用 `customNamespace`：

```yaml
  customNamespace:
    - name: my-app
      namespace: MyCompany/OrderService
      regions: [us-west-2]
      dimensionNameRequirements: [ServiceName, Stage]
      metrics:
        - name: OrderLatency
          statistics: [Average, p95]
          period: 60
          length: 300
```

---

## 三、补 IAM 权限

绝大多数服务**不需要**额外权限 —— `tag:GetResources` + 3 个 cloudwatch 读权限就够。
只有下面这些 namespace 的资源发现需要额外 API：

| 新增 namespace | 需要追加的 action |
|---|---|
| `AWS/ApiGateway` | `apigateway:GET` |
| `AWS/AutoScaling` | `autoscaling:DescribeAutoScalingGroups` |
| `AWS/DMS` | `dms:DescribeReplicationInstances`、`dms:DescribeReplicationTasks` |
| `AWS/EC2Spot` | `ec2:DescribeSpotFleetRequests` |
| `AWS/TransitGateway` | `ec2:DescribeTransitGatewayAttachments` |
| `AWS/StorageGateway` | `storagegateway:ListGateways`、`storagegateway:ListTagsForResource` |
| `AWS/DDoSProtection` | `shield:ListProtections` |
| `AWS/Prometheus` | `aps:ListWorkspaces` |

本仓库的 `iam-policy-yace.json` 已经把上面全部包含了，所以**通常不用动**。
真需要改时（例如加了 ALB 的 target group 发现）：

```bash
aws iam create-policy-version \
  --policy-arn arn:aws:iam::123456789012:policy/g2610-yace-cloudwatch-readonly \
  --policy-document file://iam-policy-yace.json \
  --set-as-default
```

AK/SK 身份用的是同一个 policy，改完立即生效，**不需要重启 YACE**。

---

## 四、发布与验证

```bash
cd eks

# 1) 先本地校验 YAML 语法，避免把 pod 搞成 CrashLoop
helm template yace prometheus-community/prometheus-yet-another-cloudwatch-exporter \
  --version 0.48.0 -f yace-values.yaml > /dev/null && echo "模板 OK"

# 2) 发布
helm upgrade --install yace \
  prometheus-community/prometheus-yet-another-cloudwatch-exporter \
  --version 0.48.0 -n monitoring -f yace-values.yaml --wait

# 3) 配置解析是否通过（配置有错 YACE 会直接退出，不是静默忽略）
kubectl -n monitoring logs -l app.kubernetes.io/instance=yace --tail=30
```

等一个 `scraping-interval`（当前 120s）后验证新指标：

```bash
kubectl -n monitoring port-forward svc/yace-prometheus-yet-another-cloudwatch-exporter 5000:80 &
sleep 5

# 新服务的指标是否出现（注意 YACE 把指标名转成了 snake_case）
curl -s --noproxy '*' http://127.0.0.1:5000/metrics | grep '^aws_rds_'

# 各服务指标条数总览
curl -s --noproxy '*' http://127.0.0.1:5000/metrics \
  | grep '^aws_' | sed 's/{.*//' | cut -d_ -f2 | sort | uniq -c | sort -rn
```

> macOS 上 curl 本机端口若返回 403，加 `--noproxy '*'` 且用 `127.0.0.1` 而非 `localhost`。

指标命名规则：`aws_<service>_<metric_snake_case>_<statistic>`。
举几个实际对应关系，注意连写缩写的处理不直观：

| CloudWatch 指标 | 导出后 |
|---|---|
| `AWS/RDS` `CPUUtilization` / Average | `aws_rds_cpuutilization_average` |
| `AWS/RDS` `FreeStorageSpace` / Average | `aws_rds_free_storage_space_average` |
| `AWS/ES` `JVMMemoryPressure` / Average | `aws_es_jvmmemory_pressure_average` |
| `AWS/ES` `ClusterStatus.green` / Maximum | `aws_es_cluster_status_green_maximum` |
| `AWS/ApplicationELB` `HTTPCode_Target_5XX_Count` / Sum | `aws_applicationelb_httpcode_target_5_xx_count_sum` |
| `AWS/S3` `BucketSizeBytes` / Average | `aws_s3_bucket_size_bytes_average` |

拿不准就直接 `grep` 一下 `/metrics`，别猜。

最后确认 Prometheus 也收到了：

```bash
kubectl -n monitoring port-forward svc/kps-prometheus 9090:9090 &
curl -s --noproxy '*' --data-urlencode 'query=count by (__name__)({__name__=~"aws_rds_.*"})' \
  http://127.0.0.1:9090/api/v1/query | jq -r '.data.result[] | "\(.metric.__name__) \(.value[1])"'
```

---

## 五、每次新增都要评估成本

CloudWatch `GetMetricData` **按请求的指标数计费**（约 $0.01 / 1000 metrics requested），
不是按请求次数。新增一个服务的成本增量大致是：

```
资源数 × 指标数 × statistics 数 × (每天 86400 / scraping-interval)
```

举例：100 个 RDS 实例 × 5 个指标 × 2 个 statistics × (86400/300) = 288,000 指标/天
→ 约 $0.086/天 ≈ $2.6/月。单个服务不贵，但服务和账号一多就是线性叠加。

发布前后对比实际值：

```bash
curl -s --noproxy '*' http://127.0.0.1:5000/metrics \
  | grep yace_cloudwatch_getmetricdata_metrics_requested_total
```

Grafana 看板第一行已有「预估月度 CloudWatch API 费用」面板，新增服务后看那里最直观。

四个控成本的手段，按效果排序：

1. **拉长 `scraping-interval`** —— 120s → 300s 直接省 60%。生产建议 300s。
2. **`searchTags` 收窄资源范围** —— 只采生产环境的资源。
3. **`recentlyActiveOnly: true`** —— 只拉最近 3 小时活跃的指标，对有大量闲置资源的账号很有效。
4. **砍掉用不到的 statistics** —— 每个 statistic 都单独计费。只要 `Average` 就别带上 `Maximum`。

---

## 六、排错对照表

| 现象 | 原因 | 处理 |
|---|---|---|
| Pod CrashLoopBackOff，日志有 `couldn't read config` | 配置语法错或字段非法 | 看日志最后一行，YACE 会明确指出哪个字段 |
| 日志 `Invalid key in 'exportedTagsOnMetrics', use namespace ... rather than alias` | v0.68 起该字段必须用完整 namespace | 把 `ec2` 改成 `AWS/EC2`。上游文档此处示例是过时的 |
| 日志 `No metrics data found`，某 namespace 无指标 | 该服务在这个 region 没有资源/没数据 | 正常现象，不是错误。确认资源存在再排查 |
| 指标名 grep 不到 | 指标名写错，或该指标在 CloudWatch 不存在 | 回到第 1 步用 `list-metrics` 核对 |
| 指标出现了但值是 `NaN` | CloudWatch 返回空数据点 | 加 `nilToZero: true`；或 period 太小，回到第 3 步 |
| 曲线断断续续 | `period` 小于指标实际发布周期 | 调大 `period` 和 `length`，见第 3 步表格 |
| 资源一个都发现不到 | 资源没打 Tag（discovery 依赖 Tagging API） | 给资源打 Tag，或改用 `static` job |
| 只发现了部分资源 | `searchTags` 过滤掉了 | `value` 是**正则**不是全等，检查是否写窄了 |
| 日志有 throttling / rate exceeded | 并发太高被 CloudWatch 限流 | 降 `cloudwatch-concurrency`，或开 `-cloudwatch-concurrency.per-api-limit-enabled` 分 API 限流 |
| 全局服务（CloudFront/Route53/Billing/WAF）没数据 | 这些指标只在 **us-east-1** 发布 | job 的 `regions` 里加 `us-east-1` |
| 跨账号某账号无数据 | 目标账号角色不存在或信任策略不对 | 见 `cross-account-target-role.md`；日志会打出 AssumeRole 失败 |

---

## 七、常用服务配方

直接复制到 `discovery.jobs` 下，按需裁剪 `metrics`。

<details>
<summary>ALB / NLB</summary>

```yaml
      - type: AWS/ApplicationELB
        regions: [us-west-2]
        period: 60
        length: 300
        statistics: [Sum, Average]
        nilToZero: true
        metrics:
          - name: RequestCount
          - name: HTTPCode_Target_2XX_Count
          - name: HTTPCode_Target_4XX_Count
          - name: HTTPCode_Target_5XX_Count
          - name: HTTPCode_ELB_5XX_Count
          - name: TargetResponseTime
            statistics: [Average, p95, p99]
          - name: UnHealthyHostCount
            statistics: [Maximum]
          - name: RejectedConnectionCount
```
</details>

<details>
<summary>RDS / Aurora</summary>

```yaml
      - type: AWS/RDS
        regions: [us-west-2]
        period: 300
        length: 600
        statistics: [Average, Maximum]
        nilToZero: true
        metrics:
          - name: CPUUtilization
          - name: DatabaseConnections
          - name: FreeableMemory
          - name: FreeStorageSpace
          - name: ReadLatency
          - name: WriteLatency
          - name: ReadIOPS
          - name: WriteIOPS
          - name: ReplicaLag
          - name: DiskQueueDepth
```
</details>

<details>
<summary>Lambda</summary>

```yaml
      - type: AWS/Lambda
        regions: [us-west-2]
        period: 60
        length: 300
        statistics: [Sum, Average]
        nilToZero: true
        metrics:
          - name: Invocations
          - name: Errors
          - name: Throttles
          - name: Duration
            statistics: [Average, Maximum, p99]
          - name: ConcurrentExecutions
            statistics: [Maximum]
```
</details>

<details>
<summary>DynamoDB</summary>

```yaml
      - type: AWS/DynamoDB
        regions: [us-west-2]
        period: 60
        length: 300
        statistics: [Sum, Average]
        nilToZero: true
        metrics:
          - name: ConsumedReadCapacityUnits
          - name: ConsumedWriteCapacityUnits
          - name: ThrottledRequests
          - name: UserErrors
          - name: SystemErrors
          - name: SuccessfulRequestLatency
            statistics: [Average, p99]
```
</details>

<details>
<summary>ElastiCache</summary>

```yaml
      - type: AWS/ElastiCache
        regions: [us-west-2]
        period: 60
        length: 300
        statistics: [Average, Maximum]
        nilToZero: true
        metrics:
          - name: CPUUtilization
          - name: EngineCPUUtilization
          - name: DatabaseMemoryUsagePercentage
          - name: CacheHits
          - name: CacheMisses
          - name: Evictions
          - name: CurrConnections
          - name: ReplicationLag
```
</details>

<details>
<summary>API Gateway（需 apigateway:GET 权限）</summary>

```yaml
      - type: AWS/ApiGateway
        regions: [us-west-2]
        period: 60
        length: 300
        statistics: [Sum, Average]
        nilToZero: true
        metrics:
          - name: Count
          - name: 4XXError
          - name: 5XXError
          - name: Latency
            statistics: [Average, p99]
          - name: IntegrationLatency
            statistics: [Average, p99]
```
</details>

<details>
<summary>CloudFront（注意 region 必须是 us-east-1）</summary>

```yaml
      - type: AWS/CloudFront
        regions: [us-east-1]      # 全局服务，指标只在 us-east-1 发布
        period: 300
        length: 600
        statistics: [Sum, Average]
        nilToZero: true
        metrics:
          - name: Requests
          - name: BytesDownloaded
          - name: BytesUploaded
          - name: 4xxErrorRate
          - name: 5xxErrorRate
          - name: OriginLatency
            statistics: [Average, p99]
```
</details>

<details>
<summary>EKS ContainerInsights（依赖 CloudWatch agent 已部署）</summary>

```yaml
      - type: ContainerInsights
        regions: [us-west-2]
        period: 60
        length: 300
        statistics: [Average, Maximum]
        nilToZero: true
        metrics:
          - name: node_cpu_utilization
          - name: node_memory_utilization
          - name: pod_cpu_utilization
          - name: pod_memory_utilization
          - name: cluster_failed_node_count
```

> 集群内已有 Prometheus + node-exporter + kube-state-metrics 的话，
> 这些指标是重复的，而且 Prometheus 原生采集更实时、更便宜。
> **一般不建议**通过 CloudWatch 绕一圈拿 K8s 指标。
</details>

<details>
<summary>MSK / Kafka</summary>

```yaml
      - type: AWS/Kafka
        regions: [us-west-2]
        period: 300
        length: 600
        statistics: [Average, Maximum]
        nilToZero: true
        metrics:
          - name: BytesInPerSec
          - name: BytesOutPerSec
          - name: KafkaDataLogsDiskUsed
          - name: OfflinePartitionsCount
          - name: UnderReplicatedPartitions
          - name: MaxOffsetLag
```
</details>

---

## 八、Grafana 看板同步

新增服务后，看板不会自动出现对应面板。更新流程：

```bash
# 1) 编辑 eks/dashboards/yace-cloudwatch.json 加面板
# 2) 更新 ConfigMap（sidecar 会在 30 秒内自动重载，不用重启 Grafana）
kubectl -n monitoring create configmap yace-dashboard \
  --from-file=yace-cloudwatch.json=dashboards/yace-cloudwatch.json \
  --dry-run=client -o yaml \
  | kubectl label -f - grafana_dashboard=1 --local --dry-run=client -o yaml \
  | kubectl apply -f -
```

面板里数据源要写 `{"type":"prometheus","uid":"prometheus"}` —— uid 是**小写**，
写成显示名 `Prometheus` 会导致面板无数据。

也可以在 Grafana UI 里直接画，调好后用 Dashboard → Share → Export 导出 JSON 存回仓库，
避免下次重建丢失（Grafana 的 PVC 不是可靠的配置载体）。
