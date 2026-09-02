# MacEnvManager

MacEnvManager 是一个原生 macOS 环境变量管理器。它用统一界面管理终端变量、`PATH` 和当前 GUI 登录会话变量，不需要手动选择 Bash 或 Zsh 配置文件。

## 功能

- 同时支持 Bash 与 Zsh，包括登录 Shell 和交互式 Shell
- 管理普通环境变量以及 `PATH` 条目顺序
- 通过 `launchctl` 管理当前 GUI 登录会话变量
- 修改配置前自动备份，最多保留 40 份
- 默认隐藏变量值
- 只修改当前用户配置，不写入 `/etc`，不请求管理员权限

## 系统要求

- macOS 13 或更高版本
- Apple Silicon 或 Intel Mac
- Bash 或 Zsh

Terminal、iTerm2、Warp 和 VS Code 集成终端等终端应用都可使用，只要其中运行的是 Bash 或 Zsh。当前版本不管理 Fish、Csh 等其他 Shell。

## 安装

1. 打开 `MacEnvManager-1.1.0-universal.dmg`。
2. 将 `MacEnvManager.app` 拖入 `Applications`。
3. 启动“环境变量管理器”。

## 使用

### 终端变量

在“终端变量”页面添加或编辑变量。保存后，所有新打开的 Bash 与 Zsh 终端都会加载该变量。

已经打开的终端不会被其他进程直接修改。重新打开终端即可生效，也可以在当前终端执行：

```bash
source "$HOME/Library/Application Support/MacEnvManager/environment.zsh"
```

检查变量是否存在时，应使用应用中完全相同的变量名。例如：

```bash
if [[ -n "${OPENAI_API_KEY:-}" ]]; then
  echo "已生效"
else
  echo "未生效"
fi
```

### PATH

在“PATH”页面添加目录，并用上下箭头调整优先级。列表顶部的目录会出现在最终 `PATH` 的最前面；重复目录不会再次加入。

### GUI 会话

“GUI 会话”页面通过 `launchctl setenv` 修改当前登录会话。此类变量不会持久化到下次登录，并且通常只对修改后启动的 GUI 应用有效。

## Shell 接入规则

应用维护一份 Bash/Zsh 均可读取的环境文件，并在下列启动文件中加入带明确标记的加载区块：

- Zsh：`.zshrc`、`.zprofile`
- Bash 交互 Shell：`.bashrc`
- Bash 登录 Shell：依次选择已存在的 `.bash_profile`、`.bash_login`、`.profile`；都不存在时创建 `.bash_profile`

应用不会覆盖启动文件中的其他内容。切换接入位置或升级配置时，非受管内容会被保留。

## 数据与安全

数据保存在：

- 状态：`~/Library/Application Support/MacEnvManager/state.json`
- 环境文件：`~/Library/Application Support/MacEnvManager/environment.zsh`
- 备份：`~/Library/Application Support/MacEnvManager/Backups`

状态、环境文件和备份使用 `0600` 权限，仅当前用户可读写。持久终端变量仍以明文存储；环境变量中的令牌或密钥也会传递给终端启动的子进程。GUI 会话变量的值不写入应用状态，但会由当前用户的 `launchd` 会话持有直到注销。

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

输出文件位于 `dist/MacEnvManager-1.1.0-universal.dmg`。本地构建采用 ad-hoc 签名；公开分发需要 Apple Developer ID 签名和公证。

## 项目结构

```text
MacEnvManager/
├── Resources/   应用元数据
├── Scripts/     测试、图标和 DMG 构建脚本
├── Sources/     SwiftUI 应用源码
└── Tests/       核心逻辑与 Shell 集成测试
```
