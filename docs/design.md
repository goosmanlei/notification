# 通知镜像与 Codex 接入

## 目标与选择

目标是让多显示器使用者在任一屏幕都看见新通知，并在终端 Codex 需要人工介入时收到持续提醒。采用原生菜单栏应用，使用 AppKit 管理不抢焦点的窗口，SwiftUI 绘制浮层内容。

首版按用户确认采用「同步镜像」：系统原有通知照常显示。用户接受实验性兼容方案，首要目标仍是尽量完整覆盖通知中心收到的通知。系统通知的真实覆盖率需要实测，不能从合成数据库测试推导。

## 为什么观察数据库

Apple 的 `UNUserNotificationCenter` 只管理本应用的通知。它的已送达通知列表和移除方法也受此范围限制，不能注册成所有应用的通知接收器。[Apple 官方说明](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter)

实验方案只读观察通知中心存储：在目前已知的较新系统中，路径为用户主目录下 `Library/Group Containers/group.com.apple.usernoted/db2/db`；旧系统路径位于 `DARWIN_USER_DIR/com.apple.notificationcenter/db2/db`。新路径及 `record.data` 的 `req.titl`、`req.subt`、`req.body` 字段在另一项目的 macOS 26.5 实测记录中出现过，这是兼容性线索，不是 Apple 的接口承诺。[原作者的字段校准记录](https://github.com/Ngaizean/wechat-priority-notifier/blob/master/research/live-calibration.md)

实现使用 SQLite 只读连接，每秒检查 `data_version`。无变化时不扫描正文；有变化时读取记录并以展示内容生成指纹。首次读取建立基线，之后产生的新记录或内容变化才进入浮层。响应、关闭等元数据变化不会导致重复提示。数据库文件被替换后重新建立基线。

这个方案可能漏掉尚未保存、刚保存就被删除或结构无法解析的通知。监测系统实际通知流、数据库观察和对既有记录的回放是不同能力；首版只实现数据库观察。系统的完全磁盘访问控制是读取前提，不通过修改系统数据库或绕过系统权限获取内容。

## Codex CLI 路径

Codex 的官方 hooks 提供 `PermissionRequest`，并允许通过 `PreToolUse`、`PostToolUse` 观察本地函数工具。当前工具覆盖存在例外，非托管 hooks 需要用户检查并信任。[OpenAI 官方 hooks 文档](https://learn.chatgpt.com/docs/hooks)

安装器配置提醒命令 `Notification --codex-hook`。命令读取标准输入的事件，把最少必要的标题、问题摘要、会话标识和项目目录名写入当前用户私有收件目录。GUI 进程收到事件后同步展示；原始命令和完整参数不被保存。hook 以成功状态退出且不返回审批决定，不改变终端的审批流程。

同步工具完成时，以会话、轮次、工具名和参数指纹匹配并清除提醒。异步提问调用返回不代表用户已回答，因此保持提醒，直到用户继续会话或手动关闭。该行为必须结合实际 CLI 版本验证。

App Server 也定义了等待审批、等待用户输入的状态及请求事件。本机 0.159.0 导出的协议包含这些类型，但本轮共享后台旁路连接探测没有收到初始化回应，故未把它接成首版数据源。[OpenAI App Server 文档](https://learn.chatgpt.com/docs/app-server)

## 展示与数据生命周期

同一条提醒在每个 `NSScreen` 上创建对应的非激活浮层，位置基于该屏幕的可用区域计算。屏幕布局变化后重建窗口。普通提醒显示约 10 秒；人工介入提醒持续显示，在任何屏幕关闭后同步消失。

菜单栏维护暂停、内容隐藏、最近提醒和登录启动。登录启动使用 `SMAppService.mainApp`，默认由用户在菜单中选择开启。[Apple SMAppService 文档](https://developer.apple.com/documentation/servicemanagement/smappservice)

最近提醒仅在内存中保留。锁屏或休眠时清除浮层；系统锁屏通知名称不是稳定公开契约，需按 macOS 版本验证。浮层不具备通知中心的专注模式语义，使用者可显式暂停。
