# mac-hid-session

macOS 上的有界虚拟键鼠会话：一次系统授权，在任务期间复用同一套 DriverKit 键盘和鼠标。

适合需要分多步操作 TextEdit、微信等原生界面的本机任务。它是输入层，不包含微信协议、聊天数据库读取、图片识别或自动回复。

## 改善什么

- 会话中复用同一个客户端与键鼠设备，减少每次动作重新初始化的等待。
- 默认最多 2 小时、空闲 30 分钟自动退出、最多 500 个动作。有效操作刷新空闲计时，状态查询不会无限续期。
- `start` 遇到仍有效的会话直接复用，不重复请求管理员授权。
- 一批最多 16 个动作；每个动作仍检查前台应用、显示器几何和当前登录用户。
- 同一请求 ID 重发只返回已存结果，不重复执行；不同内容复用同一 ID 被拒绝。
- 每个动作返回用时和输入报告数量，便于分清输入耗时与外围识别/调度耗时。

默认保留已经小范围验证过的鼠标步进和按键时长。主要提速来自会话复用、去掉每步固定一秒等待和批量执行，不通过加快连点来试探应用。

**没有“永不掉线”的保证。** 应用的安全策略不受本程序控制。早期单步 DriverKit 路线已完成一次微信业务操作而未观察到重登；优化版的实测范围见 [验证记录](docs/validation.md)。主聊天窗口截图限制也没有因此解决。

## 构建

需要 macOS、Xcode Command Line Tools、Python 3、Git，以及单独安装并批准的官方
[Karabiner-DriverKit-VirtualHIDDevice 8.6.0](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/releases/tag/v8.6.0)。
本项目不会自动安装驱动或批准系统扩展。
固定版本已经包含完整依赖头文件，获取后直接编译，不需要另装 CMake。

```sh
sh scripts/fetch-deps.sh
sh scripts/build.sh
python3 -m unittest discover -s tests -v
```

如已有同版本准备好的上游源码与 vendor headers，可用 `HID_UPSTREAM_DIR=/path/to/upstream sh scripts/build.sh`。
版本和依赖许可证见 [第三方声明](THIRD_PARTY_NOTICES.md)。

## 使用

先准备文件和操作目标，然后按需启动：

```sh
python3 hidctl.py start
python3 hidctl.py status
```

首次启动本轮会话时，在 macOS 提示中输入密码或用 Touch ID 批准。密码不经过 Python 或本程序。
同一会话内不需要每次点击重新授权。会话结束后重新启动仍需要系统批准；初次设备识别也可能弹出键盘设置助理。

在 TextEdit 已打开的测试文档中验证：

```json
{
  "id": "textedit-check-001",
  "op": "batch",
  "app": "com.apple.TextEdit",
  "actions": [
    {"type": "activate"},
    {"type": "key", "key": "test-x"}
  ]
}
```

保存为 `check.json`，先做无输入验证，再显式执行：

```sh
python3 hidctl.py batch check.json
python3 hidctl.py batch check.json --execute
python3 hidctl.py result textedit-check-001
python3 hidctl.py stop
```

无 `--execute` 时只验证，不启动服务、不连接设备、不发输入。`activate` 只能是本批第一步，且只激活已打开的目标应用；没有隐式抢回焦点。其他应用抢前台时停止，保留部分执行结果。

支持动作：`activate`、`key`、`move`、`click`、`double-click`、`scroll`。
键盘组合见 `src/protocol.hpp` 的固定列表。`test-x` 仅允许 TextEdit。
鼠标动作需要当前屏幕坐标 `x`、`y`，滚动额外提供 `delta`（-100 到 100，非零）。
键盘、鼠标动作可提供 `settle_ms`（50–2000，默认 150），由界面是否就绪决定，不应盲目追求零等待。

### 微信操作边界

- 操作前从当前界面核对准确聊天；程序只校验应用，无法替你识别正确收件人或登录提示。
- 搜索、选择聊天、粘贴预览、发送应在关键节点分批核对，不把不可预测的整段界面流程盲排成一批。
- 出现重登提示立即停止，交给本人恢复；不自动登录或重放上一条发送。
- `return`、点击和 `cmd+v` 可能产生外部效果，必须由调用者确认其上下文与用户授权。
- 返回输入提交成功不等于应用已接收，更不等于消息已送达；必须回读界面确认。
- `--inspect` 只读取当前前台应用、指针和显示器信息；不读取聊天或截屏。

### 文件粘贴

```sh
swift scripts/clipboard.swift --files /absolute/path/first.png /absolute/path/second.png
```

这只写入文件地址，不读取旧剪贴板，不粘贴、不发送，也不恢复原剪贴板内容。
在正确目标里另行执行 `cmd+v`，核对预览后再发送。

## 会话与权限

官方驱动要求客户端具有 root 权限。`hidctl.py` 通过 macOS 原生管理员提示启动一份经过哈希校验的临时二进制副本。
副本及运行目录由 root 持有，普通用户不能替换正在使用的特权代码；每次会话结束清理。
普通用户客户端通过仅本机 Unix socket 提交有限动作；服务检查对端 UID，客户端也核对服务 UID。
不开放 TCP 端口，不接受任意 shell/文件访问请求，不设置开机自启，不改 sudoers。

若发现官方 daemon 已经运行，本程序会拒绝接管，避免影响其他 Karabiner 使用者。
服务只停止自身启动的官方 daemon。设备断连、用户切换、硬性期限等会结束或阻断输入。

请求/结果在用户的 `~/.local/state/mac-hid-session/` 下保存，目录权限 0700。
日志记录操作类型与统计，不保存剪贴板文本或客户聊天。不要把运行目录、截图、客户素材或登录资料提交进仓库。

## 超时处理

如果调用超时，先用同一个 ID 查 `result`，再查看实际界面。不能换 ID 重试可能已经执行的发送。
断线后仍在的会话保留结果；会话已结束时，内存结果不再可查，应参考本地结果文件和实际界面。
进程被 `SIGKILL` 或断电时无法承诺完成清理，不自动启动新的会话来掩盖旧状态。

详细协议与设计见 [设计文档](docs/design.md)。
