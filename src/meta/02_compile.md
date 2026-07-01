# Compile

> 鍩轰簬 macOS 15.4.1

## 婧愮爜鑾峰彇

- pg 瀹樻柟浠撳簱锛歨ttps://git.postgresql.org/git/postgresql.git
- github 浠撳簱锛歨ttps://github.com/postgres/postgres.git
- gitee 浠撳簱锛歨ttps://gitee.com/mirrors/PostgreSQL.git

```sh
git clone https://gitee.com/mirrors/PostgreSQL.git
cd postgresql
git checkout REL_16_11
```

## 鐗堟湰瑙勫垯

- PG 鐗堟湰缁存姢瑙勫垯锛歨ttps://www.postgresql.org/support/versioning/
- 鍙戝竷鐗堝懡鍚嶈鍒欙細`REL_<涓荤増鏈?_<缁存姢鐗堟湰>`
- REL_16_11 澶勪簬 16 涓荤増鏈殑銆岀ǔ瀹氱淮鎶ら樁娈点€?- 鏇存柊棰戠巼锛氭瘡骞村彂甯冧竴涓富鐗堟湰锛?5鈫?6鈫?7鈫?8锛夛紝姣?1-2 涓湀鍙戝竷涓€涓淮鎶ょ増鏈紙濡?16_1鈫?6_2鈫掆€︹啋16_11锛?
## 婧愮爜缂栬瘧

```sh
cd postgres
mkdir build && cd build
CFLAGS="-O0 -g3 -fno-inline -fno-omit-frame-pointer" \
../configure  --prefix=$HOME/app/pgdebug --without-icu --with-libxml --enable-debug --enable-cassert
make -j4
make install
# make distclean
# cp ./src/backend/postgres ~/app/pgdebug/bin/postgres 
```

## 鍒濆鍖?
```sh
cd ~/app/pgdebug/bin
./initdb -D ~/pgdata
```

- PostgreSQL 涓垵濮嬪寲鏁版嵁搴撻泦缇わ紙Database Cluster锛?鐨勬牳蹇冨懡浠?- 鍦ㄦ寚瀹氱洰褰?`~/pgdata` 涓垱寤?PostgreSQL 杩愯鎵€闇€鐨勫熀纭€鐩綍缁撴瀯銆佺郴缁熻〃銆侀厤缃枃浠?
## 鍚姩鍜屽仠姝?
```sh
cd ~/app/pgdebug/bin

./pg_ctl start -D ~/pgdata -l ~/pgdebug.log

./pg_ctl stop -D ~/pgdata -l ~/pgdebug.log

./pg_ctl restart -D ~/pgdata -l ~/pgdebug.log
```

## 杩炴帴

閰嶇疆瀹㈡埛绔闂?pg_hba.conf

```conf
# TYPE  DATABASE        USER            ADDRESS                 METHOD

# "local" is for Unix domain socket connections only
local   all             all                                     trust
# IPv4 local connections:
host    all             all             127.0.0.1/32            trust
```

杩炴帴

```sh
psql -U postgres -d postgres -h 127.0.0.1 -p 5432
```

鏌ヨ褰撳墠 pid

```sql
// 鏌ヨ褰撳墠pid
select pg_backend_pid();
```

## vscode 閰嶇疆璋冭瘯

```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "Attach PG",
      "type": "cppdbg",
      "request": "attach",
      "program": "~/SourceCodes/postgres/src/backend/postgres", // PostgreSQL 涓荤▼搴忚矾寰?      "processId": "${command:pickProcess}", // 鍏佽鎵嬪姩閫夋嫨杩涚▼ID
      "MIMode": "lldb", // 浣跨敤 GDB 璋冭瘯鍣?      "setupCommands": [
        {
          "description": "Enable pretty-printing for gdb",
          "text": "-enable-pretty-printing",
          "ignoreFailures": true
        }
      ],
      "logging": {
        "moduleLoad": false,
        "trace": true
      }
    }
  ]
}
```
