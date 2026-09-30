# 稳定知识

## 项目说明

开发 macOS 通知工具：常驻菜单栏，在所有连接屏幕的水平居中、靠上位置同步显示显眼浮层。

用户确认的目标（2026-09-30）：

- 在 GitHub 新建公开项目维护。
- 覆盖所有应用送入 macOS 通知中心的通知。用户随后明确接受「同步镜像」：系统和本工具同时提示即可，首版不要求隐藏原生通知。
- 自行设计菜单栏图标。
- 浮层宽度保留 880 点；用户最新要求移除底部空白操作栏，tmux 信息和按钮集中到顶栏。实现按内容收紧高度、最高 156 点。状态标签与按钮需有明显的颜色和形态区别。
- 用户要求显示项目目录名；`~/codex-path` 内显示 `<group>/<project>`，有 tmux 上下文时显示 `<session-name>/<window-name>/pane-<pane-index>` 并提供跳转入口，精简每条提醒重复出现的固定文案。
- 用户最新要求取消消息定位：飞书及其他普通通知统一只提供「打开应用」，仅 Codex 任务提醒保留特殊处理。
- 用户反馈飞书提醒晚几秒，要求优化接收速度；需区分本工具检测、系统落库和浮层排队耗时。
- 接收 Codex 人工介入信号（HITL，指需要用户审批或回答问题），优先覆盖终端 Codex CLI。
- 优先覆盖所有应用，接受依赖系统实现、可能随系统升级失效的实验性兼容方案。

来源：创建时的 `--brief`、本会话需求、两项选项回复和随后接受同步镜像的补充。以上为需求，当前实现及验收进度以 [STATE.md](STATE.md) 和 [验证记录](docs/verification.md) 为准。

## 维护入口

- 公开 GitHub 仓库：[goosmanlei/notification](https://github.com/goosmanlei/notification)。2026-09-30 通过 GitHub CLI 创建。
- 安装与后续更新统一部署到 `/Applications/Notification.app`，Codex hooks 默认引用该位置；用户于 2026-09-30 指定。
- 实现选择 Swift / AppKit 菜单栏应用，SwiftUI 绘制浮层，SQLite 只读观察系统通知，Codex 官方 hooks 提供人工介入信号；详见 [技术说明](docs/design.md)。

## 技术依据

- Apple 的 `UNUserNotificationCenter` 仅管理调用应用自己的通知，不能据此实现其他应用通知的全局接管。[官方文档](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter)
- 当前选择验证只读数据库监听：观察系统已落库通知，保留原生通知。完整覆盖范围和接收延迟仍需真实通知验证。
- Codex 官方 hooks 支持 `PermissionRequest` 和本地函数工具的 `PreToolUse` / `PostToolUse`。非托管 hooks 必须由用户检查并信任；提醒 hook 不返回审批决定。[官方文档](https://learn.chatgpt.com/docs/hooks)
- 2026-09-30 实测：macOS 26.6.2、Swift 6.4，本轮运行中的终端 Codex 为 0.159.2。普通通知漏收的已确认原因是 Notification 的完全磁盘访问关闭；用户批准开启后，GUI 恢复监听，并从系统数据库读回本应用经 macOS 投递的测试通知。
- 本机临时签名更新后，完全磁盘访问会失效，需要恢复并重启。部署后的权限验收以实际读取为准。当前实现不再使用辅助功能。
- 接收改为文件变化唤醒与 250 毫秒兜底检查；旧实现正常读取后再次等待一秒的逻辑已移除。真实飞书总延迟仍需以新通知验证，不能用隔离数据库耗时替代；见 [验证记录](docs/verification.md)。
- 共享 Codex 后台服务的 hook 环境不能证明当前终端位置；本机实测两个 CLI 的会话编号分别匹配到各自 pane，不能只依赖后台继承的 `TMUX_PANE`。
