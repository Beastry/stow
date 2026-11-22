import Foundation
import Observation

/// A serial queue shares the same resource budget as a single pack. Failed and cancelled rows
/// retain their in-memory job snapshots until they are retried or the results are dismissed.
@Observable
final class SeparatePackQueue {
    enum Phase: Equatable {
        case waiting, running(Double), completed, failed(Failure), cancelled
    }

    struct Row: Identifiable {
        let id = UUID()
        let name: String
        var phase: Phase = .waiting
        var placed: [URL] = []
        var verified = false
    }

    private(set) var rows: [Row] = []
    private var jobs: [UUID: PackController.Job] = [:]
    private var worker: Task<Void, Never>?
    private var current: Task<ArchiveCreation.Result, any Error>?
    private var cleanupDirectory: URL?
    private var cleanupOnlyOnSuccess = false
    private var cleaned: ((URL) -> Void)?
    private var completion: ((Result<[URL], Error>) -> Void)?

    var isRunning: Bool { worker != nil }
    /// Something is still waiting or packing: what the results panel offers Stop All for.
    var isActive: Bool {
        isRunning || rows.contains {
            switch $0.phase {
            case .waiting, .running: true
            default: false
            }
        }
    }

    /// Design review only: shows rows without packing anything.
    func preview(_ planned: [(name: String, phase: Phase, verified: Bool)]) {
        guard !isRunning else { return }
        let folder = URL(filePath: "/Users/Shared/Downloads", directoryHint: .isDirectory)
        rows = planned.map { name, phase, verified in
            var row = Row(name: name, phase: phase)
            if phase == .completed { row.placed = [folder.appending(path: name)]; row.verified = verified }
            return row
        }
    }

    func start(_ planned: [PackController.Job], cleanupDirectory: URL?, cleanupOnlyOnSuccess: Bool,
               cleaned: @escaping (URL) -> Void, completion: @escaping (Result<[URL], Error>) -> Void) {
        guard !planned.isEmpty, !isRunning else { return }
        dismiss()
        self.cleanupDirectory = cleanupDirectory
        self.cleanupOnlyOnSuccess = cleanupOnlyOnSuccess
        self.cleaned = cleaned
        self.completion = completion
        rows = planned.map { Row(name: $0.name + "." + $0.request.format.fileExtension) }
        jobs = Dictionary(uniqueKeysWithValues: zip(rows.map(\.id), planned))
        run()
    }

    func retry(_ id: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == id }), jobs[id] != nil else { return }
        switch rows[index].phase {
        case .cancelled, .failed:
            rows[index].phase = .waiting
            run()
        default: break
        }
    }

    func cancel(_ id: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        switch rows[index].phase {
        case .waiting: rows[index].phase = .cancelled
        case .running: current?.cancel()
        default: break
        }
    }

    func cancelAll() {
        for index in rows.indices where rows[index].phase == .waiting { rows[index].phase = .cancelled }
        current?.cancel()
    }

    func dismiss() {
        guard !isRunning else { return }
        jobs.removeAll()
        rows.removeAll()
        if !cleanupOnlyOnSuccess { removeCleanupDirectory() }
        cleanupDirectory = nil
        cleaned = nil
        let finish = completion
        completion = nil
        finish?(.failure(EngineError(.cancelled)))
    }

    func protects(_ folder: URL) -> Bool {
        let root = folder.resolvingSymlinksInPath().standardizedFileURL.path
        return jobs.values.contains { job in
            job.items.contains {
                let path = $0.source.standardizedFileURL.path
                return path == root || path.hasPrefix(root + "/")
            }
        }
    }

    private func run() {
        guard worker == nil else { return }
        worker = Task {
            while let index = rows.firstIndex(where: { $0.phase == .waiting }) {
                let id = rows[index].id
                guard var job = jobs[id] else {
                    rows[index].phase = .cancelled
                    continue
                }
                job.request.operationID = UUID().uuidString
                let snapshot = job
                rows[index].phase = .running(0)
                let attempt = snapshot.request.operationID
                let work = Task<ArchiveCreation.Result, any Error> {
                    guard !snapshot.items.isEmpty else {
                        throw EngineError(.failed, String(localized: "There are no files to pack for this item."))
                    }
                    return try await ArchiveCreation.run(
                        snapshot.items, totalBytes: snapshot.totalBytes, attributes: snapshot.attributes,
                        request: snapshot.request, named: snapshot.name, in: snapshot.destination,
                        portableNames: true
                    ) { [weak self] fraction in
                        Task { @MainActor in
                            self?.advance(index, attempt: attempt, to: fraction)
                        }
                    }
                }
                activeAttempt = attempt
                current = work
                switch await work.result {
                case .success(let result):
                    rows[index].placed = result.placed
                    rows[index].verified = result.report.verified
                    rows[index].phase = .completed
                    jobs[id] = nil
                case .failure(let error):
                    rows[index].phase = EngineError(error).failure == .cancelled
                        ? .cancelled
                        : .failed(Failure(error, .pack, name: rows[index].name, destination: snapshot.destination,
                                          needs: snapshot.totalBytes))
                }
                current = nil
                activeAttempt = nil
            }
            worker = nil
            guard jobs.isEmpty else { return }
            removeCleanupDirectory()
            let finish = completion
            completion = nil
            finish?(.success(rows.flatMap(\.placed)))
        }
    }

    private var activeAttempt: String?

    private func advance(_ index: Int, attempt: String, to fraction: Double) {
        guard activeAttempt == attempt, rows.indices.contains(index),
              case .running(let shown) = rows[index].phase, fraction > shown else { return }
        rows[index].phase = .running(fraction)
    }

    private func removeCleanupDirectory() {
        guard let folder = cleanupDirectory else { return }
        cleanupDirectory = nil
        do {
            try FileManager.default.removeItem(at: folder)
            cleaned?(folder)
        } catch {
            // The Tray row stays available if its temporary group couldn't be removed.
        }
    }
}
