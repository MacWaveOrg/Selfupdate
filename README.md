# MacWaveOrg/Selfupdate

MacWave 的自更新数据。它只回答两个问题：

1. **现在该装哪个版本？** → `macwavedata/latest.toml`
2. **那个版本具体怎么装？** → `macwavedata/<版本>/update_commands.sh`

客户端只读这一个仓库，地址由环境变量决定：

| 环境变量 | 默认值 | 用途 |
| --- | --- | --- |
| `MACWAVE_SELFUPDATE_DOMAIN` | 本仓库的 raw 地址 | 版本指针与更新脚本 |

自带解释器不在这里，见 [`MacWaveOrg/Python`](https://github.com/MacWaveOrg/Python)
（`MACWAVE_PYTHON_DOMAIN`）。两者分开是因为体积与发布节奏不同：一个几十字节，
一个每架构约 26 MB。

## 目录

```
macwavedata/
    latest.toml                这次要装 / 升到哪个版本（唯一入口）
    4.0.0/
        update_commands.sh     该版本「下载哪些文件、放到哪里」，随版本冻结
```

## 为什么分成两个文件

`latest.toml` 每次发版都变，`update_commands.sh` 按版本冻结。

把「当前该装哪个版本」和「那个版本具体怎么装」混在一个文件里，就没法让装了旧版本
的用户继续用他们那份说明 —— 而旧版本仍在运行，它们要读的是自己那一份。

## 为什么用脚本取代文件清单

3.x 的 `files_info` 是一棵缩进树，客户端得自己解析出「要下载哪些文件」。这套格式
只能表达「全部列一遍」，所以每次更新都要重下所有文件，哪怕只有一个 `help.py` 变了。

4.0 换成一份脚本，客户端只负责取回来执行：

- 脚本里只写**这次变动的**文件，没变的一个字节都不下；
- 目录结构变更的迁移也写在同一个脚本里，不必再维护 `updatedata/` 那套机制；
- 客户端不再需要自定义格式的解析器。

脚本自己判断要不要走全量：`MACWAVE_CURRENT_VERSION` 为空就是首次安装（下载全部），
否则按增量清单走。所以一个文件同时服务 `install.sh` 与 `wave selfupdate`。

环境变量就是它与客户端之间的全部契约，见脚本头部注释。

## 发布一次新版本要做什么

1. 生成脚本（别手写）：

   ```
   python3 scripts/build_update_commands.py \
       --version 4.0.1 --branch 4.0 --ref 4.0 \
       --delta lib/help.py \
       --out <本仓库>/macwavedata/4.0.1/update_commands.sh
   ```

   `--files` 是完整文件清单（首次安装用），`--delta` 是这次变动的文件。
   漏写一个该更新却没写的文件，用户升级后那条命令就会用旧代码跑。

2. 改 `macwavedata/latest.toml` —— 最后改，它就是「上线开关」。

第 1 步是机械的，由 MacWave 仓库的 `.github/workflows/sync-payloads.yml` 一并做。

## 与 MacWave 仓库的关系

字段名与 `lib/domains.py` 是一份约定，改字段名要两边一起改。

## 3.x 的用户会看到什么

3.x 的 `selfupdate` 从旧 `configdata` 读到新版本号后，会被「跨大版本不允许 selfupdate」
拦住，提示去 <https://macwave.org> 用安装命令重装。要做的事只有一件：在旧 `configdata`
的 `versiondata/latest_version` 里把版本号写成 4.x，那个守卫会替我们拦住所有人。
