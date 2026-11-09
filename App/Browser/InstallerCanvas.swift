import AppKit
import ImageIO
import SwiftUI

// MARK: - Model

/// A disk image's own window, ready to draw (#344): the author's background, the apps' own icons
/// and where everything was placed. Read once per opened image; tied to that archive, so a stale
/// canvas never shows over another one.
struct InstallerCanvas {
    let archiveID: Archive.ID
    let layout: InstallerLayout
    let background: NSImage?
    /// The background's size in points: its pixels over its scale (`bg@2x.png` is drawn at half).
    let backgroundSize: CGSize?
    /// Each app's declared icon (`CFBundleIconFile`), by entry path.
    let icons: [String: NSImage]
    /// Item names whose label sits on dark artwork, so their names are drawn light.
    let darkUnderLabel: Set<String>

    var backgroundColor: Color? {
        guard case .color(let red, let green, let blue) = layout.background else { return nil }
        return Color(red: red, green: green, blue: blue)
    }

    /// Whether names drawn straight on the canvas read better light. A picture says per item; a
    /// colour, by its brightness; Finder's plain window is light.
    func labelIsLight(_ name: String) -> Bool {
        if background != nil { return darkUnderLabel.contains(name) }
        if case .color(let red, let green, let blue) = layout.background {
            return 0.2126 * red + 0.7152 * green + 0.0722 * blue < 0.5
        }
        return false
    }
}

/// How a window gets its disk image's layout: read it now, already read while the window said it
/// was opening (nil: the image has none), or still being read when the window had to show.
enum InstallerCanvasStart {
    case load
    case ready(InstallerCanvas?)
    case pending(Task<InstallerCanvas?, Never>)

    /// Stops a read nobody will show.
    func cancel() {
        if case .pending(let task) = self { task.cancel() }
    }
}

/// Resumes once, with whichever finishes first: the read or the wait.
private final class FirstFinish {
    private var continuation: CheckedContinuation<Bool, Never>?
    var timer: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }

    func finish(_ value: Bool) {
        timer?.cancel()
        timer = nil
        continuation?.resume(returning: value)
        continuation = nil
    }
}

/// Reads an image's layout out of the archive, bounded at every step: only listed files, only
/// sizes the listing vouched for, a few engine trips, decoded images capped. Any failure means
/// no canvas and the volume browses as before.
enum InstallerCanvasLoader {
    static let maxBackgroundBytes: Int64 = 32 << 20
    nonisolated static let maxBackgroundPixels = 8_192
    nonisolated static let maxBackgroundArea = 40_000_000
    static let maxApps = 8
    /// How long an opening window waits for the layout before showing the files without it.
    static let openingWait = Duration.seconds(5)

    /// Whether the archive may have a layout to read: a disk image with a `.DS_Store` or
    /// `.background` at its volume's top.
    static func wantsCanvas(_ archive: Archive) -> Bool {
        archive.isDiskImage && archive.source != nil && !archive.presentationFiles.isEmpty
    }

    /// Reads the layout while the window still says it's opening, as ArcZip does: the image
    /// appears as its author's window, with its apps' own icons, rather than as plain files that
    /// turn into it a moment later. A read slower than `limit` is handed over still running, and
    /// the files show meanwhile.
    static func prepare(_ archive: Archive, password: String?, limit: Duration = openingWait) async -> InstallerCanvasStart {
        guard wantsCanvas(archive) else { return .ready(nil) }
        let task = Task { await load(archive, password: password) }
        let finished = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let race = FirstFinish(continuation)
                race.timer = Task {
                    try? await Task.sleep(for: limit)
                    race.finish(false)
                }
                Task {
                    _ = await task.value
                    race.finish(true)
                }
            }
        } onCancel: {
            task.cancel()
        }
        return finished ? .ready(await task.value) : .pending(task)
    }

    static func load(_ archive: Archive, password: String?) async -> InstallerCanvas? {
        guard archive.isDiskImage, let source = archive.source else { return nil }
        let root = archive.volumeRoot
        let prefix = root.isEmpty ? "" : root + "/"
        let storePath = prefix + ".DS_Store"
        guard let storeSize = archive.presentationFiles[storePath], storeSize <= InstallerLayout.maxStoreBytes else { return nil }

        // First trip: the store, and each app's Info.plist for its icon's name.
        let apps = archive.children(of: root).filter { ArchivedAppIcon.applies(to: $0) }.prefix(maxApps)
        var first = [storePath: Int64(InstallerLayout.maxStoreBytes)]
        for app in apps {
            let plist = ArchivedAppIcon.plistPath(app: app.path)
            if let entry = archive.entry(at: plist), !entry.isFolder, entry.size <= ArchivedAppIcon.maxPlistBytes {
                first[plist] = ArchivedAppIcon.maxPlistBytes
            }
        }
        guard let firstFiles = try? await ArchiveFileReader.read(first, from: archive, source: source, password: password),
              !Task.isCancelled,
              let store = firstFiles[storePath], let layout = InstallerLayout.read(store) else { return nil }

        // Second trip: the background picture and the apps' icons.
        var second: [String: Int64] = [:]
        var backgroundPath: String?
        if case .picture(let candidates) = layout.background {
            backgroundPath = candidates.lazy.compactMap { InstallerLayout.archivePath($0, volumeRoot: root) }
                .first { path in
                    let size = archive.presentationFiles[path] ?? archive.entry(at: path).flatMap { $0.isFolder ? nil : $0.size }
                    return size.map { $0 <= maxBackgroundBytes } ?? false
                }
            if let backgroundPath { second[backgroundPath] = maxBackgroundBytes }
        }
        var iconPaths: [String: String] = [:]
        for app in apps {
            let plist = firstFiles[ArchivedAppIcon.plistPath(app: app.path)]
            guard let path = ArchivedAppIcon.iconFile(app: app.path, plist: plist, in: archive) else { continue }
            iconPaths[app.path] = path
            second[path] = ArchivedAppIcon.maxIconBytes
        }
        let secondFiles = second.isEmpty ? [:] : ((try? await ArchiveFileReader.read(second, from: archive, source: source, password: password)) ?? [:])
        guard !Task.isCancelled else { return nil }

        var background: (image: NSImage, size: CGSize, dark: Set<String>)?
        if let backgroundPath, let data = secondFiles[backgroundPath] {
            let name = (backgroundPath as NSString).lastPathComponent
            background = await decodeBackground(data, name: name, layout: layout)
        }
        var icons: [String: NSImage] = [:]
        for (app, path) in iconPaths {
            if let data = secondFiles[path], let image = await ArchivedAppIcon.decode(data) { icons[app] = image }
        }
        guard !Task.isCancelled else { return nil }
        return InstallerCanvas(archiveID: archive.id, layout: layout, background: background?.image,
                               backgroundSize: background?.size, icons: icons, darkUnderLabel: background?.dark ?? [])
    }

    /// Decodes the picture off the main thread, capped in pixels, and works out its size in
    /// points and which names sit on dark parts of it.
    @concurrent
    nonisolated static func decodeBackground(_ data: Data, name: String,
                                             layout: InstallerLayout) async -> (image: NSImage, size: CGSize, dark: Set<String>)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        // A multi-resolution TIFF holds 1x and 2x: draw the largest at the smallest's size.
        var reps: [(image: CGImage, width: Int, height: Int)] = []
        for index in 0..<min(CGImageSourceGetCount(source), 4) {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= maxBackgroundPixels, height <= maxBackgroundPixels,
                  width * height <= maxBackgroundArea,
                  let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            reps.append((image, width, height))
        }
        guard let largest = reps.max(by: { $0.width < $1.width }),
              let smallest = reps.min(by: { $0.width < $1.width }) else { return nil }
        let scale: CGFloat
        if reps.count > 1 {
            scale = CGFloat(largest.width) / CGFloat(smallest.width)
        } else {
            scale = backgroundScale(name: name, pixelWidth: largest.width, source: source, window: layout.windowSize)
        }
        let size = CGSize(width: (CGFloat(largest.width) / scale).rounded(), height: (CGFloat(largest.height) / scale).rounded())
        let image = NSImage(cgImage: largest.image, size: size)
        let dark = darkNames(in: largest.image, size: size, layout: layout)
        return (image, size, dark)
    }

    /// `name@2x.png` is twice its points; so is a picture saved at 144 dpi. Without either, a
    /// picture about twice the window's width is a Retina one.
    nonisolated static func backgroundScale(name: String, pixelWidth: Int, source: CGImageSource?, window: CGSize?) -> CGFloat {
        let base = (name as NSString).deletingPathExtension
        for factor in [3, 2] where base.hasSuffix("@\(factor)x") { return CGFloat(factor) }
        if let source, let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let dpi = properties[kCGImagePropertyDPIWidth] as? Double, dpi >= 143 { return (dpi / 72).rounded() }
        if let window, window.width > 0, CGFloat(pixelWidth) >= window.width * 1.8 { return 2 }
        return 1
    }

    nonisolated static func labelGap(iconSize: CGFloat) -> CGFloat { (iconSize * 0.07 + 2).rounded() }

    /// Samples the picture under each placed name (a few pixels per point is plenty).
    nonisolated private static func darkNames(in image: CGImage, size: CGSize, layout: InstallerLayout) -> Set<String> {
        let width = max(1, Int(size.width / 4)), height = max(1, Int(size.height / 4))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return [] }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var dark = Set<String>()
        for (name, center) in layout.positions {
            // The rows the name's letters cover, under the icon. A bitmap context's memory runs top down.
            let text = center.y + layout.iconSize / 2 + labelGap(iconSize: layout.iconSize)
            let top = (text + layout.textSize * 0.2) / 4
            let bottom = (text + layout.textSize * 1.1) / 4
            let left = (center.x - layout.textSize * 2.5) / 4, right = (center.x + layout.textSize * 2.5) / 4
            var total = 0.0, count = 0.0
            for y in Int(top)...max(Int(top), Int(bottom)) where (0..<height).contains(y) {
                let row = y
                for x in Int(left)...max(Int(left), Int(right)) where (0..<width).contains(x) {
                    let pixel = pixels + (row * width + x) * 4
                    total += 0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[2])
                    count += 1
                }
            }
            if count > 0, total / count < 128 { dark.insert(name) }
        }
        return dark
    }
}

// MARK: - View

/// The volume as its author laid it out (#344): their artwork, the apps' own icons where they put
/// them, and the "drag here" shortcut as a place to drop. Dropping an app there, or choosing
/// Install App, runs the same install with the same checks; nothing installs or opens by
/// selecting, pointing or starting a drag. Items the author didn't place sit under the artwork.
/// The artwork scales as one with its icons, never stretched, down to half size; past that the
/// files scroll.
struct InstallerCanvasView: View {
    @Bindable var model: BrowserModel
    let canvas: InstallerCanvas
    var isSearchFocused: Binding<Bool>
    @FocusState private var isFocused: Bool
    @Environment(\.reducesMotion) private var reduceMotion

    private static let minimumScale: CGFloat = 0.5

    var body: some View {
        // The window dressing is the canvas itself; the shortcut is its drop target.
        let entries = model.visibleEntries.filter { !$0.isHelper }
        let positions = canvas.layout.positions
        let placed = entries.filter { positions[$0.name] != nil }
        let targets = model.archive.dropTargets.filter {
            ($0.path as NSString).deletingLastPathComponent == model.archive.volumeRoot && positions[$0.name] != nil
        }
        let others = entries.filter { positions[$0.name] == nil }
        let size = canvas.layout.canvasSize(background: canvas.backgroundSize,
                                            placed: placed.map(\.name) + targets.map(\.name))
        GeometryReader { proxy in
            let room = CGSize(width: proxy.size.width - Space.xl * 2,
                              height: proxy.size.height - Space.xl * 2 - (others.isEmpty ? 0 : 150))
            let scale = max(Self.minimumScale, min(1, room.width / size.width, room.height / size.height))
            let scaled = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
            ScrollView(scaled.width > proxy.size.width - Space.xl * 2 ? [.horizontal, .vertical] : .vertical) {
                VStack(alignment: .leading, spacing: Space.xl) {
                    artwork(size: scaled, scale: scale, placed: placed, targets: targets)
                    if !others.isEmpty {
                        OtherItems(model: model, entries: others, icons: canvas.icons, isFocused: $isFocused)
                            .frame(width: max(scaled.width, 320), alignment: .leading)
                    }
                }
                .padding(Space.xl)
                .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
                .background {
                    Color.clear.contentShape(.rect).onTapGesture {
                        isFocused = true
                        model.select([])
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear {
            if !isSearchFocused.wrappedValue { isFocused = true }
            // Up and Down step one item at a time: the author's places aren't rows.
            model.gridColumns = 1
        }
        .filesTakeKeyboard($isFocused, isSearchFocused: isSearchFocused)
        .browserKeys(model)
    }

    private func artwork(size: CGSize, scale: CGFloat, placed: [ArchiveEntry],
                         targets: [DiskImageLayout.DropTarget]) -> some View {
        ZStack(alignment: .topLeading) {
            backdrop
                .frame(width: size.width, height: size.height)
                .contentShape(.rect)
                .onTapGesture {
                    isFocused = true
                    model.select([])
                }
                .accessibilityHidden(true)
            ForEach(targets, id: \.path) { target in
                if let center = canvas.layout.positions[target.name] {
                    CanvasTarget(model: model, target: target, iconSize: canvas.layout.iconSize * scale,
                                 textSize: canvas.layout.textSize * scale, labelIsLight: canvas.labelIsLight(target.name))
                        .position(itemCenter(center, scale: scale))
                }
            }
            ForEach(placed) { entry in
                if let center = canvas.layout.positions[entry.name] {
                    CanvasItem(model: model, entry: entry, icon: canvas.icons[entry.path],
                               iconSize: canvas.layout.iconSize * scale, textSize: canvas.layout.textSize * scale,
                               isSelected: model.selection.contains(entry.id), labelIsLight: canvas.labelIsLight(entry.name),
                               isFocused: $isFocused)
                        .position(itemCenter(center, scale: scale))
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(.rect(cornerRadius: Radius.panel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
                .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Installer window"))
    }

    @ViewBuilder
    private var backdrop: some View {
        if let image = canvas.background {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
        } else if let color = canvas.backgroundColor {
            color
        } else {
            Color.white
        }
    }

    /// Where an item's view goes so its icon's centre lands on the author's point: the view is the
    /// icon with its name below.
    private func itemCenter(_ point: CGPoint, scale: CGFloat) -> CGPoint {
        let item = CanvasItemMetrics(iconSize: canvas.layout.iconSize * scale, textSize: canvas.layout.textSize * scale)
        return CGPoint(x: point.x * scale, y: point.y * scale - item.iconSize / 2 + item.height / 2)
    }
}

/// An icon and its name, sized from the author's icon and text sizes.
private struct CanvasItemMetrics {
    let iconSize: CGFloat
    let textSize: CGFloat
    /// Finder leaves about this much between an icon and its name; authors draw name plates to match.
    var gap: CGFloat { InstallerCanvasLoader.labelGap(iconSize: iconSize) }
    var labelHeight: CGFloat { (textSize * 1.3).rounded(.up) * 2 + 4 }
    var width: CGFloat { max(iconSize + 24, textSize * 10) }
    var height: CGFloat { iconSize + gap + labelHeight }
}

/// One of the archive's items where the author put it. It selects, opens and drags like a tile in
/// the grid; dragging it onto an install destination installs it.
private struct CanvasItem: View {
    let model: BrowserModel
    let entry: ArchiveEntry
    let icon: NSImage?
    let iconSize: CGFloat
    let textSize: CGFloat
    let isSelected: Bool
    let labelIsLight: Bool
    var isFocused: FocusState<Bool>.Binding
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let metrics = CanvasItemMetrics(iconSize: iconSize, textSize: textSize)
        VStack(spacing: metrics.gap) {
            picture
                .frame(width: iconSize, height: iconSize)
                .padding(iconSize * 0.04)
                .background(selectionTint.opacity(isSelected ? 1 : 0), in: .rect(cornerRadius: max(4, iconSize * 0.12), style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: max(4, iconSize * 0.12), style: .continuous)
                        .strokeBorder(.primary.opacity(ContrastStyle.resolve(contrast).increased && isSelected ? 0.5 : 0))
                }
                .padding(-iconSize * 0.04)
                .accessibilityHidden(true)
            CanvasLabel(text: entry.kind == .app ? Installer.displayName(entry.name) : entry.name,
                        textSize: textSize, isSelected: isSelected, isLight: labelIsLight)
                .frame(width: metrics.width, height: metrics.labelHeight, alignment: .top)
        }
        .frame(width: metrics.width, height: metrics.height)
        .contentShape(.rect)
        .onTapGesture(count: 2) { model.open(entry) }
        .simultaneousGesture(TapGesture().onEnded {
            isFocused.wrappedValue = true
            model.click(entry, modifiers: NSEvent.modifierFlags)
        })
        // A press here that moves starts the usual drag out (to Finder, another archive, or an
        // install destination on this canvas).
        .onHover { inside in
            if inside {
                model.dragOut.hovered = entry.id
            } else if model.dragOut.hovered == entry.id {
                model.dragOut.hovered = nil
            }
        }
        .contextMenu { EntryMenu(model: model, entry: entry) }
        .help(entry.kind == .app && !model.archive.dropTargets.isEmpty
              ? String(localized: "Drag to Applications to install, or choose Install App")
              : entry.name)
        .archiveEntryAccessibility(entry: entry) {
            model.select([entry.id])
            model.open(entry)
        }
    }

    @ViewBuilder
    private var picture: some View {
        if let icon {
            Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
        } else if ArchivedAppIcon.applies(to: entry) {
            ArchivedAppIconView(entry: entry, model: model)
        } else {
            LiveThumbnail(entry: entry, model: model, side: max(64, iconSize * 2))
        }
    }

    /// Finder's square behind a selected icon: a mid grey shows on light and dark art alike.
    private var selectionTint: Color { Color(white: 0.5, opacity: 0.35) }
}

/// A "drag here" shortcut (Applications) drawn as the place it stands for: the real folder's icon,
/// lit while an app from this canvas is held over it. It never installs by itself.
private struct CanvasTarget: View {
    let model: BrowserModel
    let target: DiskImageLayout.DropTarget
    let iconSize: CGFloat
    let textSize: CGFloat
    let labelIsLight: Bool
    @State private var isTargeted = false
    @Environment(\.reducesMotion) private var reduceMotion

    var body: some View {
        let metrics = CanvasItemMetrics(iconSize: iconSize, textSize: textSize)
        VStack(spacing: metrics.gap) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: target.folder))
                .resizable()
                .interpolation(.high)
                .frame(width: iconSize, height: iconSize)
                .scaleEffect(isTargeted && !reduceMotion ? 1.08 : 1)
                .background {
                    RoundedRectangle(cornerRadius: max(6, iconSize * 0.16), style: .continuous)
                        .fill(Color.accentColor.opacity(isTargeted ? 0.22 : 0))
                        .strokeBorder(Color.accentColor.opacity(isTargeted ? 0.9 : 0), lineWidth: 2)
                        .padding(-iconSize * 0.08)
                }
            CanvasLabel(text: target.name, textSize: textSize, isSelected: isTargeted, isLight: labelIsLight)
                .frame(width: metrics.width, height: metrics.labelHeight, alignment: .top)
        }
        .frame(width: metrics.width, height: metrics.height)
        .animation(Motion.resolved(Motion.target, reduceMotion: reduceMotion), value: isTargeted)
        .contentShape(.rect)
        .onDrop(of: [ArchiveTransfer.contentType, .fileURL],
                delegate: InstallTargetDrop(model: model, target: target, isTargeted: $isTargeted))
        .help(String(localized: "Install destination: \(target.folder)"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: target.name))
        .accessibilityValue(Text("Install destination: \(target.folder)"))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text("Choose Install App, or drag the app here"))
    }
}

/// A name under an icon, as Finder draws it on a laid-out window: on the artwork, in a tinted
/// capsule when selected.
private struct CanvasLabel: View {
    let text: String
    let textSize: CGFloat
    let isSelected: Bool
    let isLight: Bool

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: textSize))
            .lineLimit(2)
            .truncationMode(.middle)
            .multilineTextAlignment(.center)
            .foregroundStyle(isSelected ? .white : (isLight ? .white : .black))
            .shadow(color: isSelected || !isLight ? .clear : .black.opacity(0.45), radius: 1, y: 0.5)
            .padding(.horizontal, textSize * 0.4)
            .padding(.vertical, 1)
            .background(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear),
                        in: .rect(cornerRadius: textSize * 0.4, style: .continuous))
    }
}

/// Takes only this canvas's own app (or plug-in) dragged onto its destination, and hands it to the
/// install that Install App runs. Files from elsewhere, several items, or a stale drag are refused.
private struct InstallTargetDrop: DropDelegate {
    let model: BrowserModel
    let target: DiskImageLayout.DropTarget
    @Binding var isTargeted: Bool

    func validateDrop(info: DropInfo) -> Bool {
        DragActivity.touch()
        return ArchiveTransfer.activeEntries(from: model).flatMap { model.installStep(for: $0, onto: target) } != nil
    }
    func dropEntered(info: DropInfo) { isTargeted = true }
    func dropExited(info: DropInfo) {
        DragActivity.touch()
        isTargeted = false
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DragActivity.touch()
        return DropProposal(operation: .copy)
    }
    func performDrop(info: DropInfo) -> Bool {
        DragActivity.touch()
        isTargeted = false
        guard let transfer = ArchiveTransfer.takeNativeDrop(), transfer.source === model, transfer.sourceIsCurrent,
              let step = model.installStep(for: transfer.entries, onto: target) else { return false }
        model.run(step, on: transfer.entries)
        return true
    }
}

/// What the author didn't place, under the artwork: still there to select, open, drag and install.
private struct OtherItems: View {
    let model: BrowserModel
    let entries: [ArchiveEntry]
    let icons: [String: NSImage]
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Other Items")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            FlowLayout(spacing: Space.s, lineSpacing: Space.s) {
                ForEach(entries) { entry in
                    OtherItem(model: model, entry: entry, icon: icons[entry.path],
                              isSelected: model.selection.contains(entry.id), isFocused: isFocused)
                }
            }
        }
        .padding(Space.m)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: Radius.card, style: .continuous))
    }
}

private struct OtherItem: View {
    let model: BrowserModel
    let entry: ArchiveEntry
    let icon: NSImage?
    let isSelected: Bool
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: Space.s) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                } else {
                    LiveThumbnail(entry: entry, model: model, side: 64)
                }
            }
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)
            Text(verbatim: entry.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180, alignment: .leading)
        }
        .padding(.horizontal, Space.s)
        .padding(.vertical, Space.xs)
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .background(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), in: .rect(cornerRadius: Radius.chip, style: .continuous))
        .contentShape(.rect)
        .onTapGesture(count: 2) { model.open(entry) }
        .simultaneousGesture(TapGesture().onEnded {
            isFocused.wrappedValue = true
            model.click(entry, modifiers: NSEvent.modifierFlags)
        })
        .onHover { inside in
            if inside {
                model.dragOut.hovered = entry.id
            } else if model.dragOut.hovered == entry.id {
                model.dragOut.hovered = nil
            }
        }
        .contextMenu { EntryMenu(model: model, entry: entry) }
        .archiveEntryAccessibility(entry: entry) {
            model.select([entry.id])
            model.open(entry)
        }
    }
}
