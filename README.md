# Supervisor Manager (sm.sh)

**以 Bash 为主的交互式 Supervisor 管理器**——单文件、菜单驱动、复用 Supervisor 自带的 Python 解析器和系统 flock，参考 mdserver-web / 宝塔面板的 Supervisor 插件功能集，但跑在终端里而非浏览器里。

设计目标与 [Supervisord TUI (god)](https://github.com/nicklasos/god) 不同：**不走 TUI 方向**，没有 vim 风格的全屏界面，就是普通的"打印标题 → 列菜单 → read 数字 → 进流程"，跟 `nvm` / `rvm` 那种用户体验类似。

## v1.6.3：提高串口默认输出间隔

- QM 串口默认行间及输入提示延迟从 50ms 提高到 150ms，以进一步降低偶发中文乱码概率。SSH 输出仍不增加延迟。
- 可使用 `SM_SERIAL_DELAY_MS=200 svm` 或 `SM_SERIAL_DELAY_MS=300 svm` 增大延迟；原有 0–1000ms 自定义范围及中文默认语言不变。实机验证前不能保证完全消除乱码。

## v1.6.2：QM 串口中文输出节流（历史版本）

- 串口模式默认每个 UI 完整行或输入提示输出后等待 50ms，降低高速连续 UTF-8 输出出现乱码的概率；中文仍为默认语言。使用 `SM_SERIAL_DELAY_MS=100 svm` 增大延迟，`SM_SERIAL_DELAY_MS=0 svm` 关闭节流（允许 0–1000ms）。
- 串口提示先完整输出到 stderr 再读取输入，避免命令替换捕获提示文字。帮助、安装、首页、菜单和状态展示均使用同一节流输出层。
- SSH 不增加输出延迟；Supervisor RPC、进程日志、配置内容及内部数据返回不经过节流。串口物理链路或终端解码仍可能存在问题，需实机验证。

## v1.6.1：默认中文及实例信息本地化

- SSH 与 QM 串口均默认中文，串口仍禁用颜色、清屏、复杂 Unicode 表格排版及 locale 自动调整。界面语言和终端模式独立：`SM_LANG=en svm` 可按需选择英文兜底，`SM_LANG=zh svm` 恢复中文。
- 首页实例名称、自动/手动选择方式、主程序、控制程序、主配置文件及服务状态均使用中文标签；程序名、配置路径、进程原始状态和日志内容不翻译、不删减。
- 保留 v1.6.0 多实例选择、卸载与 64 MiB 日志预算。以下串口说明以本节为准。

## v1.6.0：串口兼容、多实例选择与菜单卸载

- 主菜单新增 13「卸载 SVM 管理工具」；与 `svm --uninstall` 共用确认逻辑。取消后返回菜单，成功后退出当前界面。仅移除正在运行的 SVM 脚本，保留 Supervisor、所有业务配置、日志、备份及已保存实例设置。

- PVE qm terminal 进入 /dev/ttyS* 等串口设备时自动使用简化中文界面：禁用 ANSI 颜色、清屏和 Unicode 宽度计算，不自动切换 locale。SSH 保持正常中文界面。SM_SERIAL=1/0 可强制开启/关闭；SM_COLOR=0 单独禁用颜色。
- 菜单 12 可选择包管理器版本、MW 面板版本、手动指定版本、恢复自动选择。默认自动选择顺序为包管理器 > MW；手动输入是显式选择，不会猜测未知路径。切换仅改变管理目标，不启动或停止 daemon。
- MW 默认配置 /www/server/supervisor/supervisor.conf；优先使用 /www/server/mdserver-web/bin 下的 supervisord、supervisorctl，兼容常见 venv 目录与共享程序路径。MW 日志默认 /www/server/supervisor/log。
- 手动模式分别设置 supervisord、supervisorctl、主配置和可选 systemd unit。可保存至 /etc/supervisor-manager/instance.conf（root 0600，不作为 shell source）。SM_PROFILE、SM_SUPERVISORD、SM_SUPERVISORCTL、SM_MAIN_CONF、SM_SERVICE 可覆盖选择。
- 服务启停只允许匹配程序路径和配置路径的唯一 systemd unit；不再猜测或自动创建服务。非 systemd、无法识别的 unit、未带绝对 -c 路径的 daemon 需要人工处理。此保守行为用于避免多实例误操作。
- 保留每进程 64 MiB 日志预算。修复安装和帮助页字面 \\033 转义显示。
- 串口模式只约束管理工具界面，不改变外部编辑器、进程日志和配置文件的实际编码。

## v1.5.0：安全与稳定性更新

- 优先识别运行中的 supervisord 配置、systemd unit 和常见发行版路径；无法确认时使用 `SM_MAIN_CONF=/absolute/path/supervisord.conf svm` 显式选择。
- 控制命令统一传递主配置；使用 Supervisor 原生解析器验证配置，不启动额外 daemon。复杂或 ENV 动态 include 不自动猜测新增文件名。
- 增删改使用 flock 互斥、0700 备份目录、0600 备份文件、临时文件与原子替换。解析或应用失败恢复磁盘配置，运行态恢复为尽力而为，不保证恢复原 PID、手工启停状态及业务副作用。
- 局部操作拒绝已有待生效改动，只更新 reread 报告的变更组；全局重载需要确认。删除针对整个配置文件，不预先停止其他进程。
- 新建进程 stdout 与 stderr 各采用 **8MB × (1 + 3) = 32MiB** 的轮转预算，合计 64MiB；单次日志写入可能短暂超限。已有配置及历史日志不自动改写或清理。
- 新建进程默认 stopasgroup=true、killasgroup=true。日志路径使用运行态 RPC，日志查看不再编辑文件。敏感环境变量预览不回显。
- 自身安装检查实际目标，先备份不同内容再原子替换；`svm --uninstall` 只卸载工具，不删除 Supervisor、业务配置或历史备份。
- 仍为单文件部署，依赖 Bash、Supervisor 自带 Python 3、flock 和常见 Linux 工具（stat、mktemp、mv -T）。非标准 init、多实例及无法安全识别的配置需要人工确认。
- MIT 许可证完整文本已嵌入脚本。
- Debian 12/13 回归测试位于 tests/regression.sh，GitHub Actions 执行语法检查、配置匹配、备份、回滚及真实 Supervisor 进程组增删测试。容器测试不覆盖 systemd 开机恢复。

以下旧版本说明为历史记录；有冲突时以本节为准。

## 首页长这样

进入 `svm` 后，**不用点任何菜单就能看到所有受管进程的状态**——上方是状态看板，下方是操作菜单：

```
 Supervisor Manager v1.5.0
====================================================================
  进程状态  共 9 个，运行 4，异常 5
  名称                        状态         PID      运行时长
  --------------------------  -----------  -------  ----------------
  web                         RUNNING      101      0:10:23
  api-server                  RUNNING      12345    26d 3:04:05
  worker:0                    RUNNING      102      1d 2:03:04
  worker:1                    FATAL        -        Exited too quickly (process log may have details)
  cron                        STOPPED      -        Sep 12 03:04 PM
  db                          BACKOFF      -        Exited too quickly
  cache                       STARTING     -        -
  a-very-very-long-process..  RUNNING      7        0:00:01
--------------------------------------------------------------------
   1) 安装 Supervisor
   2) 配置开机自启
   ...
  0) 退出

请选择 [0-11]:
```

> 表头里的「名称」「状态」是汉字、数据行是英文，二者仍能严格对齐——这不是 `printf %-Ns` 做得到的，见下文 [v1.4.0 修复记录](#v140-修复记录locale-自适应--界面对齐)。

看板特性：

- **状态色编码**：`RUNNING` 绿 / `FATAL`·`STOPPED` 红 / `STARTING`·`BACKOFF`·`STOPPING` 黄 / 其他灰
- **汇总统计**：一眼看出"共 N 个，运行 X，异常 Y"；全部正常时提示"全部运行中"
- **严格对齐**：按**显示宽度**（汉字 2 列、ASCII 1 列）补齐，表头/分隔线/数据行各列起点一致；进程名含中文、带 ANSI 颜色码都不影响
- **超长名称截断**：名称超过列宽截成 `xxx..`，不撑破表格；运行时长 `26 days, 3:04:05` 压成 `26d 3:04:05`
- **窄终端自适应**：终端比 68 列窄时自动收窄"名称"列（最小 44 列），可用 `SM_WIDTH` 固定宽度
- **locale 自适应**：进菜单前检测当前 locale，不是 UTF-8 就自动切到系统可用的 UTF-8 locale（见 v1.4.0 记录）
- **异常场景直接给处置路径**：未安装 → 指向 `[1]`；未运行 → 指向 `[2]`；无进程 → 指向 `[3]`
- **`numprocs` 实例**（`worker:0`/`worker:1`）与**组汇总**（`group:*`）都能正确显示
- 看完日志返回时**跳过清屏**，刚读到的日志内容不会立刻被刷掉
- 渲染全程 bash 内建命令、零 fork：若每行用 `$( )` 取补齐结果，60 个进程要 fork 上百次，慢机器上首屏要等数秒（本机 Windows Git Bash 实测 6.0s → 0.9s）

## 功能一览

| 菜单项 | 功能 | 实现要点 |
| --- | --- | --- |
| 首页看板 | 直接渲染全部进程状态 + 汇总统计 | 每轮菜单前刷新一次；色编码 + 三种异常场景引导 |
| 1. 安装 Supervisor | 按发行版 apt/yum/dnf/apk/pacman 安装 | 自动生成主配置 + `[include] conf.d` 段 |
| 2. 配置开机自启 | systemd enable / OpenRC rc-update | 缺 unit 时自动生成 `/etc/systemd/system/supervisor.service` |
| 3. 添加守护进程 | 流程化输入 name/command/user/dir/autostart/logpath 等 | 落点跟随 `[include] files` 的目录**与后缀**；防重 + 预览 + reread+update+start |
| 4/5/6. 启动/停止/重启 | 选具体进程或 `all` | 命令失败给出 ERROR 但不退出菜单 |
| 7. 查看/跟随日志 | tail / tail -f / `$EDITOR` 三种动作 × stdout/stderr | 直接定位 conf.d 下的 logfile 路径 |
| 8. 编辑进程配置 | 自动备份 → 编辑 → 检测是否真改动 → 问是否立即重载 | 列表按 `[include] files` 枚举，不再只看 `conf.d` |
| 9. 重载 supervisor 配置 | reread + update | **reread 报错即判失败**，不再误报“重载完成” |
| 10. 删除守护进程 | 二次确认 → 按 `[program:x]` 段名 stop → 备份 → rm → 重载 | 文件名 ≠ 程序名时也能停对进程 |
| 11. 编辑主 supervisord.conf | 备份 → 编辑 → 提示需重启（reread 无效）| 可直接确认执行 `systemctl restart` |

> `-c status` 仍保留一次性状态输出（适合脚本调用），但交互模式下首页已自带，不需要再单独点。

## 部署

### 方式一：Self-install（推荐，自动命名为 `svm`）

```bash
# 1) 把脚本送到服务器
curl -fsSL https://your-host/sm.sh -o /tmp/sm.sh
# 或 scp sm.sh root@server:/tmp/sm.sh

# 2) self-install（自动命名 svm，PATH 中已有 svm 则降级 svmgr/supmgr）
sudo bash /tmp/sm.sh --install
```

安装完成后直接输入 `svm` 启动。

### 方式二：Self-install 高级选项

```bash
sudo bash sm.sh --install --as svmgr          # 强制命令名为 svmgr
sudo bash sm.sh --install --path /opt/bin     # 装到 /opt/bin/svm
sudo bash sm.sh --install --force             # 跳过冲突检测强制覆盖（旧文件自动备份）
sudo bash sm.sh --install --help              # 查看所有选项
```

### 方式三：手动拷贝（如不能用 self-install）

```bash
sudo cp sm.sh /usr/local/bin/svm
sudo chmod +x /usr/local/bin/svm
```

## 升级

用新版脚本重新执行 `--install` 即完成升级：

```bash
sudo bash sm.sh-1.3.2 --install
# 检测到旧版本 v1.2.0 → 升级到 v1.3.2
# 旧版本自动备份为 svm.v1.2.0（回滚: mv /usr/local/bin/svm.v1.2.0 /usr/local/bin/svm）
```

升级语义：

- 覆盖安装**只更新 `svm` 命令本身**，不触碰 `/etc/supervisor/` 配置、systemd unit、运行中的 supervisord 与受管进程
- 旧版本自动备份为 `svm.v<旧版本号>`，回滚一条 `mv` 命令
- 同版本重复安装提示"原样覆盖"，不产生备份
- 升级完成后自动做环境检查：supervisord 是否安装/运行、systemd 开机自启是否启用，异常时提示进对应菜单项处理

## `svm` 命名冲突说明

`svm` 不是 Linux base 系统自带命令，在纯运维服务器上通常空闲，但被以下生态项目占用：

| 项目 | 命令 | 安装方式 |
| --- | --- | --- |
| [alloy-rs/svm-rs](https://github.com/alloy-rs/svm-rs) | `svm`（Solidity 版本管理器） | `cargo install svm-rs` / Foundry 工具链 |
| [web3j/svm](https://github.com/web3j/svm) | `svm`（Solidity 版本管理器） | `curl install.sh \| bash` |

补充说明：LIBSVM 的命令是 `svm-train` / `svm-predict`，**不冲突**；AMD CPU 的 `svm` 只是 `/proc/cpuinfo` 里的虚拟化标志位，不是命令。

self-install 内置冲突检测：

- 检测到 `svm` 已被**非本工具**占用 → 自动降级到 `svmgr` → 再冲突则 `supmgr` → `supvmgr`
- 检测到是本工具旧版本 → 直接覆盖更新
- 也可用 `--as <自定义名>` 一开始就指定一个不冲突的名字

## 使用

```bash
sudo svm                # 进入交互式菜单（首页直接看状态）
sudo svm -c status      # 一次性命令：直接打印状态
sudo svm --help         # 查看所有用法
sudo svm --version      # 显示版本
```

环境变量覆盖默认路径：

```bash
SM_CONF_DIR=/opt/sv/conf.d SM_MAIN_CONF=/opt/sv/supervisord.conf svm
```

二次开发 / source 加载：

```bash
SM_NO_ENTRY=1 source /usr/local/bin/svm   # 加载所有函数但不进入菜单
```

## 配置文件定位（v1.3.2 起）

**supervisord 加载哪些文件，由主配置的 `[include] files` 决定，不是由本工具的 `SM_CONF_DIR` 决定。** 这是旧版"编辑进程配置什么都不显示"的根因：

| 部署来源 | 主配置里的 include | 旧版按 `SM_CONF_DIR=/etc/supervisor/conf.d` 扫描的结果 |
| --- | --- | --- |
| Debian/Ubuntu apt 装 | `files = /etc/supervisor/conf.d/*.conf` | 命中，正常 |
| RHEL/CentOS yum 装 | `files = /etc/supervisord.d/*.ini` | **空列表** |
| pip 装 + 手写主配置 | 进程直接写在 `supervisord.conf` 里，无 include | **空列表** |

现在统一以 include 为准：

1. 解析 `[include] files`，支持**单行多模式**、**多行续行**、**相对路径**（相对主配置所在目录）、**行内 `;` 注释**
2. 展开为实际文件列表（`compgen -G`），`.conf` / `.ini` / 任意后缀都按实际匹配来
3. 解析不到时才退回 `SM_CONF_DIR` 与 `/etc/supervisord.d`、`/etc/supervisor/conf.d` 等常见位置
4. 列表为空时打印诊断：主配置路径、当前 include 模式、以及"进程可能直接写在主配置里"的引导

同一套定位逻辑也用于：

- **添加守护进程的落点**：写入 `[include] files` 第一个可用模式对应的**目录 + 后缀**。写在 `*.ini` 的机器上会生成 `name.ini` 而不是 `name.conf`，后者永远不会被加载
- **日志路径解析**：`stdout_logfile` 等键从真实配置文件中读取，不再死盯 `conf.d`
- **重名检测**：按 `[program:name]` 是否存在判断，而不是看文件是否存在

写入后还有一道自检：若生成的文件不在 include 匹配范围内，立刻告警并打印当前的 include 模式。

## 初次使用流程（典型）

1. `sudo svm` → 首页显示"supervisord 未安装 → 请选择 [1]"
2. 选 `1` 安装 Supervisor
3. 选 `2` 配置开机自启（顺带把 supervisord 拉起来）
4. 选 `3` 添加守护进程，按提示填名称/命令/用户/工作目录/日志路径
5. 回到首页，新进程状态直接显示在看板上
6. 选 `7` 看日志
7. 改配置后选 `9` 重载
8. 选 `0` 退出

## 文件布局

| 路径 | 用途 |
| --- | --- |
| `/etc/supervisor/supervisord.conf` | 主配置（apt/yum 装的超集默认创建，pip 装的由本工具生成） |
| `/etc/supervisor/conf.d/*.conf` | 子进程配置，每个 `[program:name]` 一个文件 |
| `/var/log/supervisor/` | 默认日志目录 |
| `/var/run/supervisor/` | PID / sock 目录 |
| `/var/backups/supervisor-manager/` | 编辑/删除前的自动备份（`<文件名>.<时间戳>.<pid>`）|

## 配置项说明

`sm.sh` 头部可调环境变量：

| 变量 | 默认 | 用途 |
| --- | --- | --- |
| `SM_CONF_DIR` | `/etc/supervisor/conf.d` | 子进程配置目录（**仅作 include 解析失败时的兜底**）|
| `SM_MAIN_CONF` | `/etc/supervisor/supervisord.conf` | 主配置文件 |
| `SM_LOG_DIR` | `/var/log/supervisor` | 日志默认目录 |
| `SM_RUN_DIR` | `/var/run/supervisor` | PID/run 目录 |
| `SM_BACKUP_DIR` | `/var/backups/supervisor-manager` | 编辑/删除前的自动备份目录（0700，不可写时拒绝修改）|
| `SM_NO_CLEAR` | 未设置 | 设为 `1` 禁用首页清屏，保留终端滚动历史 |
| `SM_WIDTH` | 未设置（68） | 固定界面总宽度；不设则默认 68，并在终端更窄时自动收窄 |
| `SM_LOCALE` | 未设置（自适应） | `0` 关闭 locale 自适应；填具体 locale 名（如 `zh_CN.UTF-8`）则强制使用它 |

## 兼容性

- **发行版**：Debian / Ubuntu / CentOS / Rocky / Fedora / Alpine / Arch
- **Init**：systemd（首选）/ OpenRC
- **依赖**：bash ≥ 4.0、`supervisorctl`（安装后）

## 故障排查

| 现象 | 排查 |
| --- | --- |
| 首页显示 `supervisord 未运行` | 选菜单 `2` 启用开机自启 + 立即启动 |
| 首页显示 `无权访问 supervisord socket` | 用 `sudo` 运行本工具，并检查 socket 所属用户，不要随意放宽权限 |
| `socket not found` | 检查主配置 `[unix_http_server] file=...` 与 `[supervisorctl] serverurl=unix://...` 是否一致 |
| 添加进程后状态 FATAL | `supervisorctl tail <name> stderr` 看真实错误；多数是 `command` 路径不对或权限 |
| 改完主配置不生效 | 主配置改端口/socket 必须重启，reread 不够；菜单 `11` 会提示并可直接确认重启 |
| 改完进程配置不生效 | 菜单 `8` 编辑完会主动询问是否重载；若重载失败会打印 supervisorctl 的报错行号 |
| 疑似改坏配置 | 备份在 `SM_BACKUP_DIR`（默认 `/var/backups/supervisor-manager`），`cp -a` 回去即可 |
| **编辑/删除列表是空的** | v1.3.2 已修：旧版只按 `SM_CONF_DIR` 扫描，而 supervisord 实际加载由 `[include] files` 决定。若列表仍空，诊断行会打印主配置路径与 include 模式，据此核对 |
| 进程定义在 supervisord.conf 里 | 不在任何 conf.d 文件内，编辑列表本就该为空；v1.3.2 会直接提示并引导进菜单 `11` |
| 有 FATAL 进程时工具报"未运行" | v1.2.0 已修复（改用 `supervisorctl pid` 探测），升级即可 |
| 首页看板拖慢操作（socket 慢） | 多为 supervisord 卡死；`supervisorctl pid` 也会超时，先看 `tail /var/log/supervisor/supervisord.log` |
| **进菜单后中文乱码** | 先看首屏顶部有没有 `[WARN] 系统中没有可用的 UTF-8 locale`——有就按提示装 locale。没有 WARN 但仍乱码，是**终端软件的编码设置**不是 UTF-8（Xshell/PuTTY/SecureCRT 的"编码"选项），脚本改不了客户端，只能改终端设置 |
| **想关掉自动切 locale** | `SM_LOCALE=0 svm`；或 `SM_LOCALE=zh_CN.UTF-8 svm` 指定用哪个 |
| 表格列对不齐（汉字挤在一起） | v1.3.x 及更早的问题：`printf %-Ns` 在 C locale 按字节补齐、在 UTF-8 下按字符补齐，两种都算不对汉字的显示宽度。v1.4.0 起按显示宽度自行计算，升级即可 |
| 终端很窄时表格被折行 | v1.4.0 起终端窄于 68 列自动收窄名称列；想固定宽度用 `SM_WIDTH=60 svm` |

## v1.4.0 修复记录（locale 自适应 + 界面对齐）

### 1. 进菜单前自动把本进程切到 UTF-8 locale

**问题**：`sudo` 默认 `env_reset` 会清掉 `LANG`/`LC_*`，脚本于是在 C locale 下运行——bash 把一个汉字当成 3 个字节，界面文字按字节截断、中文输入也可能被切坏。

**做法**（`_ensure_utf8_locale`）：

1. 用 bash 自己的字符计数探测：UTF-8 下 `${#"中"}` 是 1，C locale 下是 3
2. 已是 UTF-8 → 什么都不动
3. 不是 → 在子 shell 里逐个试候选 locale，取第一个真正可用的：`SM_LOCALE` 指定的 → 与 `LANG` 同语言的 `.UTF-8` 变体（如 `zh_CN.GBK` → `zh_CN.UTF-8`）→ `C.UTF-8` → `en_US.UTF-8` → `zh_CN.UTF-8`
4. 有 `LC_ALL` 时只能整体覆盖它（优先级最高）；否则只设 `LC_CTYPE`，消息语言等其他类别保持用户原设置
5. 首屏顶部提示一行 `locale C -> C.UTF-8（原 locale 非 UTF-8，已自动切换）`，并附一行英文：切换前终端若是乱码，这行英文能看懂

**边界（脚本改不了的）**：终端软件自身的解码方式（Xshell / PuTTY 的"编码"设置）和脚本退出后的父 shell。locale 切了但终端不是 UTF-8，照样乱码——这是客户端设置，见故障排查表。

**一个 UTF-8 locale 都没有**（精简容器常见）：给出安装命令（Debian `apt install locales && dpkg-reconfigure locales`；RHEL `localedef -c -f UTF-8 -i zh_CN zh_CN.UTF-8`），不静默吞掉。

### 2. 界面按显示宽度对齐

**根因**：`printf '%-26s'` 的补齐是按**字节**（C locale）或**字符**（UTF-8 locale）数的，而终端按**显示列**渲染——汉字占 2 列。「名称」2 个汉字 4 列，`%-26s` 在 C locale 下补 24 个空格（多 2 个），在 UTF-8 下补 24 个（也多 2 个），正确值是 22 个。所以无论切不切 locale，`printf` 都对不齐；而表头是汉字、数据行是英文，错位一眼可见。

**做法**（`_pad_c`）：在 `LC_ALL=C` 子 shell 里逐字节解析 UTF-8，还原码点，按 East Asian Width 判定每个字符占 1 列还是 2 列（CJK、全角、假名、谚文、4 字节 emoji），ANSI 转义序列计 0 列；不足补空格，超宽截断并以 ASCII `..` 结尾。

| # | 问题 | 修复 |
| --- | --- | --- |
| 1 | 表头与数据列错位、分隔线长度不一 | 所有列统一走 `_pad_c` 按显示宽度补齐；横线由 `_rule` 按同一宽度生成 |
| 2 | 进程名过长撑破表格 | 超过列宽截断为 `名称..`（如 `a-very-very-long-process..`） |
| 3 | `26 days, 3:04:05` 太长 | 压成 `26d 3:04:05`，`365d 23:59:59` 也在 16 列内 |
| 4 | `[INFO]`/`[WARN]`/`[ERROR]`/`[ OK ]` 四种前缀宽度不一 | 统一成 7 字符 + 正文对齐 |
| 5 | 小屏终端折行 | 终端窄于 68 列自动收窄名称列（下限 44 列）；`SM_WIDTH` 可固定 |
| 6 | 启动时自检 | `_sm_width_selftest` 校验 5 组用例（汉字/纯英文/带颜色码/截断），任一不符就退回 `printf` 旧行为，不会比旧版更糟 |

### 3. 性能

宽度计算若用 `x=$(_pad_c ...)` 取结果，每行 3 次 fork，60 个进程 = 180 次。改为 `_pad_c` 直接写变量 `_SM_PAD`，整个渲染零 fork。本机 Windows Git Bash（fork 很慢）实测 60 进程首屏 **5955ms → 943ms**，输出逐字节不变。

### 4. 其他

- source 模式（`SM_NO_ENTRY=1 source sm.sh`）不再解析调用方的位置参数——以前 `source lib.sh "$@"` 会把调用方的参数误当成自己的命令行参数报"未知参数"
- `--help` 补充 `SM_WIDTH` / `SM_LOCALE` / `SM_BACKUP_DIR` 说明

### 验证

- 独立校验脚本（Python `unicodedata.east_asian_width`，与 bash 实现互为对照）在 `C` / `C.UTF-8` / `zh_CN.UTF-8` / `en_US.UTF-8` 四种 locale、68/60/50 三种宽度下均为 `ALL ALIGNED`；`LC_ALL=C` 与 `zh_CN.UTF-8` 输出 md5 相同
- 33 项回归全过：11 项菜单映射、locale 提示仅首屏出现一次、编辑→备份→重载生效/跳过/菜单 9 重载、`--help`、自安装、同版本覆盖

## v1.3.2 修复记录（配置定位）

| # | 问题 | 影响 | 修复 |
| --- | --- | --- | --- |
| 1 | 编辑/删除列表只扫 `SM_CONF_DIR`，不看 `[include] files` | include 指向别处时（RHEL `supervisord.d/*.ini`、或进程内联在主配置）列表**全空**，编辑/删除功能形同不可用 | 新增 `_conf_include_patterns` / `_conf_include_files` / `_conf_source_files`，一律按 include 枚举 |
| 2 | 添加进程固定写 `SM_CONF_DIR/name.conf` | 在 `*.ini` 的机器上写进去也不会被加载，表现为"添加成功但进程一直不出现" | `_preferred_conf_target` 从 include 模式推导**目录 + 后缀**；写入后做 include 覆盖自检并告警 |
| 3 | 重名检测看文件是否存在 | 进程定义在 `other.ini` 里时，再添加同名进程能通过检测，产生重复段 | 改为 `_program_exists`，按 `[program:name]` 段检测 |
| 4 | 日志路径查找只看 `conf.d/name.conf` | 配置不在该路径时日志菜单报"未找到配置" | `_lookup_key` 改为遍历实际加载的配置文件 + 主配置 |
| 5 | 空列表只提示"目录为空" | 用户无从判断是路径错、后缀错，还是进程根本没在文件里 | 新增 `_conf_diag_empty`，打印主配置路径与 include 模式；有内联程序时直接给出"编辑主配置"入口 |

## v1.3.1 修复记录（编辑配置链路）

针对“编辑进程配置”做的专项复查，发现的问题按影响排序：

| # | 问题 | 影响 | 修复 |
| --- | --- | --- | --- |
| 1 | `action_reload` 完全忽略 `supervisorctl reread` 的返回值 | 配置写错时 reread 打印 `ERROR ... line N` 并退出非 0，工具却继续 update 并打印 **`[OK] 重载完成`** + 看板“全部运行中”——**假成功**，用户以为改动生效，实际 supervisord 仍跑旧配置 | 新增 `_do_reload()`：检查退出码与输出里的 `ERROR`，失败即报错并说明“改动未生效” |
| 2 | 编辑完没有任何闭环 | 提示语打印在打开编辑器**之前**，vim 全屏一切就看不见了；改完直接回菜单，很容易忘记重载 | 编辑后对比文件指纹（`cksum`），真改了才提示，并当场询问“是否立即重载”；失败可回到编辑器继续改 |
| 3 | 编辑前不备份 | 配置改坏不可逆 | 编辑前自动备份到 `SM_BACKUP_DIR`，失败只告警不阻塞；出错时直接给出 `cp -a` 回滚命令 |
| 4 | 编辑器退出码被忽略 | vim 崩溃、只读文件、终端异常都不会有任何提示 | 非 0 退出明确报“文件可能没有保存”；找不到编辑器时报错并列出探测过的候选 |
| 5 | 只认 `*.conf` | `[include] files` 不限定后缀，用 `*.ini` 的部署在菜单里根本看不到，编辑/删除无从下手 | 新增 `_list_conf_files()`，`.conf` / `.ini` 都列；并排除主配置本身 |
| 6 | 删除时用文件名当进程名 | 一个文件里定义多个 `[program:x]` 时，`stop <文件名>` 必然 `no such process`，进程还在跑但配置已被删 | 新增 `_conf_entity_names()` 解析真实段名，按段名逐个 stop（含 `[group:x]`）|
| 7 | 删除也走 `reread \|\| true` | 同上，失败无感知 | 统一走 `_do_reload()`，失败时提示可恢复备份 |
| 8 | 主配置编辑提示时机不对 | 提示被编辑器覆盖，且未说明 reread 无效 | 编辑后判断是否改动，明确“必须重启”，并可直接确认 `systemctl restart` |

### 新增能力

- `_backup_file()`：编辑/删除前自动备份，`/var/backups` 不可写时自动退到 `/tmp`
- `_file_sig()`：用 `cksum` 做文件指纹，判断“是否真的改过”，避免无意义重载
- `_do_reload()`：统一的 reread + update 执行与失败判定
- `_pick_editor()`：`$EDITOR` 未设置时按 `vi → vim → nano → emacs` 探测
- `_conf_entity_names()`：从配置文件解析 `[program:x]` / `[group:x]` 段名

## v1.3.0 修复记录

首页看板改造过程中复查出的问题：

| # | 问题 | 影响 | 修复 |
| --- | --- | --- | --- |
| 1 | `_promote_target` 用 `$(...)` 取值，但其内部 `ui_menu` 把选项列表打到 stdout | `target` 变成"整段菜单文本 + 进程名"，`supervisorctl start` 必然 `no such process`——**启停重启全部失效** | 改用全局 `_SM_TARGET`，与 `_SM_MENU_CHOICE` 同一套路，彻底消除命令替换污染 |
| 2 | `{ ... } > file` 组里最后一句是 `[[ -n "$env_str" ]] && echo ...` | env 为空时该判断返回 1，整个组被判为"配置写入失败"，但文件其实已写成功 | 改为 `if [[ ... ]]; then ...; fi` |
| 3 | 首页每轮清屏后立刻重绘 | 部分 action 的错误分支 `return 1` 前没有 `ui_pause`，报错文案会被瞬间刷掉 | 给 `require_root`、`_open_editor`、`_action_ctl`、`action_install`、`action_boot` 的错误分支补 `ui_pause` |
| 4 | 看日志返回后清屏 | `tail -f` 刚读到的内容立刻消失 | `action_log` 返回时置 `_SM_SKIP_CLEAR=1`，下一轮跳过清屏 |
| 5 | 菜单输入直接回车 | 报"请输入数字"，误触时噪音大 | 空输入静默重绘 |
| 6 | 首页每轮都查一次 socket | supervisord 卡死时整个菜单被拖住 | `_supervisor_status_raw()` 加 5 秒 `timeout`，超时提示"可能卡死"并指向 supervisord.log（有 FATAL 时 `status` 返回 3 属正常，不作错误处理） |

### 新增能力

- `_render_status_table()`：首页看板与 `-c status` 共用同一渲染逻辑，返回 `0=正常 / 1=不可用 / 2=无进程`
- `_clear_screen()`：仅在 tty 下清屏，`SM_NO_CLEAR=1` 可关闭
- `ui_menu --bare` / `--zero <文案>`：`--bare` 跳过标题只画分隔线（首页用），`--zero` 自定义 0 号项文案（主菜单显示"退出"）
- `action_reload` 完成后改用统一状态看板，不再直接甩 `supervisorctl status` 原始输出
- `_supervisor_status_raw()`：状态查询带 5 秒上限，socket 卡死不会冻住菜单

## v1.2.0 代码审查修复记录

### 致命问题

| # | 问题 | 影响 | 修复 |
| --- | --- | --- | --- |
| 1 | `supervisor_alive()` 用 `supervisorctl status` 判断存活 | **任一进程非 RUNNING（FATAL/STOPPED/EXITED）时 status 返回退出码 3**，导致误判"supervisord 未运行"，状态/启停/日志/编辑全部不可用 | 改用 `supervisorctl pid` 探测 socket 连通性 |
| 2 | `action_status` awk 列错位 | `$3` 是字面量 `pid`、`$4` 是 `12345,`，表格显示 PID 列为 "pid"、时长列为 "12345," | 按状态分支解析，正确提取 pid/uptime |
| 3 | numprocs 实例无法打开日志 | `worker:0` 去查 `worker:0.conf` 不存在 | 新增 `_lookup_key()`，剥离 `:N`/`:*` 后缀 + 全量段搜索 |
| 4 | `--as` / `--path` 缺参数 | `set -u` 下 `$2` unbound 直接崩溃 | 显式参数个数校验 |
| 5 | `EDITOR="vim -u NONE"` 失效 | 整串被当作单个命令名，command not found | 新增 `_open_editor()`，拆分为参数数组 |

### 健壮性问题

| # | 问题 | 修复 |
| --- | --- | --- |
| 6 | 后续 8 个 `ui_ask` 未处理 EOF | 新增 `_ask_or_abort()`，Ctrl+D 立即中止，不写空配置 |
| 7 | 进程名未校验合法字符 | 强制 `^[A-Za-z0-9_.-]+$`，拒绝空格/斜杠/冒号 |
| 8 | `autostart` 输入 `true` 被转成 `false` | 新增 `_to_bool()`，支持 y/yes/true/1/on |
| 9 | `echo_supervisord_conf` 不存在时生成空配置 | 检测命令存在 + 空文件兜底手写最小配置 |
| 10 | 生成的 unit 中 `ExecStart` 可能为空 | 显式检查 `command -v` 结果，缺失则报错退出 |
| 11 | `enable --now` 后立即 `is-active` 误报失败 | 改为轮询等待（最多 10 秒）+ 区分 failed 状态 |
| 12 | `[include]` 存在但未覆盖配置目录 | 检测 `files` 行内容，仅提示手工修改（**不自动追加重复段**，否则 ConfigParser 报 section 重复导致 supervisord 无法启动） |
| 13 | 配置写入失败无检测 | 检查写入退出码 + 文件存在性 |
| 14 | `rm` 失败仍报"已删除" | 检查退出码 + 二次确认文件已消失 |
| 15 | 输入 `08` 触发八进制错误 | `ui_menu` 内强制 `10#` 十进制规范化 |
| 16 | `-c status` 不检测可用性 | 统一走 `supervisor_alive` + `_report_not_alive` |

### 新增能力

- `_supervisor_diag()` / `_report_not_alive()`：区分"未启动"与"无权限访问 socket"，给出不同处置建议
- `_lookup_key()`：支持精确文件、numprocs 实例、组汇总、多 program 同文件四种配置形态
- `action_log` 对 `AUTO` 模式日志、文件尚不存在的情况给出明确指引
- `action_boot` 用 `systemctl cat` 探测真实 unit 名（覆盖 `/lib`、`/usr/lib`、`/etc` 差异）
- `action_edit_main` 动态探测服务名，不再硬编码 `supervisor`

## License

MIT
