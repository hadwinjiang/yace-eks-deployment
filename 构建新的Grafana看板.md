# 如何构建一个新的 Grafana 看板

针对本仓库的 YACE + Prometheus + Grafana 环境。看板以 **JSON 存仓库、靠 ConfigMap 下发**，
Grafana 的 PVC 不是可靠的配置载体（上次 AZ 错位重建 PVC 时就验证过：卷丢了，但看板因为在
ConfigMap 里所以自动恢复）。

顺序很重要，**配色放在最后一步**。大部分难看的看板都是先挑颜色。

---

## 一、先写清楚每个面板要回答什么问题

动手画之前，把看板的受众和问题列出来。一个面板对应一个问题，答不上来的面板就删掉。

反面例子：「RDS 监控看板」——太空泛，最后会变成把所有指标各画一张图的指标垃圾场。

正面例子：

| 受众 | 要回答的问题 | 判断依据 |
|---|---|---|
| 值班工程师 | 现在有东西坏了吗？ | 红/绿状态，不需要曲线 |
| 值班工程师 | 哪个实例是罪魁祸首？ | 按实例分组的排序表 |
| 容量规划 | 存储还能撑多久？ | 趋势 + 线性预测 |
| 成本负责人 | CloudWatch API 这个月花多少？ | 单个数字 |

把这张表写进看板的 description 字段，后人改的时候才知道边界在哪。

---

## 二、挑面板类型：按数据的"职责"选，不是按好看选

| 数据的职责 | Grafana 面板类型 | 不要用 |
|---|---|---|
| 一个headline 数字（当前值、总量、费用） | `stat` | 只有一条线的 timeseries |
| 状态（健康/告警） | `stat` + value mappings，或 `state-timeline` | gauge（半圆表盘占地方还难读） |
| 随时间变化 | `timeseries` | 柱状图 |
| 跨实体比较大小、要排序 | `table` 带 gauge cell，或 `bargauge` | 饼图 |
| 分布 | `heatmap` / `histogram` | 多条叠在一起的线 |
| 构成比例（且只有 2–3 项） | 堆叠 `timeseries` | 饼图、环形图 |

两条硬规则：

- **饼图基本不要用。** 超过 3 个扇区人眼就比不出大小了，排序表永远更好读。
- **绝不用双 Y 轴。** Grafana 用 override 很容易做出来，但两个不同量纲的 Y 轴是最常见的
  图表错误 —— 相关性可以靠拉伸任一轴随意编造。要么拆成两个面板，要么归一化到同一基准。
  例：想同时看「请求数」和「延迟」，就上下放两个面板，共享 time range 即可对齐看。

---

## 三、YACE 指标的四个查询惯用法

这部分是 YACE 专有的，不懂这几个套路写出来的看板会很难用。

### 1. 用 `info` 指标 join 出 Tag —— 看板上不该出现裸 instance id

YACE 为每个资源额外导出一条 `aws_<service>_info`，值恒为 0，但带全部 Tag 作为 label。
业务指标上默认**只有** `exportedTagsOnMetrics` 里声明过的 Tag。要用其他 Tag 就得 join：

```promql
# 只有 CPU，图例是 i-01f2d93c1e216e2b0 —— 没人看得懂
aws_ec2_cpuutilization_average

# join 出 Project 和 Env tag，图例变成人类可读的
aws_ec2_cpuutilization_average
  + on (name) group_left(tag_Project, tag_Env) aws_ec2_info
```

`name` label 是资源 ARN，是 join 的唯一键。`group_left` 把右侧的 label 带过来。
`+ ... aws_*_info` 之所以能用是因为 info 的值恒为 0，加上它不改变数值。

> 若该指标可能为 NaN，join 会直接丢掉整条序列。所以 job 里要开 `nilToZero: true`。

### 2. 用 `dimension_*` 区分聚合值和细分值

同一指标常有多种维度组合，YACE 会**全部导出**。不加过滤会出现"总量线"和"分项线"混在一张图里，
数值差一个量级，图完全没法看。

```promql
# OpenSearch：空 NodeId = 集群聚合，非空 = 单节点
aws_es_cpuutilization_average{dimension_NodeId=""}     # 集群级
aws_es_cpuutilization_average{dimension_NodeId!=""}    # 按节点
```

写面板前先确认这个指标有几种维度组合：

```bash
kubectl -n monitoring port-forward svc/kps-prometheus 9090:9090 &
curl -s --noproxy '*' --data-urlencode 'query=count by (dimension_NodeId) (aws_es_cpuutilization_average)' \
  http://127.0.0.1:9090/api/v1/query | jq -r '.data.result[] | "\(.metric)"'
```

### 3. 多账号：`account_id` 是一等公民

跨账号采集时每条指标都带 `account_id`。配合 `iam:ListAccountAliases` 权限还会有
`aws_account_info` 带出账号别名：

```promql
# 按账号别名分组，而不是 12 位数字
sum by (tag_Name) (aws_ec2_cpuutilization_average)
  + on (account_id) group_left(account_alias) aws_account_info
```

### 4. 速率换算：CloudWatch 的 Sum 不是速率

`Sum` 统计量是**一个 period 内的总和**。要换成 per-second 速率必须除以 period，
而且不能用 `rate()` —— YACE 导出的是 gauge，不是 counter。

```promql
# 错：rate() 对 gauge 没意义
rate(aws_ebs_volume_write_ops_sum[5m])

# 对：除以 job 里配的 period（本仓库 EBS 配的是 300）
aws_ebs_volume_write_ops_sum / 300
```

period 改了这里要跟着改 —— 这是个容易忘的隐性耦合。写在面板 description 里。

---

## 四、模板变量：让一个看板服务多个 region/账号

别为每个 region 复制一份看板。加变量：

```json
"templating": {
  "list": [
    {
      "name": "datasource",
      "label": "数据源",
      "type": "datasource",
      "query": "prometheus",
      "current": { "text": "Prometheus", "value": "prometheus" }
    },
    {
      "name": "region",
      "label": "Region",
      "type": "query",
      "datasource": { "type": "prometheus", "uid": "${datasource}" },
      "query": "label_values(aws_ec2_info, region)",
      "refresh": 1,
      "includeAll": true,
      "multi": true
    },
    {
      "name": "account",
      "label": "账号",
      "type": "query",
      "datasource": { "type": "prometheus", "uid": "${datasource}" },
      "query": "label_values(account_id)",
      "refresh": 1,
      "includeAll": true,
      "multi": true
    }
  ]
}
```

面板查询里用 `=~` 配合变量（`multi` 变量展开成 `a|b|c`）：

```promql
aws_ec2_cpuutilization_average{region=~"$region", account_id=~"$account"}
```

`"refresh": 1` 表示看板加载时刷新变量取值，新增 region/账号会自动出现。

---

## 五、配色与可访问性

### Grafana 自带调色板不达标，别用默认

我实测了 Grafana classic 调色板的 8 个槽位：

```
[FAIL] CVD separation      #705DA0↔#BA43A9  ΔE 1.7 (红色盲)  ← 紫和品红基本同色
[FAIL] Normal-vision floor #E24D42↔#EF843C  ΔE 12.1          ← 红和橙正常视力也难分
[FAIL] Chroma floor        #6ED0E0 偏灰
```

红色盲人群约占男性 8%，ΔE 1.7 意味着这两个系列对他们是同一个颜色。

### 用这套（已验证通过 light/dark 双模式全部检查）

| 槽位 | Light（我们当前 Grafana 是 light 主题） | Dark |
|---|---|---|
| 1 | `#2a78d6` 蓝 | `#3987e5` |
| 2 | `#eb6834` 橙 | `#d95926` |
| 3 | `#1baf7a` 青绿 | `#199e70` |
| 4 | `#eda100` 黄 | `#c98500` |
| 5 | `#e87ba4` 品红 | `#d55181` |
| 6 | `#008300` 绿 | `#008300` |
| 7 | `#4a3aa7` 紫 | `#9085e9` |
| 8 | `#e34948` 红 | `#e66767` |

**按固定顺序分配，不要循环复用。** 第 9 个系列不是再生成一个颜色 —— 要么归到
"Other"，要么拆成 small multiples（Grafana 里用 `repeat` 按变量重复面板）。

Grafana 里固定某个系列的颜色用 override：

```json
"overrides": [
  {
    "matcher": { "id": "byName", "options": "prod-db-01" },
    "properties": [
      { "id": "color", "value": { "mode": "fixed", "fixedColor": "#2a78d6" } }
    ]
  }
]
```

两条配套规则：

- **颜色跟实体绑定，不跟排名绑定。** 筛选条件变了导致系列数变化时，存活的系列不能换色，
  否则用户的颜色记忆全废。所以用 `byName` override，不要依赖调色板的自动顺序。
- **状态色是保留色**（good/warning/serious/critical），绝不能拿来当"第 4 个系列"。

### 状态色（阈值用）

| 语义 | 色值 |
|---|---|
| good | `#0ca30c` |
| warning | `#fab219` |
| serious | `#ec835a` |
| critical | `#d03b3b` |

状态**绝不能只靠颜色表达**，必须配文字或图标。stat 面板用 value mappings：

```json
"mappings": [
  { "type": "value", "options": { "0": { "text": "—",       "color": "text" } } },
  { "type": "value", "options": { "1": { "text": "HEALTHY", "color": "#0ca30c" } } }
]
```

现有看板的「OpenSearch 集群状态」面板就是这么做的 —— 显示的是 `HEALTHY` / `RED` 文字，
不是单纯一块绿色或红色。

### 其他必做项

- **≥2 个系列必须有图例**；只有 1 个系列不要图例（标题已经说明了画的是什么）。
- **不要给每个数据点都标数值。** 图例里用 `calcs: ["mean", "max"]` 给汇总值。
- **网格线和坐标轴要退到背景**：Grafana 默认已经够淡，不要加重。
- **数值文字用默认 text 颜色**，不要染成系列色。系列色由旁边的色块承担识别功能。

---

## 六、面板 JSON 骨架

直接抄改。三种最常用的。

### timeseries

```json
{
  "type": "timeseries",
  "title": "RDS CPU 利用率",
  "description": "超过 80% 持续 10 分钟需要关注。period=300，改 job 配置时注意同步。",
  "datasource": { "type": "prometheus", "uid": "${datasource}" },
  "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 },
  "targets": [
    {
      "refId": "A",
      "expr": "aws_rds_cpuutilization_average{region=~\"$region\"}",
      "legendFormat": "{{dimension_DBInstanceIdentifier}}"
    }
  ],
  "fieldConfig": {
    "defaults": {
      "unit": "percent",
      "min": 0,
      "max": 100,
      "custom": { "fillOpacity": 10, "lineWidth": 2, "showPoints": "never" },
      "thresholds": {
        "mode": "absolute",
        "steps": [
          { "color": "green",  "value": null },
          { "color": "#fab219", "value": 80 },
          { "color": "#d03b3b", "value": 90 }
        ]
      }
    },
    "overrides": []
  },
  "options": {
    "legend": { "displayMode": "table", "placement": "bottom", "calcs": ["mean", "max"] },
    "tooltip": { "mode": "multi", "sort": "desc" }
  }
}
```

`tooltip.mode: multi` 很关键 —— 多系列时鼠标悬停能一次看到所有系列在该时刻的值，
否则只能一条一条试。

### stat（headline 数字）

```json
{
  "type": "stat",
  "title": "预估月度 CloudWatch API 费用",
  "description": "按 $0.01/1000 metrics requested，用最近 1 小时速率外推 30 天。未扣免费额度。",
  "datasource": { "type": "prometheus", "uid": "${datasource}" },
  "gridPos": { "h": 5, "w": 6, "x": 0, "y": 0 },
  "targets": [
    {
      "refId": "A",
      "expr": "increase(yace_cloudwatch_getmetricdata_metrics_requested_total[1h]) * 24 * 30 / 1000 * 0.01"
    }
  ],
  "fieldConfig": {
    "defaults": {
      "unit": "currencyUSD",
      "decimals": 2,
      "color": { "mode": "thresholds" },
      "thresholds": {
        "mode": "absolute",
        "steps": [
          { "color": "green",   "value": null },
          { "color": "#fab219", "value": 50 },
          { "color": "#d03b3b", "value": 200 }
        ]
      }
    }
  },
  "options": {
    "reduceOptions": { "calcs": ["lastNotNull"] },
    "colorMode": "value",
    "graphMode": "none",
    "textMode": "auto"
  }
}
```

`colorMode: "value"` 只染数字（克制），`"background"` 会整块染色（刺眼，只在真告警面板用）。

### table（跨实体排序比较）

多个 query join 成一张表。`instant: true` 必须加，否则会拿到时间序列而不是单点。

```json
{
  "type": "table",
  "title": "S3 桶容量与对象数",
  "datasource": { "type": "prometheus", "uid": "${datasource}" },
  "gridPos": { "h": 9, "w": 24, "x": 0, "y": 0 },
  "targets": [
    { "refId": "A", "expr": "aws_s3_bucket_size_bytes_average", "format": "table", "instant": true },
    { "refId": "B", "expr": "aws_s3_number_of_objects_average", "format": "table", "instant": true }
  ],
  "transformations": [
    { "id": "joinByField", "options": { "byField": "dimension_BucketName", "mode": "outer" } },
    { "id": "organize", "options": {
        "excludeByName": { "Time 1": true, "Time 2": true, "__name__ 1": true, "__name__ 2": true,
                           "job 1": true, "job 2": true, "instance 1": true, "instance 2": true },
        "renameByName": { "dimension_BucketName": "Bucket", "Value #A": "容量", "Value #B": "对象数" }
    } }
  ],
  "fieldConfig": {
    "defaults": { "custom": { "align": "auto", "filterable": true } },
    "overrides": [
      { "matcher": { "id": "byName", "options": "容量" },
        "properties": [
          { "id": "unit", "value": "bytes" },
          { "id": "custom.cellOptions", "value": { "type": "gauge", "mode": "gradient" } }
        ] }
    ]
  },
  "options": { "sortBy": [{ "displayName": "容量", "desc": true }], "showHeader": true }
}
```

join 之后 label 列会带 ` 1` / ` 2` 后缀（来自不同 query），`organize` 里要逐个排掉 ——
这里很啰嗦但没别的办法，漏了就会在表里看到一堆重复列。

### 单位别写错

Grafana 单位字符串是硬编码的枚举，写错不报错、只是不生效：

| 数据 | unit |
|---|---|
| 百分比（0–100） | `percent` |
| 百分比（0–1） | `percentunit` |
| 字节 | `bytes`（IEC）/ `decbytes`（SI） |
| 字节/秒 | `Bps` |
| 秒 / 毫秒 | `s` / `ms` |
| IOPS | `iops` |
| 请求/秒 | `reqps` |
| 美元 | `currencyUSD` |
| 无单位计数 | `short` |

注意 CloudWatch 的 `FreeStorageSpace` 对 OpenSearch 返回的是 **MB**，不是字节。
要么乘 `1024*1024` 配 `bytes`，要么直接标 `decmbytes`。现有看板用的是前者。

---

## 七、布局

- 一行 24 格。常用：全宽 24、半宽 12、三分 8、四分 6。
- **最重要的放最上面。** 第一屏应该在 5 秒内回答"有没有问题"。
- 用 `row` 面板分组，按服务或关注维度分段。
- stat 面板高度 4–5，timeseries 7–8，table 9+。
- 相关面板同高度对齐，否则页面会参差不齐。

现有看板的分段方式可以参考：`CloudWatch API 用量与成本` → `EC2` → `OpenSearch` → `SQS/EBS/S3`，
成本放第一行是因为这是 YACE 方案里最需要持续盯的东西。

---

## 八、落库与发布

### 推荐工作流：UI 探索 → JSON 固化

1. 在 Grafana UI 里新建看板，调查询、试面板类型 —— 探索阶段 UI 效率高得多。
2. 调好后 **Dashboard settings → JSON Model**（或 Share → Export → Save to file），
   复制 JSON。
3. 存到 `eks/dashboards/<名字>.json`，手工补三件事：
   - 固定 `"uid"`（否则每次导出都变，ConfigMap 更新会变成新建看板）
   - 把所有 `"datasource"` 改成 `{ "type": "prometheus", "uid": "${datasource}" }`
   - 删掉 `"id"`、`"version"`、`"iteration"` 这些实例相关字段
4. 下发：

```bash
cd eks
kubectl -n monitoring create configmap yace-dashboard \
  --from-file=yace-cloudwatch.json=dashboards/yace-cloudwatch.json \
  --from-file=rds.json=dashboards/rds.json \
  --dry-run=client -o yaml \
  | kubectl label -f - grafana_dashboard=1 --local --dry-run=client -o yaml \
  | kubectl apply -f -
```

sidecar 30 秒内自动加载，**不用重启 Grafana**。一个 ConfigMap 可以放多个看板文件。

> ConfigMap 单个对象上限 1MiB。看板多了要拆成多个 ConfigMap，都打 `grafana_dashboard=1` 标签即可。

### 验证

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80 &
PW=$(cat /tmp/grafana-pw.txt)

# 看板是否加载
curl -s --noproxy '*' -u "admin:$PW" 'http://127.0.0.1:3000/api/search?type=dash-db' \
  | jq -r '.[] | "\(.uid)  \(.title)"'

# 面板查询是否真能出数（走 Grafana 的数据源代理，比只看 Prometheus 更接近真实）
curl -s --noproxy '*' -u "admin:$PW" -H 'Content-Type: application/json' \
  -X POST 'http://127.0.0.1:3000/api/ds/query' \
  -d '{"queries":[{"refId":"A","datasource":{"type":"prometheus","uid":"prometheus"},
       "expr":"aws_rds_cpuutilization_average","instant":true}],"from":"now-1h","to":"now"}' \
  | jq '.results.A.frames | length'
```

返回 0 就是取不到数，去查指标名或 label 过滤条件。

### 两个必踩的坑

1. **datasource uid 是小写 `prometheus`**。写成显示名 `Prometheus` 会让**整个看板所有面板**
   无数据，且 UI 上不报错，只是一片空白。模板变量的 `current.value` 也必须是 uid。
2. **不要指望 Grafana PVC 保存看板**。手工在 UI 改的东西在 pod 重建后就没了
   （这个环境已经发生过一次）。UI 只用于探索，成果必须导回仓库。

---

## 九、从面板到告警

看板是给人看的，告警要独立配。kube-prometheus-stack 装了 Prometheus Operator，
用 `PrometheusRule` CRD 最直接：

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: yace-cloudwatch-alerts
  namespace: monitoring
  labels:
    release: kube-prometheus-stack   # 必须匹配，否则 Prometheus 不加载
spec:
  groups:
    - name: cloudwatch
      rules:
        - alert: OpenSearchClusterNotGreen
          expr: aws_es_cluster_status_green_maximum == 0
          for: 10m
          labels:
            severity: critical
          annotations:
            summary: "OpenSearch 域 {{ $labels.dimension_DomainName }} 不是 green"

        - alert: OpenSearchJVMPressureHigh
          expr: aws_es_jvmmemory_pressure_average{dimension_NodeId!=""} > 85
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "节点 {{ $labels.dimension_NodeId }} JVM 内存压力 {{ $value | printf \"%.1f\" }}%"

        - alert: CloudWatchAPICostSpike
          expr: increase(yace_cloudwatch_getmetricdata_metrics_requested_total[1h]) * 24 * 30 / 1000 * 0.01 > 200
          for: 30m
          labels:
            severity: warning
          annotations:
            summary: "CloudWatch API 预估月成本超 $200，检查是否误加了高基数 job"
```

`for` 一定要给。YACE 的数据本身有 5–10 分钟延迟（CloudWatch 出数 + 抓取间隔），
`for` 设得比 `scraping-interval` 短会因为单次抓取抖动而误报。建议 **至少 2 倍 scraping-interval**。

> 实时性要求高的告警（秒级）不要走这条链路，延迟摆在那里。那种场景用 CloudWatch Alarm
> 直接发 SNS，YACE 链路只做趋势和容量类告警。

---

## 十、提交前自查

- [ ] 每个面板都能说出它回答什么问题，没有"顺手加的"面板
- [ ] 没有双 Y 轴，没有饼图
- [ ] `datasource` 全部是 `{"type":"prometheus","uid":"${datasource}"}`
- [ ] `uid` 已固定，`id`/`version` 已删
- [ ] 每个 panel 的 `unit` 都设了，且枚举值拼写正确
- [ ] 系列颜色用 `byName` override 固定，不依赖自动顺序
- [ ] 状态色配了文字/图标，不是只有颜色
- [ ] ≥2 系列有图例，1 系列没有图例
- [ ] 图例用 `calcs` 给汇总值，没有逐点标数字
- [ ] 多系列 timeseries 设了 `tooltip.mode: "multi"`
- [ ] 涉及 `Sum / period` 换算的面板，在 description 里写明了 period 值
- [ ] `_info` join 用了 `group_left`，且对应 job 开了 `nilToZero`
- [ ] 下发后**真的打开看过** —— 校验脚本查不出标签重叠、文字溢出、面板高度参差
