# MacWaveOrg/Selfupdate

MacWave 4.0 的自更新数据。以前这些内容放在 `configdata` 里，和「安装信息」混在一起；
4.0 起安装信息归 MacWave 仓库自己，自更新数据单独一个仓库——它的发布节奏和
MacWave 的代码不同，混在一起时每次发版都要同时改两个语义不同的地方。

客户端只读这一个仓库的三个位置，地址由环境变量决定：

| 环境变量 | 默认值 | 用途 |
| --- | --- | --- |
| `MACWAVE_SELFUPDATE_DOMAIN` | 本仓库的 raw 地址 | 版本数据、文件清单、迁移脚本、冻结的更新脚本 |
| `MACWAVE_PYTHON_DOMAIN` | 本仓库的 raw 地址 | `pythondata/latest_python` |

## 目录

```
versiondata/
    latest_version          这次要装/升到哪个版本（唯一入口）
    files_info_<版本>       该版本要下载的文件清单，一个版本一份
selfupdate/
    selfupdate_<版本>.sh    该版本的自更新脚本，随版本冻结
updatedata/
    <版本>/
        dir_structure_change    一个字符：Y 表示该版本改了目录结构
        transfer_commands       改了的话，迁移脚本写在这里
pythondata/
    latest_python           自带 CPython 的版本、地址与校验值
```

## 为什么文件清单一个版本一份

清单必须与它描述的代码完全对应。以前所有版本共用一份 `versiondata/files_info`，
于是往 `main` 上加一个文件，还在用旧分支的用户就会去下一个不存在的文件，卡在 404 上。
现在发版时生成一份，`latest_version` 的 `files_info` 字段指向它。

## 为什么更新脚本也冻结

4.0.1 的自更新逻辑可能与 4.0.0 不同，而装了 4.0.0 的用户手里只有 4.0.0 那份脚本。
让脚本随数据一起冻结，客户端就不必去猜「这个用户现在能跑哪个版本的脚本」——
它只按 `latest_version` 里的 `selfupdate_script` 取，取到什么就跑什么。

3.x 的做法是把整条命令写在 `update_command` 字段里（`bash -c "$(curl ...)"`）。
4.0 不再需要那个字段，但客户端仍然认它，所以**旧数据继续可用**。

## 发布一次新版本要改什么

1. `versiondata/files_info_<新版本>` —— 从 MacWave 仓库的 `lib/`、`pkg/`、`surfboard/`
   生成，别手写（漏一个文件，用户装完就在某条命令上 `ModuleNotFoundError`）。
2. `selfupdate/selfupdate_<新版本>.sh` —— `cp <MacWave>/lib/selfupdate.sh` 过来。
3. `updatedata/<新版本>/dir_structure_change` —— 没改目录结构就写 `N`。
4. `versiondata/latest_version` —— 最后改这一行，它就是「上线开关」。

第 1、2 步是机械的，应该由 MacWave 仓库的 CI 做；在那之前先手工照做。

## 与 MacWave 仓库的关系

字段名与 `lib/domains.py` 是一份约定。改字段名要两边一起改，否则客户端会读不到值
（读不到时它按「这是旧数据」处理，回落到 3.x 的行为，不会崩溃）。

## 3.x 的用户会看到什么

3.x 的 `selfupdate` 会从旧 `configdata` 读到新版本号，然后被「跨大版本不允许 selfupdate」
拦住，提示去 <https://macwave.org> 用安装命令重装。这里要做的事只有一件：
在旧 `configdata` 的 `versiondata/latest_version` 里把版本号写成 4.x，
那个守卫就会替我们拦住所有人。
