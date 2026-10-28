# McAwake

McAwake 是一款 macOS 菜单栏工具，可在 MacBook 合盖后保持运行。本项目基于 [McAwake](https://github.com/taufiqxr/McAwake) 二次开发，支持首次管理员授权后切换模式，无需每次输入密码。

## 功能

- **Always Awake**：接通电源或使用电池时保持唤醒。电量不高于 15% 时恢复睡眠，达到 18% 或接通电源后重新保持唤醒。
- **Smart Auto**：接通电源时保持唤醒，使用电池时允许正常睡眠。
- **Normal Sleep**：恢复 macOS 正常睡眠。
- 菜单栏显示当前电源状态，保留上游的本地服务查看、通知和 Claude Code 会话切换功能。

## 系统要求

- macOS 13 或更高版本。
- 管理员账号，用于首次安装守护进程，以及后续修复或更新。
- 从源码构建需要 Xcode Command Line Tools。

## 构建与运行

在项目根目录运行：

```bash
cd src/mc-awake
./build.sh
open build/McAwake.app
```

构建结果为 `src/mc-awake/build/McAwake.app`。本机发布产物按版本存放在 `0_Release/<版本>/`，不纳入 Git 仓库。

应用使用 ad-hoc 签名，未经过 Apple 公证；若 macOS 阻止打开，可在 Finder 中右键选择“打开”。

## 管理员权限

首次选择模式时，应用通过 macOS 授权安装 root LaunchDaemon。之后切换模式无需重复输入密码，守护进程会在电脑重启后继续运行；修复或更新守护进程时可能需要再次授权。应用不保存管理员密码。

守护进程只接受 `normal`、`auto` 和 `always` 三种模式指令；同一用户运行的其他程序也可以发送这些指令。普通睡眠模式下守护进程仍会运行，但不会持续覆盖其他程序的电源设置。

本项目与上游版本共用应用及守护进程标识。使用本版本前请先退出原版；首次授权会替换原版同名守护进程。

## 测试

```bash
cd src/mc-awake
bash tests/test-daemon-logic.sh
```

测试使用模拟系统命令，不需要管理员权限，也不会修改真实的电源设置。

## 卸载

在 `src/mc-awake/` 目录运行 `./uninstall.sh`。脚本会请求管理员授权，移除守护进程、恢复正常睡眠，并删除 `/Applications/McAwake.app`。

## 来源与许可

上游项目为 [taufiqxr/McAwake](https://github.com/taufiqxr/McAwake)。项目保留上游原始版权和 [MIT 许可证](LICENSE)。
