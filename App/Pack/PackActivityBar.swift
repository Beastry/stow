import SwiftUI

/// The pack's progress, then its result, in the same floating glass capsule as Next Steps.
struct PackActivityBar: View {
    let packing: PackController
    @Namespace private var glass

    var body: some View {
        if !packing.separate.rows.isEmpty {
            SeparatePackActivity(queue: packing.separate)
        } else if let activity = packing.activity {
            GlassEffectContainer(spacing: Space.s) {
                ActivityCapsule(phase: activity.phase,
                                title: activity.phase == .done ? activity.doneTitle : String(localized: "Packing “\(activity.name)”"),
                                note: activity.verified ? String(localized: "· contents verified") : nil,
                                noteHelp: String(localized: "Stow read back the new archive to verify its contents"),
                                glass: glass,
                                stop: activity.isSample ? nil : { packing.cancel() },
                                showInFinder: activity.placed.isEmpty ? nil : { packing.showInFinder() },
                                perform: { packing.follow($0) },
                                dismiss: { packing.dismiss() })
                .fixedSize()
                .controlSize(.large)
            }
            .padding(.horizontal, Space.l)
        }
    }
}

/// Separate packing's results (#366), in the batch panel's form: one glass panel, a headline that
/// says how the run went in words with a tally once anything stopped or failed, and a row per
/// archive with its own Stop, Try Again or Show in Finder. Collapsed, the rows that need someone
/// (failures, then the archive being packed) are never the ones hidden behind Show All.
private struct SeparatePackActivity: View {
    let queue: SeparatePackQueue
    @Environment(\.reducesMotion) private var reduceMotion
    @State private var showsAll = false
    private let visibleRows = 4
    /// Four and a half rows: the cut row says the list scrolls.
    private let expandedHeight: CGFloat = 164

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            header
            rows
            if hasFooter { footer }
        }
        .padding(Space.m)
        .frame(width: 320)
        .accessibleGlass(in: .rect(cornerRadius: Radius.panel))
        .onChange(of: queue.rows.count) { _, count in
            if count <= visibleRows { showsAll = false }
        }
    }

    // MARK: Header

    private var counts: (completed: Int, stopped: Int, failed: Int, pending: Int, progress: Double) {
        var completed = 0, stopped = 0, failed = 0, pending = 0, progress = 0.0
        for row in queue.rows {
            switch row.phase {
            case .completed: completed += 1; progress += 1
            case .cancelled: stopped += 1; progress += 1
            case .failed: failed += 1; progress += 1
            case .waiting: pending += 1
            case .running(let fraction): pending += 1; progress += fraction
            }
        }
        return (completed, stopped, failed, pending, progress / Double(max(queue.rows.count, 1)))
    }

    private var header: some View {
        let counts = counts
        return HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            ActivityGlyph(glyph(counts))
                // The glyph sits on the headline, not between it and the tally.
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 2) {
                Text(headline(counts))
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .liveNumber()
                let tally = tally(counts)
                if !tally.isEmpty {
                    HStack(spacing: Space.m) {
                        ForEach(tally, id: \.symbol) { outcome in
                            Label {
                                Text(outcome.words).liveNumber()
                            } icon: {
                                Image(systemName: outcome.symbol).foregroundStyle(outcome.color)
                            }
                            .labelStyle(TallyLabelStyle())
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(([headline(counts)] + tally(counts).map(\.words)).joined(separator: ", "))
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Space.s)
            if queue.isActive {
                Button("Stop All") { queue.cancelAll() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Stop unfinished archives. Archives already packed are kept.")
            }
        }
    }

    private func glyph(_ counts: (completed: Int, stopped: Int, failed: Int, pending: Int, progress: Double)) -> ActivityGlyph.State {
        if counts.pending > 0 { return .running(counts.progress) }
        if counts.failed > 0 { return .failed }
        if counts.stopped > 0 { return .stopped }
        return .done
    }

    /// The outcome that matters most, in words; a stopped run never reads as done.
    private func headline(_ counts: (completed: Int, stopped: Int, failed: Int, pending: Int, progress: Double)) -> String {
        let total = queue.rows.count
        if counts.pending > 0 {
            return String(localized: "Packing \(total - counts.pending + 1) of \(total) archives")
        }
        if counts.failed > 0 { return String(localized: "\(counts.failed) archives need attention") }
        if counts.stopped > 0 {
            return counts.completed == 0 ? String(localized: "Packing stopped")
                : String(localized: "Stopped before all were packed")
        }
        return total == 1 ? String(localized: "1 archive packed") : String(localized: "\(total) archives packed")
    }

    private struct Outcome {
        let symbol: String
        let color: Color
        let words: String
    }

    /// Every outcome with a count, once anything stopped or failed. All-success runs don't need it.
    private func tally(_ counts: (completed: Int, stopped: Int, failed: Int, pending: Int, progress: Double)) -> [Outcome] {
        guard counts.stopped + counts.failed > 0 else { return [] }
        var outcomes: [Outcome] = []
        if counts.completed > 0 {
            outcomes.append(Outcome(symbol: "checkmark.circle.fill", color: .green,
                                    words: String(localized: "\(counts.completed) packed")))
        }
        if counts.stopped > 0 {
            outcomes.append(Outcome(symbol: "minus.circle", color: .secondary,
                                    words: String(localized: "\(counts.stopped) stopped")))
        }
        if counts.failed > 0 {
            outcomes.append(Outcome(symbol: CheckupFinding.Severity.caution.symbol,
                                    color: CheckupFinding.Severity.caution.color,
                                    words: String(localized: "\(counts.failed) failed")))
        }
        return outcomes
    }

    // MARK: Rows

    @ViewBuilder private var rows: some View {
        if showsAll {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s) {
                    ForEach(queue.rows) { row in SeparatePackRow(row: row, queue: queue) }
                }
            }
            .frame(maxHeight: expandedHeight)
            .fixedSize(horizontal: false, vertical: true)
            .scrollBounceBehavior(.basedOnSize)
            .scrollEdgeEffectStyle(.soft, for: .vertical)
            .transition(.opacity)
        } else {
            ForEach(collapsedRows) { row in SeparatePackRow(row: row, queue: queue) }
        }
    }

    private var collapsedRows: [SeparatePackQueue.Row] {
        let rows = queue.rows
        guard rows.count > visibleRows else { return rows }
        func rank(_ row: SeparatePackQueue.Row) -> Int {
            switch row.phase {
            case .failed: 0
            case .running: 1
            default: 2
            }
        }
        return rows.indices
            .sorted { (rank(rows[$0]), $0) < (rank(rows[$1]), $1) }
            .prefix(visibleRows)
            .sorted()
            .map { rows[$0] }
    }

    // MARK: Footer

    private var canExpand: Bool { queue.rows.count > visibleRows }
    private var hasFooter: Bool { canExpand || !queue.isActive }

    /// Show All on the leading side; Done quietly on the trailing side once nothing is left to
    /// run. Results stay until someone is done with them.
    private var footer: some View {
        HStack(spacing: Space.s) {
            if canExpand {
                let title = showsAll ? String(localized: "Show Fewer Results")
                    : String(localized: "Show All \(queue.rows.count) Results")
                Button {
                    // Growing the list is movement: none under Reduce Motion or from the keyboard.
                    withAnimation(reduceMotion || Motion.byKeyboard ? nil : Motion.appear) { showsAll.toggle() }
                } label: {
                    Label(title, systemImage: "chevron.down")
                        .labelStyle(DisclosureLabelStyle(isExpanded: showsAll))
                }
                .foregroundStyle(.accentText)
                .accessibilityLabel(title)
            }
            Spacer(minLength: Space.s)
            if !queue.isActive {
                Button("Done") { queue.dismiss() }
                    .foregroundStyle(.secondary)
                    .help("Close these results. Packed archives are kept.")
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .font(.callout)
        .padding(.top, Space.xs)
    }
}

/// One archive of a separate pack: the batch panel's row, with Stop, Try Again or Show in Finder.
private struct SeparatePackRow: View {
    let row: SeparatePackQueue.Row
    let queue: SeparatePackQueue

    var body: some View {
        HStack(spacing: Space.s) {
            ActivityGlyph(glyph)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .liveNumber()
            }
            .help(pointerHelp)
            Spacer(minLength: 0)
            switch row.phase {
            case .waiting, .running:
                Button("Stop", systemImage: "xmark") { queue.cancel(row.id) }
                    .accessibilityLabel(String(localized: "Cancel “\(row.name)”"))
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Stop packing “\(row.name)”")
            case .failed, .cancelled:
                Button("Try Again", systemImage: "arrow.clockwise") { queue.retry(row.id) }
                    .accessibilityLabel(String(localized: "Try packing “\(row.name)” again"))
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Try Again")
            case .completed where !row.placed.isEmpty:
                Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting(row.placed) }
                    .accessibilityLabel(String(localized: "Show “\(row.name)” in Finder"))
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
            default:
                EmptyView()
            }
        }
        // #93: one leaf label from pure strings, as BatchRow; each row's controls stay reachable
        // by name through its actions.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
        .accessibilityValue(progressValue)
        .accessibilityActions {
            switch row.phase {
            case .waiting, .running:
                Button(String(localized: "Cancel “\(row.name)”")) { queue.cancel(row.id) }
            case .failed(let failure):
                Button(String(localized: "Try packing “\(row.name)” again")) { queue.retry(row.id) }
                Button("Copy Details") { ErrorReport.Copyable(failure).copy() }
            case .cancelled:
                Button(String(localized: "Try packing “\(row.name)” again")) { queue.retry(row.id) }
            case .completed where !row.placed.isEmpty:
                Button(String(localized: "Show “\(row.name)” in Finder")) { NSWorkspace.shared.activateFileViewerSelecting(row.placed) }
            default:
                EmptyView()
            }
        }
        .contextMenu {
            if case .failed(let failure) = row.phase {
                Button("Copy Error Details (\(failure.code.description))") { ErrorReport.Copyable(failure).copy() }
            }
            if !row.placed.isEmpty {
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(row.placed.map(\.path).joined(separator: "\n"), forType: .string)
                }
            }
        }
    }

    private var spokenLabel: String {
        switch row.phase {
        case .failed(let failure):
            AccessibilityText.activity(title: row.name, note: AccessibilityText.failure(failure))
        case .running:
            row.name
        default:
            AccessibilityText.activity(title: row.name, note: detail)
        }
    }

    private var progressValue: String {
        if case .running(let progress) = row.phase { AccessibilityText.progress(progress) } else { "" }
    }

    private var glyph: ActivityGlyph.State {
        switch row.phase {
        case .waiting: .waiting
        case .running(let progress): .running(progress)
        case .completed: .done
        case .failed: .failed
        case .cancelled: .stopped
        }
    }

    /// The whole explanation or the real paths, for the pointer.
    private var pointerHelp: String {
        switch row.phase {
        case .failed(let failure): failure.title + ". " + failure.advice
        case .completed: row.placed.map(\.path).joined(separator: "\n")
        default: ""
        }
    }

    private var detail: String {
        switch row.phase {
        case .waiting: return String(localized: "Waiting")
        // Before anything is measured the ring turns; no "0%" claims a start.
        case .running(let progress):
            return progress > 0 ? progress.formatted(.percent.precision(.fractionLength(0))) : String(localized: "Preparing…")
        case .completed:
            guard let first = row.placed.first else { return String(localized: "Packed") }
            let folder = FileManager.default.displayName(atPath: first.deletingLastPathComponent().path)
            let saved = row.placed.count > 1 ? String(localized: "\(row.placed.count) parts in \(folder)")
                                             : String(localized: "Saved in \(folder)")
            return row.verified ? String(localized: "\(saved) · verified") : saved
        case .failed(let failure): return failure.brief
        case .cancelled: return String(localized: "Stopped")
        }
    }
}
