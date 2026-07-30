src/backend/replication/README

# Walreceiver — libpqwalreceiver API

Walreceiver 中与传输相关的部分（连接主库、接收 WAL、发送消息）采用**动态加载**，以免把主服务端二进制直接链接到 libpq。动态模块位于 `libpqwalreceiver` 子目录。

该模块实现一组函数；各函数说明见 `src/include/replication/walreceiver.h`。

目前应把此 API 视为**内部接口**。将来有可能向第三方开放，允许用可插拔方式替换 `libpqwalreceiver`，从而自定义接收 WAL 的方法。

# Walreceiver IPC

当 Startup 进程中的 WAL 重放已经走到归档 WAL 的末尾（通过 `restore_command` 可恢复的部分），若配置了流复制，就会启动 walreceiver 进程去拉取更多 WAL。

Walreceiver 是 postmaster 的子进程，因此 Startup **不能直接 fork** 它。做法是：向 postmaster 发信号，请 postmaster 拉起 walreceiver。在此之前，Startup 会先填好 `WalRcvData->conninfo`、`WalRcvData->slotname`，并把起始位点写到 `WalRcvData->receiveStart`。

Walreceiver 从主库收到 WAL，写入并 flush 到本地磁盘（`pg_wal`）后，会更新 `WalRcvData->flushedUpto`，并信号通知 Startup，使其知道重放可以推进到何处。

每当写入或 flush 了新的 WAL，或到达指定的时间间隔，walreceiver 会把复制进度信息发回主库，用于汇报。

# Walsender IPC

关机时，postmaster 对 walsender 的处理与普通 backend **不同**。对普通 backend，它会等它们都退出后，再写 shutdown checkpoint，并结束 pgarch 等辅助进程；但对 walsender 不合适——我们希望备库在主库关掉之前，收到**包括 shutdown checkpoint 在内**的全部 WAL。因此 postmaster 把 walsender 当作类似 pgarch 来对待：在 `PM_SHUTDOWN_2` 阶段才让它们退出，此时普通 backend 已死、checkpointer 也已写出 shutdown checkpoint。

Postmaster 接受连接后会立刻 fork 新进程做握手与认证，该进程初始化成 backend。此时 postmaster **还不知道**它最终是普通 backend 还是 walsender——这要在连接握手里才能区分——所以需要额外信号，让 postmaster 能识别 walsender。

Walsender 启动时，会在 `PMSignal` 数组里把自己标成 walsender，postmaster 据此与普通 backend 区分。

若 postmaster 误把 walsender 当成普通 backend，通常也无大碍：只是会更早结束该 walsender。在完成初始化并在 `PMSignal` 中标记之前，以及进程退出、清除 `PMSignal` 槽位之后，walsender 在外观上都会像普通 backend。

每个 walsender 从 `WalSndCtl` 数组分配一项，跟踪复制进度；用户可通过统计视图监控。

# Walsender — walreceiver 协议

见手册。
