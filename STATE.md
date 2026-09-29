# 当前状态

首个实验版本已实现并完成构建与基础验证：原生多屏浮层、菜单栏常驻、通知数据库只读观察、终端 Codex hooks 接入。用户已明确采用同步镜像展示，保留系统原有通知。

公开维护仓库：[goosmanlei/notification](https://github.com/goosmanlei/notification)。使用和开发入口为 [README.md](README.md)，已实现行为与限制见 [技术说明](docs/design.md)，检查证据与未验证项见 [验证记录](docs/verification.md)。

2026-09-30 交付状态：

- 应用已安装到用户的 `~/Applications/Notification.app`，构建及本地临时签名检查通过。
- 六组核心检查、两组 hooks 安装器检查通过；实际浮层组件已离屏渲染检查。
- 提醒 hooks 已安装至当前用户的 `~/.codex/hooks.json`，未代替用户标记信任。未修改原生通知设置或开启登录启动。
- 系统通知数据库当前读取受权限阻挡。Computer Use 绑定应用窗口返回 `cgWindowNotFound`，真实多屏界面未完成自动化验收；离屏渲染不替代这一项。

下一步：用户为最终应用开启完全磁盘访问，并在 Codex CLI `/hooks` 中检查、信任新增 hooks 后，验证真实系统通知及人工介入事件。
