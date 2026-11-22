import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Quick Look preview of an archive in Finder (also rendered by the `quicklook` demo scene).
/// Spacing and radii follow DESIGN.md (4-pt grid; card 12, chip 8); Quick Look is a separate
/// process without the app's tokens, so the values are written out here.
struct ArchivePreview: View {
    let content: ArchivePreviewContent
    /// Nil hides the button (no app to hand over to).
    var openInStow: (() -> Void)?

    var body: some View {
        Group {
            switch content {
            case .listed(let model): ListedPreview(model: model, openInStow: openInStow)
            case .fallback(let fallback): FallbackPreview(fallback: fallback, openInStow: openInStow)
            }
        }
        .tint(Self.amber)
        .frame(minWidth: 360, minHeight: 260)
    }

    /// DESIGN.md › Color: the app's AccentColor, written out because the extension has no asset
    /// catalog. Amber is only ever a fill here (button, `FormatBadge`, bar), so white words on it need
    /// 4.5 : 1: light #D97B2B, dark #B85E1C, Increase Contrast #A8551C in both.
    static let amber = Color(nsColor: NSColor(name: "StowAmber") { appearance in
        amberColor(for: appearance.bestMatch(from: [
            .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
        ]))
    })

    static func amberColor(for appearance: NSAppearance.Name?) -> NSColor {
        let hex: Int = switch appearance {
        case .accessibilityHighContrastAqua?, .accessibilityHighContrastDarkAqua?: 0xA8551C
        case .darkAqua?: 0xB85E1C
        default: 0xD97B2B
        }
        return NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                       blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

private struct ListedPreview: View {
    #if DEBUG
    /// Design review: `-StowPreviewExpand "Photos|Fonts"` opens those folders.
    @State private var expanded = Set((UserDefaults.standard.string(forKey: "StowPreviewExpand") ?? "")
        .split(separator: "|").map(String.init))
    #else
    @State private var expanded: Set<String> = []
    #endif
    let model: ArchivePreviewModel
    let openInStow: (() -> Void)?

    var body: some View {
        let visible = model.visible(expanded: expanded)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                PreviewHeader(name: model.name, format: model.format, summary: model.summary,
                              isEncrypted: model.isEncrypted, openInStow: openInStow)
                if let packed = model.packedSize, model.totalSize > 0 {
                    PackedBar(packed: packed, total: model.totalSize)
                }
                if let finding = model.headline {
                    FindingLine(finding: finding, cautionCount: model.cautionCount)
                }
            }
            .padding(16)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visible.rows) { row in
                        if row.hasChildren {
                            Button {
                                if !expanded.insert(row.id).inserted { expanded.remove(row.id) }
                            } label: {
                                TreeRow(row: row, expanded: expanded.contains(row.id))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(expanded.contains(row.id) ? String(localized: "Collapse \(row.name)") : String(localized: "Expand \(row.name)"))
                        } else {
                            TreeRow(row: row, expanded: false)
                        }
                    }
                    if visible.hiddenRowCount > 0 {
                        // Names what's missing: rows past what Quick Look lists, not files left out of the archive.
                        Text("Plus \(visible.hiddenRowCount.formatted()) more not listed here. Open in Stow to see everything.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }
}

private struct PreviewHeader: View {
    let name: String
    let format: ArchiveFormat
    let summary: String
    let isEncrypted: Bool
    let openInStow: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            FormatBadge(format: format, fill: ArchivePreview.amber)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if isEncrypted {
                        Image(systemName: "lock.fill")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Encrypted")
                    }
                }
                Text("\(format.displayName) · \(summary)")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let openInStow {
                Button("Open in Stow", action: openInStow)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
    }
}

private struct PackedBar: View {
    let packed: Int64
    let total: Int64

    private var fraction: Double { min(1, max(0, Double(packed) / Double(max(total, 1)))) }

    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(.tint).frame(width: max(4, proxy.size.width * fraction))
                }
            }
            .frame(height: 4)
            Text(ArchivePreviewModel.packedSummary(packed: packed, total: total))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }
}

/// The finding that matters most, only when there is one: what it is and, under it, what it means.
/// Tinted like the app's notice card above the files; an ordinary archive shows no line at all.
private struct FindingLine: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    let finding: CheckupFinding
    let cautionCount: Int

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            glyph
                .frame(width: 14)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(finding.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if cautionCount > 1 {
                        Text("+\(cautionCount - 1) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
                if !finding.detail.isEmpty {
                    Text(finding.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(color.opacity(colorScheme == .dark ? 0.09 : 0.1), in: shape)
        .overlay {
            shape.strokeBorder(color.opacity(contrast == .increased ? 0.8 : colorScheme == .dark ? 0.18 : 0.28))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .help(finding.detail)
    }

    // Mirrors FindingGlyph in App/Browser/ArchiveInfoView.swift (not compiled into the extension).
    @ViewBuilder
    private var glyph: some View {
        switch finding.severity {
        case .caution: Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
        case .handled: Image(systemName: "shield.lefthalf.filled").foregroundStyle(color)
        case .info: Image(systemName: "info.circle.fill").foregroundStyle(color)
        case .fine: Image(systemName: "checkmark.circle").foregroundStyle(color)
        }
    }

    private var color: Color {
        switch finding.severity {
        case .fine: .secondary
        case .info: .secondary
        case .handled: .blue
        case .caution: .yellow
        }
    }
}

private struct TreeRow: View {
    let row: ArchivePreviewModel.Row
    let expanded: Bool

    var body: some View {
        HStack(spacing: 6) {
            // A disclosure column on every row, so files and folders at one depth line up whether or
            // not a folder can open. Finder's turn: right when closed, down when open, at once.
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .opacity(row.hasChildren ? 1 : 0)
                .frame(width: 10)
                .accessibilityHidden(true)
            Image(nsImage: Self.icon(for: row))
                .resizable()
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            Text(row.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            if !row.isFolder {
                Text(row.size.bytes)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.leading, 10 + CGFloat(min(row.depth, 12)) * 16)
        .padding(.trailing, 16)
        .frame(height: 22)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel([row.name, row.isFolder ? String(localized: "Folder") : (UTType(filenameExtension: (row.name as NSString).pathExtension)?.localizedDescription ?? String(localized: "File")), row.isFolder ? nil : row.size.bytes].compactMap { $0 }.joined(separator: ", "))
    }

    /// Finder's own icons; cached per type because Quick Look rows scroll fast.
    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor private static func icon(for row: ArchivePreviewModel.Row) -> NSImage {
        let ext = row.isFolder ? "/" : (row.name as NSString).pathExtension.lowercased()
        if let image = cache[ext] { return image }
        let type: UTType = row.isFolder ? .folder : UTType(filenameExtension: ext) ?? .data
        let image = NSWorkspace.shared.icon(for: type)
        cache[ext] = image
        return image
    }
}

private struct FallbackPreview: View {
    let fallback: ArchivePreviewFallback
    let openInStow: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            PreviewHeader(name: fallback.name, format: fallback.format, summary: fallback.size.bytes,
                          isEncrypted: fallback.reason == .encrypted, openInStow: openInStow)
                .padding(16)
            Divider()
            VStack(spacing: 8) {
                Image(systemName: fallback.symbol)
                    .accessibilityHidden(true)
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(.secondary)
                Text(fallback.title)
                    .font(.headline).accessibilityAddTraits(.isHeader)
                Text(fallback.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
