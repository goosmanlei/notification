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
            TabView {
                retentionPage.tabItem { Text("停留策略") }
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
                GroupBox("Codex 人工介入提醒") {
                    RetentionRow(title: "审批与提问", policy: $draft.codex).padding(10)
                }
                GroupBox("飞书通知") {
                    VStack(spacing: 16) {
                        RetentionRow(title: "消息", policy: $draft.feishu.message)
                        RetentionRow(title: "日历", policy: $draft.feishu.calendar)
                        RetentionRow(title: "其他", policy: $draft.feishu.other)
                    }.padding(10)
                }
                Text("计时从浮层真正显示时开始。选择等待处理时，Codex 会在任务继续或相应操作完成后清除；飞书需关闭卡片或点击打开应用。")
                    .font(.callout).foregroundStyle(.secondary)
                Text("飞书类型按通知标题和正文的关键词识别，可在「文字识别」中调整。其他应用仍显示 10 秒。")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(18)
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
                Text("可添加多条内容关键词条件，例如「发布」或「故障」。关闭过滤时，所有飞书消息均显示；日历和其他通知不受这里的消息过滤影响。")
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
                        Text(decision.show ? "结果：显示浮层" : "结果：不显示（消息过滤未通过）")
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
            Picker("停留策略", selection: $policy.mode) {
                Text("定时消失").tag(RetentionPolicy.Mode.timed)
                Text("等待处理").tag(RetentionPolicy.Mode.untilHandled)
            }.labelsHidden().frame(width: 160)
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
