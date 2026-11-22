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

/// Shows per-input work and gives keyboard-accessible controls for each result.
private struct SeparatePackActivity: View {
    let queue: SeparatePackQueue

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Separate Archives").accessibilityAddTraits(.isHeader)
                Spacer()
                if queue.isRunning {
                    Button("Cancel All") { queue.cancelAll() }
                } else {
                    Button("Done") { queue.dismiss() }
                }
            }
            ScrollView {
                VStack(alignment: .leading) {
                    ForEach(queue.rows) { row in
                        VStack(alignment: .leading) {
                            Text(row.name).textSelection(.enabled)
                            status(row)
                        }
                        Divider()
                    }
                }
            }
            .frame(height: min(240, CGFloat(queue.rows.count) * 72))
        }
        .padding()
        .frame(width: 390)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
    }

    @ViewBuilder
    private func status(_ row: SeparatePackQueue.Row) -> some View {
        switch row.phase {
        case .waiting:
            HStack {
                Text("Waiting")
                Spacer()
                cancel(row)
            }
        case .running(let progress):
            HStack {
                ProgressView(value: progress) { Text("Packing") }
                Spacer()
                cancel(row)
            }
        case .completed:
            VStack(alignment: .leading) {
                HStack {
                    Text(row.verified ? String(localized: "Completed and verified") : String(localized: "Completed"))
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(row.placed) }
                        .accessibilityLabel(Text("Show “\(row.name)” in Finder"))
                }
                ForEach(row.placed, id: \.self) { url in
                    Text(url.path).font(.caption).textSelection(.enabled)
                }
            }
        case .failed(let failure):
            HStack {
                Text(failure.title)
                Spacer()
                retry(row)
            }
        case .cancelled:
            HStack {
                Text("Cancelled")
                Spacer()
                retry(row)
            }
        }
    }

    private func cancel(_ row: SeparatePackQueue.Row) -> some View {
        Button("Cancel") { queue.cancel(row.id) }
            .accessibilityLabel(Text("Cancel “\(row.name)”"))
    }

    private func retry(_ row: SeparatePackQueue.Row) -> some View {
        Button("Try Again") { queue.retry(row.id) }
            .accessibilityLabel(Text("Try packing “\(row.name)” again"))
    }
}
