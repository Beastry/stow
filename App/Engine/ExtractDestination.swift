import AppKit

/// Asks where to extract. The folder people pick is the only place Stow (and its engine, via a
/// staging folder next to it) may write.
enum ExtractDestination {
    static func choose(for archive: Archive) async -> URL? {
        // Design review and verification runs pick the folder up front (`-StowExtractFolder <path>`).
        if let path = UserDefaults.standard.string(forKey: "StowExtractFolder") { return URL(filePath: path, directoryHint: .isDirectory) }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Extract")
        panel.message = String(localized: "Choose where to extract “\(archive.name)”.")
        panel.directoryURL = archive.source.flatMap { OtherAppFiles.startFolder(near: $0.url) }
        let response = if let window = NSApp.keyWindow {
            await panel.beginSheetModal(for: window)
        } else {
            panel.runModal()
        }
        return response == .OK ? panel.url : nil
    }

    /// Where a batch goes, and whether its results are collected in a new folder there (#326).
    struct BatchChoice: Equatable {
        var folder: URL
        var collects: Bool
    }

    /// One folder for several archives, with "Collect them in a new folder" below the browser.
    /// `sheet` false: a standalone panel (Finder's Extract to…, where no Stow window is in front).
    static func chooseBatch(count: Int, near first: URL?, sheet: Bool = true) async -> BatchChoice? {
        let defaults = UserDefaults.standard
        // Verification runs pick both up front (`-StowExtractFolder <path> -StowCollectInFolder YES`).
        if let path = defaults.string(forKey: "StowExtractFolder") {
            return BatchChoice(folder: URL(filePath: path, directoryHint: .isDirectory),
                               collects: count > 1 && defaults.bool(forKey: "StowCollectInFolder"))
        }
        let panel = batchPanel(count: count, near: first)
        let collect = count > 1 ? CollectOption(remembered: defaults.bool(forKey: ResultFolder.rememberKey)) : nil
        if let collect {
            panel.accessoryView = collect.view
            panel.isAccessoryViewDisclosed = true
        }
        let response = if sheet, let window = NSApp.keyWindow {
            await panel.beginSheetModal(for: window)
        } else {
            panel.runModal()
        }
        guard response == .OK, let folder = panel.url else { return nil }
        if let collect { defaults.set(collect.isOn, forKey: ResultFolder.rememberKey) }
        return BatchChoice(folder: folder, collects: collect?.isOn ?? false)
    }

    /// The checkbox, and under it what it makes, in the panel's small secondary text.
    @MainActor
    final class CollectOption {
        let view: NSView
        private let checkbox: NSButton
        var isOn: Bool { checkbox.state == .on }

        init(remembered: Bool) {
            checkbox = NSButton(checkboxWithTitle: String(localized: "Collect them in a new folder"), target: nil, action: nil)
            checkbox.state = remembered ? .on : .off
            let note = NSTextField(wrappingLabelWithString: String(localized: "A new “\(ResultFolder.defaultName)” folder is made in the folder you choose. Each archive still gets its own folder inside it."))
            note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            note.textColor = .secondaryLabelColor
            note.preferredMaxLayoutWidth = 400
            let stack = NSStackView(views: [checkbox, note])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 2
            stack.translatesAutoresizingMaskIntoConstraints = false
            note.translatesAutoresizingMaskIntoConstraints = false
            // Margins of its own: the panel places an accessory edge to edge.
            let container = NSView()
            container.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
                stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
                stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
                // The note lines up with the checkbox's title, not its box.
                note.leadingAnchor.constraint(equalTo: checkbox.leadingAnchor, constant: 20),
                note.widthAnchor.constraint(equalToConstant: 400),
            ])
            view = container
        }
    }

    private static func batchPanel(count: Int, near first: URL?) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Extract")
        panel.message = String(localized: "Choose where to extract \(count == 1 ? String(localized: "the archive") : String(localized: "\(count) archives")). Each gets its own folder.")
        panel.directoryURL = first.flatMap(OtherAppFiles.startFolder(near:))
        return panel
    }

    /// One folder for a batch of archives.
    static func choose(count: Int, near first: URL?) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Extract")
        panel.message = String(localized: "Choose where to extract \(count == 1 ? String(localized: "the archive") : String(localized: "\(count) archives")). Each gets its own folder.")
        panel.directoryURL = first.flatMap(OtherAppFiles.startFolder(near:))
        let response = if let window = NSApp.keyWindow {
            await panel.beginSheetModal(for: window)
        } else {
            panel.runModal()
        }
        return response == .OK ? panel.url : nil
    }
}
