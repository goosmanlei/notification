# 稳定知识

## 项目说明

开发 macOS 通知工具：常驻菜单栏，在所有连接屏幕的水平居中、靠上位置同步显示显眼浮层。

用户确认的目标（2026-09-30）：

- 在 GitHub 新建公开项目维护。
- 覆盖所有应用送入 macOS 通知中心的通知。用户随后明确接受「同步镜像」：系统和本工具同时提示即可，首版不要求隐藏原生通知。
- 自行设计菜单栏图标。
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
- 2026-09-30：本机 macOS 26.6.2、Swift 6.4、Codex CLI 0.159.0；用对应命令核验。本机通知数据库存在，当前进程只读访问返回 `authorization denied`。这不能证明最终应用授权后的读取结果。
