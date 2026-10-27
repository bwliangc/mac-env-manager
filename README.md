# MacEnvManager

MacEnvManager 是一个原生 macOS 环境变量管理器。通过勾选框启用或停用变量，统一同步到 Bash、Zsh、sh、dash、ksh、csh、tcsh 和当前 GUI 登录会话，不需要选择或切换终端类型。

## 功能

- 勾选启用，取消勾选停用；停用时保留变量名和值，方便随时恢复
- 新增变量默认不启用，支持保存时勾选或在列表中直接勾选
- 已启用变量同时应用到七种 Shell 和当前 GUI 登录会话
- 系统 Bash 和 Homebrew Bash 共用用户配置
- 自动接入登录和交互式启动文件，启动应用时修复缺失的加载区块
- 修改配置前自动备份，最多保留 40 份
- 默认隐藏变量值
- 只修改当前用户配置，不写入 `/etc`，不请求管理员权限

## 系统要求

- macOS 13 或更高版本
- Apple Silicon 或 Intel Mac
- Bash、Zsh、sh、dash、ksh、csh 或 tcsh

Terminal、iTerm2、Warp 和 VS Code 集成终端等终端应用无需分别维护变量，使用以上 Shell 即可。Fish、Nushell 等其他 Shell 尚未适配。

## 安装

1. 打开 `MacEnvManager-1.4.0-universal.dmg`。
2. 将 `MacEnvManager.app` 拖入 `Applications`。
3. 启动“环境变量管理器”。

升级后首次启动会自动迁移已保存的变量并接入全部支持的 Shell，不需要重新添加变量。旧版已生效的变量保持勾选；之后的勾选状态会被保存。

1.4.0 已移除 PATH 页面和管理功能。升级时会备份旧配置，并移除受管环境文件中的旧 PATH 注入；系统及用户自行维护的 PATH 配置保持不变。已经运行的进程可能仍继承旧 PATH，应退出并重新启动相关应用。

## 使用

### 环境变量

主界面直接显示变量列表，无需切换页面。点击“+”添加变量，填写名称和值后保存。新增变量默认不勾选“启用此变量”，此时只保存数据。

- 勾选列表中的“启用”，或在编辑窗口中勾选“启用此变量”，会同步启用到七种 Shell 和当前 GUI 登录会话。
- 取消勾选会停用变量并移除 GUI 会话中的值，变量名和值继续保留。Shell 加载时会显式清除该变量，防止从父进程继承旧值。
- 编辑或改名会保留原有勾选状态；删除会彻底移除已保存的变量。

每次修改都会先检查所有受管配置，写入失败时恢复原文件、GUI 变量和勾选状态。

已经运行的终端和 GUI 应用无法被其他进程直接修改。安装或更新后，退出并重新启动终端应用（包括 VS Code），以继承新的变量和启动入口。也可以在当前 Bash/Zsh/sh/dash/ksh 终端执行：

```bash
. "$HOME/Library/Application Support/MacEnvManager/environment.zsh"
```

csh/tcsh 使用：

```csh
source "$HOME/Library/Application Support/MacEnvManager/environment.csh"
```

手动加载可启用或停用当前配置中的变量；删除或改名后，应重新打开 Shell 来清除旧进程里已经继承的旧变量。GUI 应用需重启后才能继承更改。

检查变量是否存在时，应使用应用中完全相同的变量名。例如：

```bash
if [[ -n "${OPENAI_API_KEY:-}" ]]; then
  echo "已生效"
else
  echo "未生效"
fi
```

## Shell 接入规则

应用维护一份 POSIX 兼容环境文件，以及一份使用 `setenv` 的 C-shell 环境文件。以下配置自动加入带明确标记的加载区块：

| Shell | 接入位置 |
|---|---|
| Zsh | `.zshenv`、`.zprofile`、`.zshrc`、`.zlogin` |
| Bash（系统版及 Homebrew 版） | `.bashrc`；登录时使用已存在的 `.bash_profile`、`.bash_login`、`.profile` 中优先级最高的一份 |
| sh、dash | `.profile`；交互式会话通过 `ENV` 加载 `posix-init.sh`，保留已有 `.shrc` 内容 |
| ksh | `.profile`、`.kshrc`；交互式会话也接入 `ENV` |
| csh、tcsh | `.cshrc`、`.login`；已有 `.tcshrc` 时同步接入，未存在时不创建，以免遮蔽 `.cshrc` |

即使 Bash 使用 `.bash_profile`，应用也会独立接入 `.profile`，供 sh/dash/ksh 使用。启动文件中的其他内容和权限会保留。

`ENV` 是 sh/dash/ksh 的交互式启动入口。应用将它指向受管桥接文件；已有 `ENV` 文件路径保存在 `_MAC_ENV_MANAGER_ORIGINAL_ENV`，先加载原文件，再加载统一变量。该入口从 Shell 配置与当前 GUI 会话同时传递给新启动的子进程。

每次启动应用都会修复受管加载区块，并根据勾选状态重新同步当前 GUI 登录会话：启用的变量写入，停用的变量清除。非交互式脚本一般继承父进程环境；主动清空环境（例如 `env -i`）、使用 `--norc`/`-f` 禁用启动配置或自定义 `ZDOTDIR` 的进程不保证自动加载。应用不接管 Docker、远程 SSH 主机或系统守护进程。

## 数据与安全

数据保存在：

- 状态：`~/Library/Application Support/MacEnvManager/state.json`
- 环境文件：`~/Library/Application Support/MacEnvManager/environment.zsh`
- C-shell 环境文件：`~/Library/Application Support/MacEnvManager/environment.csh`
- POSIX 交互式启动桥接：`~/Library/Application Support/MacEnvManager/posix-init.sh`
- 备份：`~/Library/Application Support/MacEnvManager/Backups`

状态、环境文件和备份使用 `0600` 权限，仅当前用户可读写。所有变量值和勾选状态保存在状态文件中；停用变量的值不写入 Shell 环境文件。已启用变量中的令牌或密钥会传递给新启动的终端、GUI 应用及其子进程。当前 GUI 会话中的值会在注销时消失，并在下次打开 MacEnvManager 时按已保存的勾选状态重新同步。

C-shell 文件为安全处理引号、`!` 等字符使用 Base64 编码已启用变量的值，编码不提供加密保护。`PATH` 等系统变量保持受保护；`ENV`、`BASH_ENV` 和 `_MAC_ENV_MANAGER_` 前缀由加载机制管理，不能作为普通变量覆盖。

## 构建与测试

项目使用 SwiftUI 和 macOS Command Line Tools，不依赖第三方库。

运行测试：

```bash
./Scripts/test.sh
```

构建通用架构应用和 DMG：

```bash
./Scripts/build_dmg.sh
```

输出文件位于 `dist/MacEnvManager-1.4.0-universal.dmg`。本地构建采用 ad-hoc 签名；公开分发需要 Apple Developer ID 签名和公证。

## 项目结构

```text
MacEnvManager/
├── Resources/   应用元数据
├── Scripts/     测试、图标和 DMG 构建脚本
├── Sources/     SwiftUI 应用源码
└── Tests/       核心逻辑与 Shell 集成测试
```
