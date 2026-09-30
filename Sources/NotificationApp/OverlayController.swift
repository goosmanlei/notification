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
            Notice(source: "Notification", title: "每一块屏幕，都能看见", body: "新通知同步显示在各屏幕上方，继续专注于手头的工作。"),
            Notice(source: "Codex CLI", title: "需要你的回答", body: "这次构建要使用哪一个目标环境？请回到终端选择。", kind: .input, context: "notification")
        ]
        let padding: CGFloat = 24
        let width = preferredWidth - horizontalInset * 2 + padding * 2
        let height = CGFloat(notices.count) * cardHeight + CGFloat(notices.count - 1) * cardSpacing + padding * 2
        let view = NSHostingView(rootView: VStack(spacing: cardSpacing) {
            ForEach(notices) { notice in NoticeCard(notice: notice, hideBody: false, dismiss: {}).frame(height: cardHeight) }
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
            let height = CGFloat(active.count) * (Self.cardHeight + Self.cardSpacing) + (waiting.isEmpty ? 0 : Self.queueHeight)
            let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.title = "Notification · \(screen.localizedName)"
            panel.level = .statusBar; panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.isReleasedWhenClosed = false
            let visible = active.map(\.notice)
            let hidden = hideBody
            let count = waiting.count
            let dismiss: (String) -> Void = { [weak self] id in self?.resolve(id: id) }
            panel.contentView = NSHostingView(rootView: VStack(spacing: Self.cardSpacing) {
                ForEach(visible) { notice in
                    NoticeCard(notice: notice, hideBody: hidden, dismiss: { dismiss(notice.id) })
                        .frame(height: Self.cardHeight)
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

private struct NoticeCard: View {
    let notice: Notice
    let hideBody: Bool
    let dismiss: () -> Void
    private var accent: Color { notice.requiresAction ? Color(red: 0.98, green: 0.70, blue: 0.26) : Color(red: 0.36, green: 0.86, blue: 0.78) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: notice.requiresAction ? "hand.raised.fill" : "bell.badge.fill").foregroundStyle(accent)
                Text(notice.source).lineLimit(1).font(.system(size: 12, weight: .semibold))
                if let context = notice.context { Text("· \(context)").lineLimit(1).foregroundStyle(.white.opacity(0.6)).font(.system(size: 11)) }
                Spacer(minLength: 4)
                Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).padding(4) }
                    .buttonStyle(.plain).help("在所有屏幕关闭此提醒")
                    .accessibilityLabel("关闭提醒")
            }
            Text(hideBody ? "收到一条新提醒" : notice.title).font(.system(size: 19, weight: .bold)).lineLimit(1)
            Text(hideBody ? "内容已隐藏" : notice.body).font(.system(size: 13)).foregroundStyle(.white.opacity(0.85))
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Text(notice.requiresAction ? "请回到 Codex 终端处理" : "同步通知")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                Spacer()
                if let session = notice.sessionID, UUID(uuidString: session) != nil {
                    Button("复制恢复命令") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("codex resume \(session)", forType: .string)
                    }.buttonStyle(.plain).foregroundStyle(accent).font(.system(size: 11, weight: .semibold))
                } else if let bundle = notice.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                    Button("打开应用") { NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, _ in }; dismiss() }
                        .buttonStyle(.plain).foregroundStyle(accent).font(.system(size: 11, weight: .semibold))
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.white)
        .background(Color(red: 0.045, green: 0.09, blue: 0.12).opacity(0.97), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(accent.opacity(0.7), lineWidth: 1.2))
        .overlay(alignment: .leading) { Capsule().fill(accent).frame(width: 3, height: 44).padding(.leading, 1) }
    }
}
