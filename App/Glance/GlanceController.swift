import AppKit
import SwiftUI

/// Where Glance opens: centred on the pointer with the pointer in its header, so it seems to grow
/// out of what was clicked — then pulled back inside the screen's visible area (menu bar and Dock
/// excluded) so no edge or corner is ever off screen.
nonisolated enum GlancePlacement {
    static let defaultSize = CGSize(width: 440, height: 500)
    static let minimumSize = CGSize(width: 400, height: 320)
    /// Kept clear between Glance and the edge of the visible area.
    static let margin: CGFloat = 8
    /// How far above the pointer the window's top edge sits: the pointer lands in the header.
    static let pointerInset: CGFloat = 24

    /// The window frame in screen coordinates (AppKit: origin bottom-left, y up).
    static func frame(size: CGSize, pointer: CGPoint, visible: CGRect) -> CGRect {
        let room = visible.insetBy(dx: margin, dy: margin)
        let width = min(size.width, room.width)
        let height = min(size.height, room.height)
        let x = clamp(pointer.x - width / 2, room.minX, room.maxX - width)
        let y = clamp(pointer.y + pointerInset - height, room.minY, room.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// How far a Glance opens from another that already stands where it would: enough for the
    /// one behind to keep its header's edge in view.
    static let cascadeStep: CGFloat = 28

    /// `frame` moved down and to the right until its top-left corner is clear of every frame in
    /// `others`, still inside the visible area. Several archives opened at once (one pointer, one
    /// spot) would otherwise stand exactly on top of each other and read as a single window.
    static func cascaded(_ frame: CGRect, clearOf others: [CGRect], visible: CGRect) -> CGRect {
        let room = visible.insetBy(dx: margin, dy: margin)
        var result = frame
        for _ in others {
            let taken = others.contains {
                abs($0.minX - result.minX) < cascadeStep / 2 && abs($0.maxY - result.maxY) < cascadeStep / 2
            }
            guard taken else { break }
            var next = result
            next.origin.x = clamp(result.minX + cascadeStep, room.minX, room.maxX - result.width)
            next.origin.y = clamp(result.minY - cascadeStep, room.minY, room.maxY - result.height)
            // In the screen's bottom-right corner there's nowhere further to step.
            guard next != result else { break }
            result = next
        }
        return result
    }

    /// The size Glance was last given by hand (`NSStringFromSize`), never under the minimum;
    /// the default when there's none yet.
    static func size(saved: String?) -> CGSize {
        guard let saved else { return defaultSize }
        let size = NSSizeFromString(saved)
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return defaultSize }
        return CGSize(width: max(size.width.rounded(), minimumSize.width), height: max(size.height.rounded(), minimumSize.height))
    }

    /// The pointer as a point in the window's own top-left space, kept inside it — where the
    /// opening scale is anchored.
    static func anchor(pointer: CGPoint, in frame: CGRect) -> UnitPoint {
        guard frame.width > 0, frame.height > 0 else { return .center }
        return UnitPoint(x: clamp((pointer.x - frame.minX) / frame.width, 0, 1),
                         y: clamp((frame.maxY - pointer.y) / frame.height, 0, 1))
    }

    /// Edges and corners of the visible area, for `-StowGlanceEdge` and the placement tests.
    enum Edge: String, CaseIterable, Sendable {
        case center, top, bottom, left, right, topLeft, topRight, bottomLeft, bottomRight

        /// A pointer resting on this edge of `visible`.
        func pointer(in visible: CGRect) -> CGPoint {
            let left = visible.minX + 1, right = visible.maxX - 1
            let bottom = visible.minY + 1, top = visible.maxY - 1
            return switch self {
            case .center: CGPoint(x: visible.midX, y: visible.midY)
            case .top: CGPoint(x: visible.midX, y: top)
            case .bottom: CGPoint(x: visible.midX, y: bottom)
            case .left: CGPoint(x: left, y: visible.midY)
            case .right: CGPoint(x: right, y: visible.midY)
            case .topLeft: CGPoint(x: left, y: top)
            case .topRight: CGPoint(x: right, y: top)
            case .bottomLeft: CGPoint(x: left, y: bottom)
            case .bottomRight: CGPoint(x: right, y: bottom)
            }
        }
    }

    private static func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        min(max(value, low), max(low, high))
    }
}

/// Glass, or a solid window background when Reduce Transparency is on.
nonisolated enum GlanceMaterial: Equatable, Sendable {
    /// System Liquid Glass (`glassEffect`).
    case glass
    /// Classic frosted material (`.regularMaterial`) when Liquid Glass is turned off (#158).
    case frosted
    /// Opaque window background; always used under Reduce Transparency.
    case solid

    static func resolve(
        reduceTransparency: Bool,
        preference: SettingsKeys.GlanceMaterialPreference = .liquidGlass,
        override: Bool = UserDefaults.standard.bool(forKey: "StowReduceTransparency")
    ) -> Self {
        if reduceTransparency || override { return .solid }
        return preference == .classic ? .frosted : .glass
    }
}

/// Glance: the compact window for a quick browse and extract. It shows the same `BrowserModel`
/// as the full window — switching between them moves the window, not the state, so folder,
/// selection and history come along. Only one of the two shows the browser at a time.
@Observable
final class GlanceController: NSObject, NSWindowDelegate {
    weak var app: AppState?
    private(set) var isShown = false
    /// Keep Glance above other apps' windows.
    var isPinned = SettingsKeys.flag(SettingsKeys.glancePinned) {
        didSet {
            UserDefaults.standard.set(isPinned, forKey: SettingsKeys.glancePinned)
            window?.level = isPinned ? .floating : .normal
        }
    }
    /// The archive being opened into Glance (from Finder or Quick Look) until it's listed.
    var pendingName: String?
    /// Bumped on every animated appearance; the view springs its content in from `anchor`.
    private(set) var appearance = 0
    private(set) var anchor = UnitPoint.center

    /// Closes the full window. A seam for tests; Glance and the full window never both show the browser.
    @ObservationIgnored var closeMainWindow: () -> Void = {}
    /// Brings the full window back (AppState's `showMainWindow` unless a test swaps it).
    @ObservationIgnored var openMainWindow: (() -> Void)?
    /// Tests keep Glance off screen; the state still changes the same way.
    @ObservationIgnored var presentsWindow = true

    @ObservationIgnored private(set) var window: NSWindow?

    /// The browser Glance shows — always the app's own, never a copy.
    var model: BrowserModel? { app?.browser }

    /// Whether the full window has been on screen yet. SwiftUI puts it up once at launch, after
    /// a Finder open may already have gone to Glance.
    @ObservationIgnored private var sawMainWindow = false

    override init() {
        super.init()
        closeMainWindow = { [weak self] in self?.ownedMainWindows.forEach { $0.close() } }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let window = (note.object as? NSWindow).map(WindowBox.init)
                MainActor.assumeIsolated { if let window = window?.window { self?.mainWindowAppeared(window) } }
            }
        }
    }

    /// The full window came up while Glance was showing the browser. At launch that's SwiftUI's
    /// own presentation, so it goes; later it's someone choosing the full window, so Glance goes.
    private func mainWindowAppeared(_ window: NSWindow) {
        guard window.isVisible, ownedMainWindows.contains(window) else { return }
        defer { sawMainWindow = true }
        if mainWindowAnimation != .default {
            // It's up; whatever opens it next (the Dock, the Window menu) gets the usual opening.
            mainWindowAnimation = .default
            window.animationBehavior = .default
        }
        guard isShown, presentsWindow else { return }
        guard !sawMainWindow else { return close() }
        // SwiftUI is still presenting it and ignores a close until that's done: hide it now, close it after.
        window.orderOut(nil)
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            window.close()
        }
    }

    // MARK: - Switching

    /// Full window → Glance, near the pointer. Clicking animates; the keyboard shortcut doesn't.
    func collapse(near pointer: CGPoint = NSEvent.mouseLocation, animated: Bool = !GlanceController.isKeyboardEvent) {
        guard let model else { return }
        // Columns shows a selected folder in the preceding column while `folder` names its
        // contents. Glance has one list: show that folder in its parent so the highlighted row
        // and selection actions still refer to the same item (#160). This is a presentation
        // transfer, not a history step; preserve the selection and the Browser's view preference.
        if let selected = selectedColumnFolder, selected.path == model.folder {
            model.folder = selected.parent
            model.select([selected.id], scroll: true)
        }
        app?.rememberArchiveWindow(.glance)
        // Transfer ownership before the full window emits willCloseNotification.
        isShown = true
        closeMainWindow()
        show(near: pointer, animated: animated)
    }

    /// Glance → full window, same browser. By keyboard the full window appears without AppKit's
    /// window zoom (DESIGN.md › Motion); a click keeps the system's usual opening.
    func expand(byKeyboard: Bool = Motion.byKeyboard) {
        guard isShown else { return }
        // A folder selected in Glance belongs in its parent column, with its contents to the
        // right. Resolve the current selection, never a saved one: browsing, edits or archive
        // changes in Glance must not resurrect the folder from before the transfer.
        if let model, let selected = selectedColumnFolder, selected.parent == model.folder {
            model.columnSelect(selected)
        }
        app?.rememberArchiveWindow(.browser)
        close()
        mainWindowAnimation = byKeyboard ? .none : .default
        // A full window SwiftUI kept around is ordered in again; a new one gets it in `prepareMainWindow`.
        for window in ownedMainWindows { window.animationBehavior = mainWindowAnimation }
        (openMainWindow ?? app?.showMainWindow)?()
    }

    private var selectedColumnFolder: ArchiveEntry? {
        guard let model, model.viewMode == .columns, !model.isSearching,
              model.selection.count == 1, let id = model.selection.first,
              let entry = model.archive.entry(at: id), entry.isNavigable else { return nil }
        return entry
    }

    /// How the next full window comes up; `expand` sets it, and it's back to the default once one has.
    @ObservationIgnored private var mainWindowAnimation = NSWindow.AnimationBehavior.default

    /// The browser hands over its window as soon as it exists, before SwiftUI puts it on screen.
    func prepareMainWindow(_ window: NSWindow) {
        guard ownedMainWindows.contains(window) else { return }
        window.animationBehavior = mainWindowAnimation
    }

    /// Opens an archive from Finder or Quick Look straight into Glance: the window appears at the
    /// pointer right away and says what it's opening; the archive fills it once listed.
    func open(_ url: URL) {
        guard let app else { return }
        pendingName = url.lastPathComponent
        isShown = true
        closeMainWindow()
        show(near: NSEvent.mouseLocation, animated: true)
        app.open(url)
    }

    // MARK: - Window

    func show(near pointer: CGPoint, size: CGSize? = nil, animated: Bool) {
        let visible = Self.screen(containing: pointer).visibleFrame
        var frame = GlancePlacement.frame(size: size ?? window?.frame.size ?? Self.rememberedSize,
                                          pointer: pointer, visible: visible)
        // Another archive's Glance already stands there (several opened at once): step aside.
        frame = GlancePlacement.cascaded(frame, clearOf: otherGlanceFrames, visible: visible)
        anchor = GlancePlacement.anchor(pointer: pointer, in: frame)
        isShown = true
        guard presentsWindow else { return }
        let window = window ?? makeWindow()
        self.window = window
        window.level = isPinned ? .floating : .normal
        window.setFrame(frame, display: false)
        let reduceMotion = DisplayPreferences.reducesMotionNow
        if animated {
            appearance += 1
            window.alphaValue = 0
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                // The glass arrives with the content's spring (DESIGN.md › Motion: response 0.32, damping 1).
                context.duration = reduceMotion ? 0.15 : 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 1
            }
        } else {
            window.alphaValue = 1
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
        // Each time it shows, so they stay hidden whatever the window went through since.
        updateWindowControls()
    }

    /// Brings Glance forward where it stands. Only opening it (a click, Finder, the switch from
    /// the full window) puts it at the pointer; asking for a Glance that's already on screen (the
    /// same archive opened again, Open Stow in the Tray's menu, a question before quitting) must
    /// not move the window from where it was left.
    func bringForward() {
        guard isShown else { return }
        guard presentsWindow, let window, window.isVisible || window.isMiniaturized || NSApp.isHidden else {
            return show(near: NSEvent.mouseLocation, animated: false)
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Where the other archives' Glance windows stand, for `GlancePlacement.cascaded`.
    private var otherGlanceFrames: [CGRect] {
        guard let app else { return [] }
        return app.archiveSessions.compactMap { session in
            guard session !== app, let other = session.glance.window, other.isVisible else { return nil }
            return other.frame
        }
    }

    // MARK: - Remembered size

    /// Glance's size is window state, as the Browser's frame is (`NSWindow Frame Browser`), not a
    /// preference: it isn't in Settings and no reset touches it.
    static let sizeKey = "GlanceWindowSize"

    /// Design snapshots and tests always get the default size, whatever this Mac's Glance was left at.
    private static var remembersSize: Bool {
        UserDefaults.standard.string(forKey: "StowScene") == nil && NSClassFromString("XCTestCase") == nil
    }

    private static var rememberedSize: CGSize {
        remembersSize ? GlancePlacement.size(saved: UserDefaults.standard.string(forKey: sizeKey)) : GlancePlacement.defaultSize
    }

    /// Resized by hand: the next Glance (another archive's, or after a relaunch) opens at this size.
    func windowDidEndLiveResize(_ notification: Notification) {
        guard Self.remembersSize, let window, notification.object as? NSWindow === window else { return }
        UserDefaults.standard.set(NSStringFromSize(window.frame.size), forKey: Self.sizeKey)
    }

    /// Glance is borderless (#159): its own Close, Pin on Top and Open in Full Window are along the
    /// bottom, so the traffic lights never show. The window stays titled for ⌘W, ⌘M, resizing,
    /// its shadow and corners, and its title in the Window menu.
    func updateWindowControls() {
        if let window { updateWindowControls(of: window) }
    }

    private func updateWindowControls(of window: NSWindow) {
        for button: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
    }

    /// Hides Glance without ending the archive session, including a transfer back to Browser.
    func close() {
        guard isShown else { return }
        // orderOut retains the hosted view, so its onDisappear is not a close notification.
        // Only the visible Glance owns this question; a hidden Glance must not cancel a sheet.
        if let prompt = app?.passwords, let question = prompt.question {
            prompt.answer(nil, to: question.id)
        }
        isShown = false
        pendingName = nil
        if model?.quickLook.isActive == true { model?.quickLook.close() }
        window?.orderOut(nil)
    }

    /// Close while the archive is still opening: the opening stops too, so it doesn't finish in a
    /// window nobody can see. A cloud download waits on its own cancel, so that stops as well.
    func stopOpening() {
        guard isShown else { return }
        if pendingName != nil, let app, app.isOpening {
            app.cancelCloudDownload()
            app.cancelOpening()
        }
        close()
    }

    func windowWillClose(_ notification: Notification) {
        // The close button or ⌘W.
        close()
    }

    private func makeWindow() -> NSWindow {
        let size = Self.rememberedSize
        let window = GlanceWindow(contentRect: CGRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: true)
        window.identifier = NSUserInterfaceItemIdentifier(app?.workspaceOwner == nil ? Self.windowIdentifier : "glance-" + (app?.sessionID.uuidString ?? UUID().uuidString))
        window.isReleasedWhenClosed = false
        // No title bar to see: the header inside the window names the archive and moves it.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentMinSize = GlancePlacement.minimumSize
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        window.tabbingMode = .disallowed
        // Glance has its own entrance (springing out of the pointer) and none by keyboard; AppKit's
        // window zoom would play on top of both. Closing is instant.
        window.animationBehavior = .none
        window.delegate = self
        let host = NSHostingController(rootView: GlanceRoot(glance: self).environment(app ?? AppState()))
        // SwiftUI's title becomes the window's own (Window menu, Mission Control); there's no toolbar.
        host.sceneBridgingOptions = [.title]
        host.sizingOptions = []
        window.contentViewController = host
        window.setContentSize(size)
        updateWindowControls(of: window)
        return window
    }

    var ownedMainWindows: [NSWindow] {
        guard let app else { return [] }
        if let window = app.archiveWindow { return [window] }
        return app.workspaceOwner == nil ? Self.mainWindows : []
    }

    static let windowIdentifier = "glance"

    /// The full window (SwiftUI's `Window(id: "main")`), however many times it was reopened, and the
    /// welcome window that stands in for it while no archive is open.
    static var mainWindows: [NSWindow] {
        NSApp.windows.filter { window in
            let id = window.identifier?.rawValue ?? ""
            return ["main", "welcome"].contains { id == $0 || id.hasPrefix($0 + "-") }
        }
    }

    static var isKeyboardEvent: Bool { NSApp.currentEvent?.type == .keyDown }

    private static func screen(containing point: CGPoint) -> NSScreen {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}

private final class GlanceWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct WindowBox: @unchecked Sendable {
    let window: NSWindow
}
