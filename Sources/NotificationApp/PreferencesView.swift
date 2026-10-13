import SwiftUI
import NotificationCore

private typealias PreferencesState<Value> = SwiftUI.State<Value>

struct PreferencesView: View {
    @PreferencesState private var draft: NotificationPreferences
    @PreferencesState private var saved = false
    @PreferencesState private var saveError: String?
    @PreferencesState private var sampleTitle = "项目群"
    @PreferencesState private var sampleBody = "[加急] @你 请确认今天的发布计划。"
    let onSave: (NotificationPreferences) throws -> Void

    init(preferences: NotificationPreferences, onSave: @escaping (NotificationPreferences) throws -> Void) {
        _draft = PreferencesState(initialValue: preferences); self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("通知策略与过滤规则").font(.title2.bold())
            Text("分别设置是否通知、停留时间及过滤范围。").font(.caption).foregroundStyle(.secondary)
            TabView {
                retentionPage.tabItem { Text("通知策略") }
                filterPage.tabItem { Text("飞书消息过滤") }
                recognitionPage.tabItem { Text("文字识别") }
                previewPage.tabItem { Text("规则试算") }
            }
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    if let error = draft.validationError ?? saveError {
                        Text(error).foregroundStyle(.red)
                    } else if saved { Text("已保存").foregroundStyle(.secondary) }
                    Text("保存后对新收到的通知生效，当前浮层保持原策略。").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("保存设置") {
                    do { try onSave(draft); saved = true; saveError = nil }
                    catch { saveError = error.localizedDescription }
                }.keyboardShortcut("s", modifiers: .command).disabled(draft.validationError != nil)
            }
        }.padding(22).frame(minWidth: 700, minHeight: 600)
            .onChange(of: draft) { _ in saved = false; saveError = nil }
    }

    private var retentionPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox("Codex CLI") {
                    VStack(alignment: .leading, spacing: 16) {
                        Toggle("tmux 在前台时，不通知当前 session/window 内的 pane", isOn: $draft.suppressForegroundTmuxWindow)
                        Text("适用于该窗口内所有 pane 的审批、提问和完成提醒。需要 tmux 开启 focus-events 且终端支持焦点上报；无法确认前台窗口时仍通知。")
                            .font(.caption).foregroundStyle(.secondary)
                        RetentionRow(title: "审批与提问", policy: $draft.codex)
                        Divider()
                        RetentionRow(title: "任务完成", policy: $draft.codexCompletion.retention)
                        completionFilters
                    }.padding(10)
                }
                GroupBox("Codex桌面端") {
                    VStack(alignment: .leading, spacing: 10) {
                        RetentionRow(title: "所有通知", policy: $draft.codexDesktop)
                        Text("审批、提问、任务完成和桌面端系统通知统一使用此策略，独立于终端设置。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(10)
                }
                GroupBox("飞书通知") {
                    VStack(spacing: 16) {
                        RetentionRow(title: "消息", policy: $draft.feishu.message)
                        RetentionRow(title: "日历", policy: $draft.feishu.calendar)
                        RetentionRow(title: "其他", policy: $draft.feishu.other)
                    }.padding(10)
                }
                GroupBox("其他应用") {
                    RetentionRow(title: "系统通知", policy: $draft.otherApps).padding(10)
                }
                Text("选择「不通知」后，不显示浮层，也不加入队列或最近提醒。Codex桌面端、其他应用和终端任务完成默认不通知，启用并保存后生效。")
                    .font(.callout).foregroundStyle(.secondary)
                Text("计时从浮层真正显示时开始。「等待处理」持续显示：Codex 在会话继续或相应操作完成后清除；其他提醒需关闭卡片或打开来源应用。飞书类型可在「文字识别」中调整。")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(18)
        }
    }

    private var completionFilters: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("完成通知表示本轮回复结束，可返回 Codex 查看结果。").font(.caption).foregroundStyle(.secondary)
            Toggle("仅通知以下目录及其子目录", isOn: $draft.codexCompletion.filterDirectories)
            if draft.codexCompletion.filterDirectories {
                ForEach($draft.codexCompletion.directories) { $directory in
                    HStack(spacing: 10) {
                        Toggle("启用目录", isOn: $directory.enabled).labelsHidden().help("启用这个目录")
                        TextField("例如 ~/codex-path/learning", text: $directory.path)
                            .textFieldStyle(.roundedBorder).accessibilityLabel("完成通知目录")
                        Button("删除") {
                            let id = directory.id
                            draft.codexCompletion.directories.removeAll { $0.id == id }
                        }
                    }
                }
                Button { draft.codexCompletion.directories.append(CompletionDirectory()) } label: {
                    Label("添加目录", systemImage: "plus")
                }
                Text("命中任一启用目录即可通知。例如 ~/codex-path/learning 包含其下所有项目；learning-other 不会命中。支持绝对路径及 ~/，可添加多个目录。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("未开启目录过滤：启用任务完成通知后，适用于所有已接入的项目。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var filterPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Toggle("仅显示符合以下条件的飞书消息", isOn: $draft.feishu.filterMessages)
                Picker("显示条件", selection: $draft.feishu.matchMode) {
                    Text("任一条件命中").tag(FeishuPreferences.MatchMode.any)
                    Text("全部条件命中").tag(FeishuPreferences.MatchMode.all)
                }.pickerStyle(.segmented)
                ForEach($draft.feishu.conditions) { $condition in
                    HStack(spacing: 10) {
                        Toggle("启用", isOn: $condition.enabled).labelsHidden().help("启用这条条件")
                        Picker("匹配条件", selection: $condition.kind) {
                            Text("内容包含").tag(MessageCondition.Kind.contains)
                            Text("@我的消息").tag(MessageCondition.Kind.mentionsMe)
                            Text("加急消息").tag(MessageCondition.Kind.urgent)
                        }.labelsHidden().frame(width: 140)
                        if condition.kind == .contains {
                            TextField("填写关键词，匹配标题和正文", text: $condition.keyword)
                        } else {
                            Text("使用「文字识别」中的匹配词").font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Button("删除") {
                            let id = condition.id
                            draft.feishu.conditions.removeAll { $0.id == id }
                        }
                    }
                }
                Button { draft.feishu.conditions.append(MessageCondition()) } label: { Label("添加条件", systemImage: "plus") }
                Text("可添加多条内容关键词条件，例如「发布」或「故障」。关闭过滤时，不按消息内容筛选；是否通知仍由「通知策略」决定。日历和其他通知不受这里的消息过滤影响。")
                    .font(.callout).foregroundStyle(.secondary)
                Text("@我和加急使用通知文字匹配，无法保证等同于飞书内部属性。可在「文字识别」中补充自己的 @姓名，并用「规则试算」核对效果。")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(18)
        }
    }

    private var recognitionPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("每行一个关键词，不区分英文大小写，按原文包含匹配。先匹配标题，再匹配正文；同一范围内按日历 → 其他判断，均未命中时按消息处理。")
                    .font(.callout).foregroundStyle(.secondary)
                KeywordEditor(title: "日历通知", text: $draft.feishu.calendarKeywords)
                KeywordEditor(title: "其他通知", text: $draft.feishu.otherKeywords)
                KeywordEditor(title: "@我的消息（可加入自己的 @姓名）", text: $draft.feishu.mentionKeywords)
                KeywordEditor(title: "加急消息", text: $draft.feishu.urgentKeywords)
                Text("默认识别 ⚡加急⚡ 标记，兼容闪电符号的显示差异及标记内空格。正文只出现普通文字「加急消息」不会因此命中默认规则。")
                    .font(.callout).foregroundStyle(.secondary)
                Text("识别只使用系统实际提供的标题和正文。隐藏预览、不同语言和普通聊天中出现这些词都可能影响结果；本工具不读取飞书聊天记录。")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(18)
        }
    }

    private var previewPage: some View {
        let notice = Notice(source: "飞书", title: sampleTitle, body: sampleBody, bundleID: "com.electron.lark")
        let decision = draft.decision(for: notice)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("输入一条飞书通知的样例文字，使用当前尚未保存的配置试算。不会发送消息或弹出通知。")
                    .font(.callout).foregroundStyle(.secondary)
                TextField("通知标题", text: $sampleTitle)
                KeywordEditor(title: "通知正文", text: $sampleBody, height: 130)
                GroupBox("试算结果") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("分类：\(decision.feishuType?.title ?? "其他应用")")
                        Text(decision.show ? "结果：显示浮层" : (decision.retention.isEnabled ? "结果：不通知（消息过滤未通过）" : "结果：不通知（已关闭此类通知）"))
                            .fontWeight(.semibold)
                        if decision.show {
                            Text(decision.retention.mode == .untilHandled ? "停留：一直显示，等待处理" : "停留：\(decision.retention.seconds) 秒后消失")
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
            }.padding(18)
        }
    }
}

private struct RetentionRow: View {
    let title: String
    @Binding var policy: RetentionPolicy
    var body: some View {
        HStack(spacing: 12) {
            Text(title).frame(width: 100, alignment: .leading)
            Picker("通知策略", selection: $policy.mode) {
                Text("不通知").tag(RetentionPolicy.Mode.disabled)
                Text("定时消失").tag(RetentionPolicy.Mode.timed)
                Text("等待处理").tag(RetentionPolicy.Mode.untilHandled)
            }.labelsHidden().frame(width: 160).accessibilityLabel(title + "通知策略")
            if policy.mode == .timed {
                TextField("秒数", value: $policy.seconds, format: .number).frame(width: 70)
                Text("秒").foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

private struct KeywordEditor: View {
    let title: String
    @Binding var text: String
    var height: CGFloat = 70
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.medium))
            TextEditor(text: $text).font(.body).frame(height: height)
                .padding(5).background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                .accessibilityLabel(title)
        }
    }
}
