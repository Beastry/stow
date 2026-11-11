import AppKit
import SwiftUI

extension AppState {
    var workspace: AppState { workspaceOwner ?? self }
    var archiveSessions: [AppState] { [workspace] + workspace.additionalSessions }

    /// Reading focus state makes command menus refresh when another archive becomes key.
    var commandSession: AppState {
        let root = workspace
        let _ = root.focusedSessionID
        return root.session(owning: NSApp.keyWindow) ?? root
    }

    func session(owning window: NSWindow?) -> AppState? {
        guard let window else { return nil }
        let owner = window.sheetParent ?? window
        return archiveSessions.first {
            owner === $0.archiveWindow || owner === $0.glance.window
                || owner === $0.browser?.editingWindow
        }
    }

    /// Resolve identity before starting asynchronous loading, so a multi-file open cannot
    /// replace an in-flight session or create competing editors for one source.
    func sessionForOpening(_ url: URL) -> AppState {
        let root = workspace
        let key = RecentArchives.key(for: url)
        if let existing = root.archiveSessions.first(where: {
            let source = $0.browser?.levels.first?.edits.url ?? $0.openingURL
            return source.map { RecentArchives.key(for: $0) == key } ?? false
        }) { return existing }
        if !root.usesBrowserWindow && !root.glance.isShown { return root }
        let session = AppState(workspaceOwner: root)
        session.presentationDefaults = root.presentationDefaults
        session.presentsArchiveWindows = root.presentsArchiveWindows
        session.glance.presentsWindow = root.glance.presentsWindow && root.presentsArchiveWindows
        session.showMainWindow = { [weak session] in
            guard let session, session.presentsArchiveWindows else { return }
            if session.archiveWindowController == nil {
                session.archiveWindowController = ArchiveWindowController(session: session)
            }
            session.archiveWindowController?.present()
        }
        root.additionalSessions.append(session)
        return session
    }

    func presentArchive() {
        workspace.lastArchiveSessionID = sessionID
        if glance.isShown { glance.bringForward() }
        else { showMainWindow() }
    }

    func openInBrowser(_ url: URL) {
        let destination = workspace.sessionForOpening(url)
        if destination.isOpening || destination.browser != nil || destination.openFailure != nil {
            destination.presentArchive()
        } else {
            destination.open(url)
            destination.showMainWindow()
        }
    }

    func presentMostRecentArchive() {
        let root = workspace
        let target = root.archiveSessions.first {
            $0.sessionID == root.lastArchiveSessionID && ($0.usesBrowserWindow || $0.glance.isShown)
        }
        (target ?? root).presentArchive()
    }
}

/// Where another archive's Browser window opens beside the one in front.
nonisolated enum ArchiveWindowPlacement {
    static let defaultSize = CGSize(width: 1120, height: 700)
    /// Clear of the window in front's title bar edge, so both can be told apart and reached.
    static let step: CGFloat = 28

    /// The front Browser's size, a step down and to the right of it. A step that would leave the
    /// visible area starts again from that side's near edge, as the system's own cascade does,
    /// so the window is never cut off by the screen or the Dock.
    static func frame(after front: CGRect, visible: CGRect) -> CGRect {
        let width = min(front.width, visible.width), height = min(front.height, visible.height)
        var x = front.minX + step
        if x + width > visible.maxX || x < visible.minX { x = visible.minX }
        var top = front.maxY - step
        if top - height < visible.minY || top > visible.maxY { top = visible.maxY }
        return CGRect(x: x, y: top - height, width: width, height: height)
    }
}

/// Secondary Browser windows reuse the existing workspace and native toolbar. Their close,
/// password and edit state belongs to their session, never to the app-wide Welcome scene.
final class ArchiveWindowController: NSWindowController {
    init(session: AppState) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: ArchiveWindowPlacement.defaultSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("archive-" + session.sessionID.uuidString)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.toolbarStyle = .unified
        let host = NSHostingController(rootView: RootView().environment(session))
        host.sceneBridgingOptions = [.title, .toolbars]
        host.sizingOptions = [.minSize]
        window.contentViewController = host
        window.setContentSize(ArchiveWindowPlacement.defaultSize)
        super.init(window: window)
        Self.place(window, among: session.workspace.archiveSessions.compactMap(\.archiveWindow))
        session.archiveWindow = window
    }

    /// Another archive's window opens as the Browser people already have: the size of the front
    /// Browser window and a step down and to the right of it, or, with none on screen, where the
    /// Browser was last left. Never placed from whichever window happens to be key (Settings,
    /// Welcome and Glance are not Browsers), and never at a size of its own.
    private static func place(_ window: NSWindow, among browsers: [NSWindow]) {
        let front = NSApp.orderedWindows.first { candidate in
            candidate !== window && candidate.isVisible && !candidate.isMiniaturized
                && !candidate.styleMask.contains(.fullScreen) && browsers.contains { $0 === candidate }
        }
        if let front, let visible = (front.screen ?? NSScreen.main)?.visibleFrame {
            window.setFrame(ArchiveWindowPlacement.frame(after: front.frame, visible: visible), display: false)
        } else if !window.setFrameUsingName(RootView.frameName) {
            window.center()
        }
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        guard let window, let id = window.identifier?.rawValue else { return }
        ApplicationLifecycle.shared.presentWindow(id) { window.makeKeyAndOrderFront(nil) }
    }
}
