import AppKit
import SwiftUI
import NotificationCore

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class OverlayController {
    private static let preferredWidth: CGFloat = 1320
    private static let cardHeight: CGFloat = 156
    private static let cardSpacing: CGFloat = 15
    private static let horizontalInset: CGFloat = 8
    private static let queueHeight: CGFloat = 39

    /// Render the actual card view with synthetic content for layout review; this is not a live-screen capture.
    static func renderPreview(to url: URL) throws {
        let notices = [
            Notice(source: "Notification", title: "构建已完成", body: "新的应用版本已就绪。", bundleID: "me.leiguoguo.notification"),
            Notice(source: "Codex CLI", title: "待回答", body: "这次构建要使用哪一个目标环境？", kind: .input,
                   context: "tool/notification", tmux: TmuxContext(socketPath: "/tmp/notification-preview", serverPID: 1,
                   sessionID: "$1", windowID: "@1", paneID: "%1", sessionName: "dev", windowName: "notification", paneIndex: 2)),
            Notice(source: "Codex 桌面端", title: "审批请求", body: "发布已通过检查的备份。", kind: .approval,
                   sessionID: "01a00000-0000-7000-8000-000000000001", context: "routine/AutoBackup", codexClient: .desktop)
        ]
        let padding: CGFloat = 24
        let width = preferredWidth - horizontalInset * 2 + padding * 2
        let heights = notices.map { fittedHeight($0, width: preferredWidth - horizontalInset * 2, hideBody: false) }
        let height = heights.reduce(0, +) + CGFloat(notices.count - 1) * cardSpacing + padding * 2
        let view = NSHostingView(rootView: VStack(spacing: cardSpacing) {
            ForEach(Array(notices.enumerated()), id: \.element.id) { index, notice in
                NoticeCard(notice: notice, hideBody: false, dismiss: {}).frame(height: heights[index])
            }
        }.padding(padding).frame(width: width, height: height).background(Color(red: 0.89, green: 0.92, blue: 0.94)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw NSError(domain: "Notification.Preview", code: 1)
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "Notification.Preview", code: 2)
        }
        try png.write(to: url)
    }

    private static func fittedHeight(_ notice: Notice, width: CGFloat, hideBody: Bool) -> CGFloat {
        let view = NSHostingView(rootView: NoticeCard(notice: notice, hideBody: hideBody, dismiss: {})
            .frame(width: width).fixedSize(horizontal: false, vertical: true))
        return min(cardHeight, max(76, ceil(view.fittingSize.height)))
    }

    struct Active {
        var notice: Notice
        var deadline: Date?
        let duration: TimeInterval?
    }
    private struct Pending { let notice: Notice; let retention: RetentionPolicy }
    private var active: [Active] = []
    private var waiting: [Pending] = []
    private var panels: [NSPanel] = []
    private var timer: Timer?
    var paused = false { didSet { if paused { clear() }; render() } }
    var locked = false { didSet { if locked { clear() }; render() } }
    var hideBody = false { didSet { render() } }
    var onChange: (() -> Void)?
    private(set) var dropped = 0
    var pendingCount: Int { active.count + waiting.count }

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.tick() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                              object: nil, queue: .main) { [weak self] _ in self?.render() }
    }

    func show(_ notice: Notice, retention: RetentionPolicy? = nil) {
        guard !paused, !locked else { return }
        let policy = retention ?? RetentionPolicy(mode: notice.requiresAction ? .untilHandled : .timed)
        guard policy.isEnabled else { return }
        guard !active.contains(where: { $0.notice.id == notice.id }), !waiting.contains(where: { $0.notice.id == notice.id }) else { return }
        if waiting.count >= 100 {
            if let index = waiting.firstIndex(where: { $0.retention.duration != nil }) { waiting.remove(at: index) }
            else { waiting.removeFirst() }
            dropped += 1
        }
        let item = Pending(notice: notice, retention: policy)
        if notice.requiresAction { waiting.insert(item, at: 0) } else { waiting.append(item) }
        fill(); render(); onChange?()
    }

    func resolve(id: String) {
        guard active.contains(where: { $0.notice.id == id }) || waiting.contains(where: { $0.notice.id == id }) else { return }
        active.removeAll { $0.notice.id == id }; waiting.removeAll { $0.notice.id == id }
        fill(); render(); onChange?()
    }

    private func setActionInProgress(id: String, _ inProgress: Bool) {
        guard let index = active.firstIndex(where: { $0.notice.id == id }) else { return }
        active[index].deadline = inProgress ? nil : active[index].duration.map { Date().addingTimeInterval($0) }
    }

    func clear(session: String? = nil, preservingCompletions: Bool = false) {
        if let session {
            func matches(_ notice: Notice) -> Bool {
                notice.sessionID == session && (!preservingCompletions || notice.kind != .completion)
            }
            guard active.contains(where: { matches($0.notice) }) || waiting.contains(where: { matches($0.notice) }) else { return }
            active.removeAll { matches($0.notice) }; waiting.removeAll { matches($0.notice) }
        } else { active = []; waiting = [] }
        fill(); render(); onChange?()
    }

    private func fill() {
        // Reserve a slot for timed notifications even when Codex or Feishu cards persist.
        while active.count < 3, !waiting.isEmpty {
            let persistent = active.filter { $0.duration == nil }.count
            let index = persistent >= 2 ? waiting.firstIndex(where: { $0.retention.duration != nil }) : waiting.startIndex
            guard let index else { break }
            let item = waiting.remove(at: index)
            let duration = item.retention.duration
            active.append(Active(notice: item.notice, deadline: duration.map { Date().addingTimeInterval($0) }, duration: duration))
        }
    }

    private func tick() {
        let old = active.count
        active.removeAll { $0.deadline.map { $0 <= Date() } ?? false }
        if active.count != old { fill(); render(); onChange?() }
    }

    func render() {
        panels.forEach { $0.orderOut(nil) }; panels = []
        guard !paused, !locked, !active.isEmpty else { return }
        for screen in NSScreen.screens {
            let width = min(Self.preferredWidth, max(240, screen.visibleFrame.width - 48))
            let visible = active.map(\.notice)
            let heights = visible.map { Self.fittedHeight($0, width: width - Self.horizontalInset * 2, hideBody: hideBody) }
            let height = heights.reduce(0, +) + CGFloat(active.count) * Self.cardSpacing + (waiting.isEmpty ? 0 : Self.queueHeight)
            let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.title = "Notification · \(screen.localizedName)"
            panel.level = .statusBar; panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.isReleasedWhenClosed = false
            let hidden = hideBody
            let count = waiting.count
            let dismiss: (String) -> Void = { [weak self] id in self?.resolve(id: id) }
            let actionState: (String, Bool) -> Void = { [weak self] id, inProgress in self?.setActionInProgress(id: id, inProgress) }
            panel.contentView = NSHostingView(rootView: VStack(spacing: Self.cardSpacing) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, notice in
                    NoticeCard(notice: notice, hideBody: hidden, dismiss: { dismiss(notice.id) },
                               onActionStateChange: { actionState(notice.id, $0) })
                        .frame(height: heights[index])
                }
                if count > 0 {
                    Text("还有 \(count) 条提醒等待显示").font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12).padding(.vertical, 3)
                        .background(.regularMaterial, in: Capsule())
                }
            }.padding(.horizontal, Self.horizontalInset))
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - width / 2,
                                         y: max(frame.minY + 12, frame.maxY - 40 - height)))
            panel.orderFrontRegardless()
            panels.append(panel)
        }
    }
}

// Keep the property wrapper available with Command Line Tools SDKs that omit SwiftUIMacros.
private typealias ViewState<Value> = SwiftUI.State<Value>

private struct NoticeCard: View {
    let notice: Notice
    let hideBody: Bool
    let dismiss: () -> Void
    var onActionStateChange: (Bool) -> Void = { _ in }
    @ViewState private var isOpening = false
    @ViewState private var navigationError: String?
    private var accent: Color { notice.requiresAction ? Color(red: 0.68, green: 0.25, blue: 0.015) : Color(red: 0.045, green: 0.28, blue: 0.70) }
    private let ink = Color(red: 0.10, green: 0.14, blue: 0.20)
    private var background: LinearGradient {
        LinearGradient(colors: notice.requiresAction
            ? [Color(red: 1, green: 0.91, blue: 0.60), Color(red: 1, green: 0.97, blue: 0.86)]
            : [Color(red: 0.82, green: 0.92, blue: 1), Color(red: 0.95, green: 0.98, blue: 1)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: notice.requiresAction ? "hand.raised.fill" : "bell.badge.fill")
                    .font(.system(size: 19, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 40, height: 40).background(accent, in: RoundedRectangle(cornerRadius: 11))
                Text(!hideBody ? notice.context ?? notice.source : notice.source)
                    .lineLimit(1).truncationMode(.middle).font(.system(size: notice.context == nil || hideBody ? 14 : 18, weight: .bold))
                if notice.context != nil && !hideBody {
                    Text(notice.source).lineLimit(1).foregroundStyle(ink.opacity(0.75)).font(.system(size: 12, weight: .medium))
                }
                if let tmux = notice.tmux, notice.codexClient != .desktop, !hideBody {
                    Label(tmux.label, systemImage: "terminal")
                        .font(.system(size: 13, design: .monospaced)).foregroundStyle(ink.opacity(0.80))
                        .lineLimit(1).truncationMode(.middle).layoutPriority(1)
                }
                Spacer(minLength: 4)
                Text(Self.timeFormatter.string(from: notice.createdAt))
                    .font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(ink.opacity(0.75))
                    .fixedSize().help("通知时间：" + notice.createdAt.formatted(date: .numeric, time: .standard))
                    .accessibilityLabel("通知时间 " + Self.timeFormatter.string(from: notice.createdAt))
                if notice.requiresAction {
                    Text(notice.title).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(accent, in: Capsule()).fixedSize()
                }
                actions.fixedSize()
                Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)) }
                    .buttonStyle(NoticeDismissStyle()).help("在所有屏幕关闭此提醒")
                    .accessibilityLabel("关闭提醒")
            }
            if !notice.requiresAction {
                Text(hideBody ? "收到一条新提醒" : notice.title).font(.system(size: 21, weight: .bold)).lineLimit(1)
            }
            if let error = navigationError {
                Text(error).font(.system(size: 13, weight: .semibold)).foregroundStyle(accent).lineLimit(1).help(error)
            } else if hideBody || !notice.body.isEmpty {
                Text(hideBody ? "内容已隐藏" : notice.body).font(.system(size: notice.requiresAction ? 17 : 16, weight: .medium))
                    .foregroundStyle(ink.opacity(0.90)).lineLimit(notice.requiresAction ? 3 : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .topLeading)
        .foregroundStyle(ink)
        .background(background, in: RoundedRectangle(cornerRadius: 18))
        .overlay(alignment: .leading) { Rectangle().fill(accent).frame(width: 6) }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(accent.opacity(0.85), lineWidth: 2))
        .shadow(color: .black.opacity(0.22), radius: 6, x: 0, y: 3)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            if notice.codexClient == .desktop {
                openButtons(target: "Codex 桌面端", systemImage: "app") { completion in
                    CodexDesktopNavigator.open(sessionID: notice.sessionID, completion: completion)
                }
            } else if let tmux = notice.tmux {
                openButtons(target: "tmux", systemImage: "arrow.up.right.square") { completion in
                    TmuxNavigator.open(tmux, completion: completion)
                }
            }
            if notice.codexClient != .desktop && (notice.tmux == nil || navigationError != nil) {
                if let command = notice.resumeCommand {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    } label: { Label("复制恢复命令", systemImage: "doc.on.doc") }
                } else if let bundle = notice.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                    openButtons(target: notice.source, systemImage: "app") { completion in
                        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, error in
                            DispatchQueue.main.async {
                                completion(error.map { "无法打开应用：\($0.localizedDescription)" })
                            }
                        }
                    }
                }
            }
        }
        .buttonStyle(NoticeActionStyle(tint: accent)).font(.system(size: 13, weight: .bold))
    }

    private func openButtons(target: String, systemImage: String,
                             open: @escaping (@escaping (String?) -> Void) -> Void) -> some View {
        HStack(spacing: 10) {
            Button {
                navigate(closeOnSuccess: false, open: open)
            } label: { Label("Go", systemImage: systemImage) }
            .help("打开\(target)，保留此提醒")
            Button {
                navigate(closeOnSuccess: true, open: open)
            } label: { Label("Go & Close", systemImage: systemImage) }
            .buttonStyle(NoticeActionStyle(tint: accent, prominent: true))
            .help("打开\(target)，成功后在所有屏幕关闭此提醒")
        }
        .disabled(isOpening)
    }

    private func navigate(closeOnSuccess: Bool, open: (@escaping (String?) -> Void) -> Void) {
        guard !isOpening else { return }
        isOpening = true; navigationError = nil; onActionStateChange(true)
        open { error in
            isOpening = false; onActionStateChange(false); navigationError = error
            if closeOnSuccess && error == nil { dismiss() }
        }
    }
}

private struct NoticeDismissStyle: ButtonStyle {
    @ViewState private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 40, height: 40)
            .background(.black.opacity(configuration.isPressed ? 0.18 : (isHovered ? 0.12 : 0.06)),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.black.opacity(0.16), lineWidth: 1))
            // Include the space around the symbol in hit testing, including the corners.
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}

private struct NoticeActionStyle: ButtonStyle {
    var tint: Color
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled
    @ViewState private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(prominent ? .white : tint)
            .padding(.horizontal, 12).frame(height: 36)
            .background(prominent ? tint : Color.white.opacity(isHovered ? 0.95 : 0.65),
                        in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(tint, lineWidth: 1.5))
            .overlay(RoundedRectangle(cornerRadius: 9).fill(.black.opacity(configuration.isPressed ? 0.16 : (prominent && isHovered ? 0.08 : 0))))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .onHover { isHovered = $0 }
    }
}
