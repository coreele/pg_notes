# 启动

| 函数名                 | 核心功能          | 关键细节                                               |
| ------------------- | ------------- | -------------------------------------------------- |
| `exec_simple_query` | 执行简单 SQL（单命令） | 执行 SQL：解析 → 重写 → 优化 → 执行                           |
| `PostgresMain`      | 后端主函数         | 循环处理多命令，关联 MessageContext/row_description_context  |
| `BackendRun`        | 运行后端逻辑        | 切换内存上下文至 TopMemoryContext                          |
| `BackendStartup`    | 创建后端进程        | fork_process 创建子进程，失败返回-1                          |
| `ServerLoop`        | 服务器事件循环       | 等待并处理客户端连接                                         |
| `PostmasterMain`    | 主进程主循环        | 读取配置，监听连接，管理子进程，PostmasterContext=TopMemoryContext |
| `main`              | 程序入口          | 初始化环境，分配 TopMemoryContext，调用 PostmasterMain        |

```cpp
main
    PostmasterMain
        InitProcessGlobals()
        CreateDataDirLockFile()   // create postmaster.pid
        ServerLoop
            BackendStartup
                fork_process
                BackendRun
                    PostgresMain(port->database_name, port->user_name);
                        exec_simple_query(query_string);
```