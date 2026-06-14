# Recovery

## Failure Domain

| 等级   | 故障域（Failure Domain）               | 典型场景                         | RTO         | RPO           |
| ------ | -------------------------------------- | -------------------------------- | ----------- | ------------- |
| **L1** | 数据对象级故障（Object-Level Failure） | DROP TABLE、误 DELETE、误 UPDATE | 分钟级      | 0~秒级        |
| **L2** | 实例级故障（Instance Failure）         | PostgreSQL 进程崩溃、OS Crash    | 秒级~分钟级 | 0             |
| **L3** | 节点级故障（Node Failure）             | 主机损坏、磁盘损坏、电源故障     | 秒级~分钟级 | 0~秒级        |
| **L4** | 集群级故障（Cluster Failure）          | 主库与备库同时损坏、存储阵列损坏 | 小时级      | 分钟级~小时级 |
| **L5** | 站点级灾难（Site Disaster）            | 机房断电、火灾、洪水、网络隔离   | 小时级~天级 | 分钟级~小时级 |
| **L6** | 区域级灾难（Regional Disaster）        | 城市级停电、区域网络瘫痪         | 天级        | 小时级~天级   |

## Recovery Mechanism

| 层级 | 故障域 (Failure Domain) | 能力类别 (Capability)   | 恢复机制 (Recovery Mechanism) | 典型场景                         |
| ---- | ----------------------- | ----------------------- | ----------------------------- | -------------------------------- |
| L1   | Object                  | Logical Recovery        | PITR / Flashback              | DROP TABLE、误 DELETE、误 UPDATE |
| L2   | Instance                | Crash Recovery          | WAL Replay                    | PostgreSQL 进程崩溃、OS Crash    |
| L3   | Node                    | High Availability       | Failover / Switchover         | 主机损坏、磁盘损坏、电源故障     |
| L4   | Cluster                 | Backup Recovery         | Restore + PITR                | WAL归档系统损坏、脑裂            |
| L5   | Site                    | Metro Disaster Recovery | Metro DR Failover             | 机房断电、火灾、洪水、网络隔离   |
| L6   | Region                  | Geo Disaster Recovery   | Geo DR Failover               | 城市级停电、区域网络瘫痪         |
