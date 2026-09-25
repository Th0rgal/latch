import Foundation
import Observation

enum BenchMode: String, CaseIterable, Identifiable {
    case virtual = "Virtual body"
    case camera = "Camera Wi-Fi"
    var id: String { rawValue }
}

@MainActor
@Observable
final class BenchModel {
    var mode: BenchMode = .virtual
    var faults = Faults()
    var phase = "Idle"
    var summary: String?
    var lines: [TraceLine] = []
    var files: [FileResult] = []
    var compare: [CompareRow] = []
    var selected: Set<Int> = Set(Catalog.roll.map(\.handle))
    var saved: [URL] = []
    var busy = false
    var waiting = false

    private var control = RunControl()
    private var task: Task<Void, Never>?

    func pressOK() {
        control.ok = true
        waiting = false
        phase = "Importing"
    }

    func stop() {
        control.aborted = true
        task?.cancel()
    }

    func start(_ kind: ClientKind) {
        guard !busy else { return }
        control = RunControl()
        control.ok = mode == .virtual && !faults.requireOk
        lines = []
        compare = []
        summary = nil
        files = []
        busy = true
        waiting = mode == .virtual && faults.requireOk
        phase = waiting ? "Waiting for OK" : "Importing"
        let faults = self.faults
        let mode = self.mode
        let handles = selected
        task = Task {
            let result: RunResult
            if mode == .virtual {
                let frames = Catalog.roll.filter { handles.contains($0.handle) }
                let body = VirtualBody(faults: faults, control: control, frames: frames)
                let link = VirtualLink(body: body)
                result = await Importer.run(
                    link: link,
                    options: RunOptions(kind: kind, frames: frames, faults: faults, control: control, paceNanos: 12_000_000),
                    log: { [weak self] line in
                        Task { @MainActor in self?.lines.append(line) }
                    }
                )
            } else {
                let link = TCPLink()
                let dir = Self.folder()
                result = await Importer.run(
                    link: link,
                    options: RunOptions(
                        kind: .latch,
                        frames: [],
                        faults: .none,
                        control: control,
                        paceNanos: 0,
                        live: true,
                        saveDirectory: dir
                    ),
                    log: { [weak self] line in
                        Task { @MainActor in self?.lines.append(line) }
                    }
                )
                saved = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?.sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
            }
            files = result.files.filter { ($0.state != "skipped" && $0.state != "lost") || $0.got > 0 }
            if result.reason == "still-waiting" {
                phase = "Waiting for OK"
            } else {
                phase = result.ok ? "On the phone" : "Stopped"
                waiting = false
                busy = false
            }
            summary = result.summary
            if result.reason != "still-waiting" { busy = false }
        }
    }

    func runCompare() {
        guard !busy else { return }
        busy = true
        phase = "Comparing"
        summary = nil
        let frames = Catalog.roll.filter { selected.contains($0.handle) }
        task = Task {
            let rows = await Importer.compare(frames: frames)
            compare = rows
            phase = "Idle"
            busy = false
            summary = "Five faults, run separately. Latch keeps the offset. XApp closes the socket."
        }
    }

    private static func folder() -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Latch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
