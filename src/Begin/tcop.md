# tcop

> tcop = Traffic COntrol Program

## 命令分类

在 PostgreSQL 16 中，后端（Postgres 进程）通过解析前端（客户端，如 psql、libpq 程序）发送的**消息类型标识**（单字符）来区分请求类型

| 字符 | 函数/处理逻辑           | 核心职责                                                                 | 典型引用场景                                                                                                                                                                                                                     |
| ---- | ----------------------- | ------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Q`  | `exec_simple_query`     | 处理「简单查询」（Simple Query），是最基础的 SQL 执行入口                | 1. psql 直接执行 `SELECT * FROM t;`、`INSERT INTO t VALUES(1);` 等单行 SQL；<br>2. 客户端未使用预备语句（Prepare），直接发送 SQL 文本执行；<br>3. 源码中该路径会跳过 Parse/Bind/Execute 流程，直接解析 → 规划 → 执行 SQL。       |
| `P`  | `exec_parse_message`    | 处理「解析消息」（Parse），编译 SQL 文本为预备语句（Prepared Statement） | 1. 客户端执行 `PREPARE stmt AS SELECT * FROM t WHERE id=$1;` 时的解析阶段；<br>2. 批量执行相同 SQL 前的预编译（减少重复解析/规划开销）；<br>3. 源码中会生成解析树/规划树，存储在门户（Portal）的上下文里。                       |
| `B`  | `exec_bind_message`     | 处理「绑定消息」（Bind），为预备语句绑定参数值，生成可执行的门户         | 1. 客户端执行 `EXECUTE stmt(1);` 前的参数绑定（将 $1 替换为具体值 1）；<br>2. 绑定参数类型/值到预备语句，确定执行上下文；<br>3. 源码中会校验参数类型、填充执行计划的参数槽，关联 `PortalContext`。                               |
| `E`  | `exec_execute_message`  | 处理「执行消息」（Execute），执行已绑定参数的门户（Portal）              | 1. 客户端绑定参数后，触发实际的 SQL 执行（如 `EXECUTE stmt`）；<br>2. 游标（CURSOR）的 `FETCH` 操作（本质是执行门户获取部分结果）；<br>3. 源码中调用 `ExecutorStart/ExecutorRun` 执行计划，关联 `PortalContext` 和执行器上下文。 |
| `F`  | `HandleFunctionRequest` | 处理「函数调用请求」（Function Call），直接调用后端函数（非 SQL 文本）   | 1. 客户端通过 libpq 直接调用 PostgreSQL 内置函数/自定义函数（如 `pg_get_userbyid(10)`）；<br>2. 扩展插件通过前端消息直接触发函数执行，跳过 SQL 解析；<br>3. 源码中直接定位函数 OID，执行函数并返回结果。                         |
| `S`  | `finish_xact_command`   | 「同步消息」（Sync），标记一个事务块的结束，等待后端响应完成             | 1. 客户端在 Parse/Bind/Execute 序列后发送 Sync，确保后端完成所有操作并返回状态；<br>2. 事务结束时（如 `COMMIT` 后），同步后端状态与前端；<br>3. 源码中会重置事务状态，清理临时上下文，响应 `CommandComplete` 消息。              |

## 核心流程关联（便于理解源码）

1. **简单查询流程**：`Q` → 直接解析/规划/执行 → 响应结果；
2. **预备语句流程（常用于 JDBC 等）**：`P`（解析）→ `B`（绑定）→ `E`（执行）→ `C`（关闭）→ `S`（同步）；
