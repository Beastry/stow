import SwiftUI

/// Number of Parts (#322): the editor beside Custom…, opened from the same places and built the
/// same way as `SplitSizeEditor`, so the two read as one pair. Nothing changes until Use.
struct PartCountEditor: View {
    /// The count in use, if any; otherwise the field starts empty.
    let initial: Int?
    /// What a valid count would mean for the items being packed ("About 12 MB each"), when known.
    var outcome: ((Int) -> String)?
    let apply: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var isFocused: Bool

    private var range: ClosedRange<Int> { SplitArchive.partCountRange }

    /// Full-width digits (an input method in full-width mode) read as their ASCII twins.
    private var parsed: Int? {
        let folded = text.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespaces)
        guard !folded.isEmpty, folded.allSatisfy(\.isASCII), let count = Int(folded), range.contains(count) else { return nil }
        return count
    }

    private var stepped: Binding<Int> {
        Binding(get: { parsed ?? initial ?? 2 }, set: { text = String($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("Number of Parts")
                .font(.headline)
            HStack(spacing: Space.s) {
                TextField("Parts", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 72)
                    .focused($isFocused)
                    .onSubmit(use)
                Stepper("Parts", value: stepped, in: range)
                    .labelsHidden()
                Text("parts")
                    .foregroundStyle(.secondary)
            }
            // One line that always says something, so the popover never changes height as people type.
            status
                .font(.callout)
                .lineLimit(2, reservesSpace: true)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.s) {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Use") { use() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(parsed == nil)
            }
        }
        .padding(Space.l)
        .frame(width: 280)
        .font(.body)
        .controlSize(.regular)
        .onAppear {
            text = initial.map(String.init) ?? ""
            isFocused = true
        }
    }

    @ViewBuilder
    private var status: some View {
        if let parsed {
            Text(outcome?(parsed) ?? String(localized: "Parts are cut once the archive is made, nearly equal in size."))
                .foregroundStyle(.secondary)
                .liveNumber()
        } else if text.trimmingCharacters(in: .whitespaces).isEmpty {
            Text("Parts are cut once the archive is made, nearly equal in size.")
                .foregroundStyle(.secondary)
        } else {
            Label {
                Text("Enter a whole number from \(range.lowerBound) to \(range.upperBound).")
            } icon: {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            }
        }
    }

    private func use() {
        guard let parsed else { return }
        apply(parsed)
        dismiss()
    }
}
