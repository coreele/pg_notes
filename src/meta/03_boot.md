# Boot

| 鍑芥暟鍚?| 鏍稿績鍔熻兘 | 鍏抽敭缁嗚妭 |
| ------------------- | ------------- | -------------------------------------------------- |
| `exec_simple_query` | 鎵ц绠€鍗?SQL锛堝崟鍛戒护锛?| 鎵ц SQL锛氳В鏋?鈫?閲嶅啓 鈫?浼樺寲 鈫?鎵ц |
| `PostgresMain` | 鍚庣涓诲嚱鏁?| 寰幆澶勭悊澶氬懡浠わ紝鍏宠仈 MessageContext/row_description_context |
| `BackendRun` | 杩愯鍚庣閫昏緫 | 鍒囨崲鍐呭瓨涓婁笅鏂囪嚦 TopMemoryContext |
| `BackendStartup` | 鍒涘缓鍚庣杩涚▼ | fork_process 鍒涘缓瀛愯繘绋嬶紝澶辫触杩斿洖-1 |
| `ServerLoop` | 鏈嶅姟鍣ㄤ簨浠跺惊鐜?| 绛夊緟骞跺鐞嗗鎴风杩炴帴 |
| `PostmasterMain` | 涓昏繘绋嬩富寰幆 | 璇诲彇閰嶇疆锛岀洃鍚繛鎺ワ紝绠＄悊瀛愯繘绋嬶紝PostmasterContext=TopMemoryContext |
| `main` | 绋嬪簭鍏ュ彛 | 鍒濆鍖栫幆澧冿紝鍒嗛厤 TopMemoryContext锛岃皟鐢?PostmasterMain |

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
