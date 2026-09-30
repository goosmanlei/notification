import AppKit
import SwiftUI
import NotificationCore

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class OverlayController {
    private static let preferredWidth: CGFloat = 880
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
                   sessionID: "$1", windowID: "@1", paneID: "%1", sessionName: "dev", windowName: "notification", paneIndex: 2))
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
    }
    private var active: [Active] = []
    private var waiting: [Notice] = []
    private var panels: [NSPanel] = []
    private var timer: Timer?
    var paused = false { didSet { if paused { clear() }; render() } }
    var locked = false { didSet { if locked { clear() }; render() } }
    var duration: TimeInterval = 10
    var hideBody = false { didSet { render() } }
    var onChange: (() -> Void)?
    private(set) var dropped = 0
    var pendingCount: Int { active.count + waiting.count }

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.tick() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                              object: nil, queue: .main) { [weak self] _ in self?.render() }
    }

    func show(_ notice: Notice) {
        guard !paused, !locked else { return }
        guard !active.contains(where: { $0.notice.id == notice.id }), !waiting.contains(where: { $0.id == notice.id }) else { return }
        if waiting.count >= 100 {
            if let index = waiting.firstIndex(where: { !$0.requiresAction }) { waiting.remove(at: index) }
            else { waiting.removeFirst() }
            dropped += 1
        }
        if notice.requiresAction { waiting.insert(notice, at: 0) } else { waiting.append(notice) }
        fill(); render(); onChange?()
    }

    func resolve(id: String) {
        active.removeAll { $0.notice.id == id }; waiting.removeAll { $0.id == id }
        fill(); render(); onChange?()
    }

    func clear(session: String? = nil) {
        if let session {
            active.removeAll { $0.notice.sessionID == session }; waiting.removeAll { $0.sessionID == session }
        } else { active = []; waiting = [] }
        fill(); render(); onChange?()
    }

    private func fill() {
        // Leave room for ordinary notifications when several human-input requests remain open.
        while active.count < 3, !waiting.isEmpty {
            let persistent = active.filter { $0.notice.requiresAction }.count
            let index = persistent >= 2 ? waiting.firstIndex(where: { !$0.requiresAction }) : waiting.startIndex
            guard let index else { break }
            let notice = waiting.remove(at: index)
            active.append(Active(notice: notice, deadline: notice.requiresAction ? nil : Date().addingTimeInterval(duration)))
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
            panel.contentView = NSHostingView(rootView: VStack(spacing: Self.cardSpacing) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, notice in
                    NoticeCard(notice: notice, hideBody: hidden, dismiss: { dismiss(notice.id) })
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
    @ViewState private var isOpeningTmux = false
    @ViewState private var isOpeningOriginal = false
    @ViewState private var navigationError: String?
    private var accent: Color { notice.requiresAction ? Color(red: 0.98, green: 0.70, blue: 0.26) : Color(red: 0.36, green: 0.86, blue: 0.78) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: notice.requiresAction ? "hand.raised.fill" : "bell.badge.fill").foregroundStyle(accent)
                Text(!hideBody ? notice.context ?? notice.source : notice.source)
                    .lineLimit(1).truncationMode(.middle).font(.system(size: notice.context == nil || hideBody ? 12 : 17, weight: .semibold))
                if notice.context != nil && !hideBody {
                    Text(notice.source).lineLimit(1).foregroundStyle(.white.opacity(0.55)).font(.system(size: 11))
                }
                if let tmux = notice.tmux, !hideBody {
                    Label(tmux.label, systemImage: "terminal")
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1).truncationMode(.middle).layoutPriority(1)
                }
                Spacer(minLength: 4)
                if notice.requiresAction {
                    Text(notice.title).font(.system(size: 12, weight: .medium)).foregroundStyle(accent)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(accent.opacity(0.13), in: Capsule()).fixedSize()
                }
                actions.fixedSize()
                Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).padding(4) }
                    .buttonStyle(.plain).help("在所有屏幕关闭此提醒")
                    .accessibilityLabel("关闭提醒")
            }
            if !notice.requiresAction {
                Text(hideBody ? "收到一条新提醒" : notice.title).font(.system(size: 19, weight: .bold)).lineLimit(1)
            }
            if let error = navigationError {
                Text(error).font(.system(size: 11)).foregroundStyle(accent).lineLimit(1).help(error)
            } else if hideBody || !notice.body.isEmpty {
                Text(hideBody ? "内容已隐藏" : notice.body).font(.system(size: notice.requiresAction ? 15 : 13))
                    .foregroundStyle(.white.opacity(0.85)).lineLimit(notice.requiresAction ? 5 : 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .topLeading)
        .foregroundStyle(.white)
        .background(Color(red: 0.045, green: 0.09, blue: 0.12).opacity(0.97), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(accent.opacity(0.7), lineWidth: 1.2))
        .overlay(alignment: .leading) { Capsule().fill(accent).frame(width: 3, height: 44).padding(.leading, 1) }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            if let tmux = notice.tmux {
                Button {
                    isOpeningTmux = true; navigationError = nil
                    TmuxNavigator.open(tmux) { error in isOpeningTmux = false; navigationError = error }
                } label: {
                    Label(isOpeningTmux ? "定位中…" : "打开 tmux", systemImage: "arrow.up.right.square")
                }.disabled(isOpeningTmux)
            }
            if notice.tmux == nil || navigationError != nil {
                if let session = notice.sessionID, UUID(uuidString: session) != nil {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("codex resume \(session)", forType: .string)
                    } label: { Label("复制恢复命令", systemImage: "doc.on.doc") }
                } else if let bundle = notice.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                    if notice.notificationIdentifier != nil {
                        Button {
                            isOpeningOriginal = true; navigationError = nil
                            SystemNotificationOpener.open(notice) { error in
                                isOpeningOriginal = false; navigationError = error
                                if error == nil { dismiss() }
                            }
                        } label: { Label(isOpeningOriginal ? "定位中…" : "打开原通知", systemImage: "arrow.up.right.square") }
                        .disabled(isOpeningOriginal)
                    }
                    if notice.notificationIdentifier == nil || navigationError != nil {
                        Button { NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, _ in }; dismiss() }
                        label: { Label("打开应用", systemImage: "app") }
                    }
                }
            }
        }
        .buttonStyle(NoticeActionStyle()).font(.system(size: 12, weight: .semibold))
    }
}

private struct NoticeActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color(red: 0.17, green: 0.31, blue: 0.44).opacity(configuration.isPressed ? 0.65 : 1),
                        in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.28), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}
