import Foundation

enum ClientKind: String, Sendable {
    case latch
    case xapp
}

struct TraceLine: Identifiable, Equatable, Sendable {
    let id: Int
    let ms: Int
    let dir: String
    let title: String
    let detail: String
    let hex: String
    var level: String
}

struct FileResult: Equatable, Sendable {
    var handle: Int
    var name: String
    var got: Int
    var total: Int
    var state: String
}

struct RunResult: Equatable, Sendable {
    var ok: Bool
    var reason: String
    var summary: String
    var files: [FileResult]
}

struct CompareRow: Identifiable, Equatable, Sendable {
    var id: String
    var fault: String
    var xapp: String
    var latch: String
    var xappOk: Bool
    var latchOk: Bool
}

struct RunOptions: Sendable {
    var kind: ClientKind
    var frames: [CardFrame]
    var faults: Faults
    var control: RunControl
    var probeOK: Bool = false
    var paceNanos: UInt64 = 0
    /// Live camera: keep polling DF00 until the body leaves WAIT, and keep every byte.
    var live: Bool = false
    var saveDirectory: URL? = nil
}

enum Importer {
    static func run(link: ByteLink, options: RunOptions, log: @escaping (TraceLine) -> Void) async -> RunResult {
        let io = IO(link: link, log: log)
        let kind = options.kind
        let faults = options.faults
        let selected = options.frames
        var files = selected.map {
            FileResult(handle: $0.handle, name: $0.name, got: 0, total: $0.bytes, state: "lost")
        }
        guard !selected.isEmpty else {
            return RunResult(ok: false, reason: "empty", summary: "Nothing selected on the card.", files: files)
        }

        do {
            try await link.open()
        } catch {
            return RunResult(ok: false, reason: "link", summary: "Could not open TCP \(Fuji.port). \(error.localizedDescription)", files: files)
        }

        io.note("Join the body", "Command socket is TCP \(Fuji.cameraHost):\(Fuji.port).")
        let name = kind == .latch ? "Latch" : "XApp"
        let attempts = kind == .latch ? 3 : 1
        var linked = false
        for attempt in 0..<attempts {
            if options.control.aborted || Task.isCancelled {
                return stop(files, io)
            }
            let packet = Packets.initCommand(name: name)
            io.out(attempt == 0 ? "Init \(name)" : "Init retry \(attempt + 1)", "82 bytes, version 0x8f53e4f2 before the GUID.", packet)
            try? await link.write(packet)
            do {
                let reply = try await io.readPacket()
                let type = reply.count >= 8 ? LE.u32(reply, 4) : 0
                if type == 5 {
                    io.fail("Init Fail", kind == .latch
                        ? "Type 5. Sending the init again."
                        : "Type 5. XApp treats this as a dead session.")
                    if kind == .xapp {
                        await link.close()
                        return RunResult(ok: false, reason: "init-fail", summary: "XApp stopped on the first Init Fail. The body often does this once; send the init again.", files: files)
                    }
                    continue
                }
                io.ok("Init Ack", "Type \(type). Session is not open yet.")
                linked = true
                break
            } catch {
                await link.close()
                return RunResult(ok: false, reason: "link", summary: "Init read failed. \(error.localizedDescription)", files: files)
            }
        }
        if !linked {
            await link.close()
            return RunResult(ok: false, reason: "init-fail", summary: "Init never acknowledged.", files: files)
        }

        if kind == .latch {
            io.note("Settle 50 ms", "OpenSession inside this window gets silence, not an error code.")
            if options.paceNanos > 0 || options.live {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        } else if faults.impatientOpen {
            io.fail("OpenSession with no settle", "Sent inside the 50 ms window. The socket goes quiet.")
            await link.close()
            return RunResult(ok: false, reason: "impatient", summary: "XApp sent OpenSession before the body was listening.", files: files)
        }

        let openTid: UInt32 = kind == .latch ? 1 : 0
        do {
            _ = try await io.command(Fuji.openSession, tid: openTid, params: [1], title: "OpenSession")
            if kind == .latch { io.tid = 2 }
        } catch {
            await link.close()
            return RunResult(ok: false, reason: "link", summary: "OpenSession failed. \(error.localizedDescription)", files: files)
        }

        if faults.requireOk || options.live {
            let limit = options.live ? 120 : (kind == .xapp ? 8 : (options.probeOK ? 3 : 240))
            var granted = !faults.requireOk && !options.live
            if options.control.ok { granted = true }
            if !granted {
                for index in 0..<limit {
                    if options.control.aborted || Task.isCancelled { return stop(files, io) }
                    if options.control.ok { granted = true; break }
                    let state = (try? await io.cameraState()) ?? 0
                    io.wait("DF00 = \(state)", index == 0 ? "EventsList 0xD212. 0 means the rear screen is still asking for OK." : "Still locked.")
                    if state != 0 { granted = true; break }
                    if !options.probeOK {
                        try? await Task.sleep(nanoseconds: options.live ? 400_000_000 : 350_000_000)
                    }
                }
            }
            if !granted {
                if kind == .latch && options.probeOK {
                    io.ok("Still polling for OK", "Latch does not give up here.")
                    return RunResult(ok: true, reason: "still-waiting", summary: "Latch is still on the event poll. It has not dropped the session.", files: files)
                }
                io.fail("Gave up waiting for OK", "Empty event lists, then the socket is closed.")
                await link.close()
                return RunResult(ok: false, reason: "ok-timeout", summary: "Stopped while the body was still on the OK screen. No photo was requested.", files: files)
            }
        }

        io.ok("DF00 = 2 FULL_ACCESS", options.control.ok ? "OK landed." : "Unlocked.")
        let versions: [(UInt32, String)] = [
            (Fuji.objectVersion, "DF22"),
            (Fuji.remoteObjectVersion, "DF25"),
            (Fuji.imageGetVersion, "DF21"),
            (Fuji.remoteVersion, "DF24"),
        ]
        for (prop, label) in versions {
            _ = try? await io.getProp(prop, title: "Get \(label)")
        }
        _ = try? await io.setProp(Fuji.clientState, value: LE.data16(20), title: "Set DF01 = 20")
        await gallery(io)

        for index in selected.indices {
            if options.control.aborted || Task.isCancelled { return stop(files, io) }
            let frame = selected[index]
            if kind == .latch {
                _ = try? await io.setProp(Fuji.correctSize, value: LE.data16(1), title: "Set D227 = 1")
            }
            let info = (try? await io.getData(Fuji.getObjectInfo, params: [UInt32(frame.handle)], title: "GetObjectInfo \(frame.name)")) ?? Data()
            let reported = info.count >= 17 ? Int(LE.u32(info, 13)) : frame.bytes
            io.note(
                "ObjectInfo \(frame.name)",
                reported == frame.bytes || frame.bytes == 0
                    ? "\(ByteFormat.string(reported)). Partial max is 1 MB."
                    : "Reported \(ByteFormat.string(reported)) because D227 is still 0. The file is \(ByteFormat.string(frame.bytes))."
            )
            if options.live && (info.count < 17 || reported == 0) {
                files[index].state = "skipped"
                break
            }

            if kind == .xapp {
                let exchange = await io.partial(handle: frame.handle, offset: 0, ask: reported, name: frame.name)
                files[index].got = exchange.bytes
                if !exchange.completed {
                    files[index].state = "lost"
                    io.fail("Socket quiet", "XApp drops the partial and closes the session. The rest of the card is never asked for.")
                    await link.close()
                    return RunResult(ok: false, reason: "stall", summary: "XApp stopped \(ByteFormat.string(exchange.bytes)) into \(frame.name) and threw the bytes away.", files: files)
                }
                files[index].state = exchange.bytes >= frame.bytes ? "full" : "partial"
                continue
            }

            var offset = 0
            var blob = Data()
            var stalls = 0
            let total = reported > 0 ? reported : frame.bytes
            while offset < total {
                if options.control.aborted || Task.isCancelled { return stop(files, io) }
                let ask = min(Fuji.partialMax, total - offset)
                let exchange = await io.partial(handle: frame.handle, offset: offset, ask: ask, name: frame.name)
                if !exchange.completed {
                    stalls += 1
                    offset += exchange.bytes
                    if options.saveDirectory != nil { blob.append(exchange.payload) }
                    files[index].got = offset
                    if stalls > 4 {
                        files[index].state = "lost"
                        io.fail("Socket stayed quiet", "Gave up after \(stalls) reconnects.")
                        await link.close()
                        return RunResult(
                            ok: false,
                            reason: "stall",
                            summary: "The command socket stayed quiet \(ByteFormat.string(offset)) into \(frame.name).",
                            files: files
                        )
                    }
                    io.fail("TCP stall", "\(ByteFormat.string(offset)) is in hand. Re-opening the command socket from that offset.")
                    await link.close()
                    do {
                        try await link.open()
                        _ = try await io.finishInit(name: "Latch")
                        _ = try await io.command(Fuji.openSession, tid: io.tid, params: [1], title: "OpenSession")
                        io.tid += 1
                        _ = try await io.setProp(Fuji.correctSize, value: LE.data16(1), title: "Set D227 = 1")
                    } catch {
                        await link.close()
                        return RunResult(ok: false, reason: "link", summary: "Reconnect failed. \(error.localizedDescription)", files: files)
                    }
                    continue
                }
                if exchange.bytes == 0 { break }
                offset += exchange.bytes
                if options.saveDirectory != nil { blob.append(exchange.payload) }
                files[index].got = offset
            }
            _ = try? await io.setProp(Fuji.correctSize, value: LE.data16(0), title: "Set D227 = 0")
            let goal = frame.bytes > 0 ? frame.bytes : total
            files[index].got = offset
            files[index].total = goal
            files[index].state = goal > 0 && offset >= goal ? "full" : "partial"
            if let dir = options.saveDirectory, !blob.isEmpty {
                let url = dir.appendingPathComponent(frame.name)
                try? blob.write(to: url, options: .atomic)
            }
        }

        await link.close()
        let short = files.filter { $0.state == "partial" }
        if !short.isEmpty {
            let summary = "Marked \(short.count) file\(short.count == 1 ? "" : "s") done short. D227 was never set, so the body under-reported the size."
            io.fail("Import finished short", summary)
            return RunResult(ok: false, reason: "truncated", summary: summary, files: files)
        }
        let copied = files.filter { $0.state == "full" }
        let summary = "\(name) copied \(copied.count) file\(copied.count == 1 ? "" : "s") off the card."
        io.ok("Card session closed", summary)
        return RunResult(ok: true, reason: "imported", summary: summary, files: files)
    }

    static func compare(frames: [CardFrame]) async -> [CompareRow] {
        let cases: [(String, String, Faults, Bool, Bool)] = [
            ("flaky", "First init fails", Faults(flakyHandshake: true, requireOk: false, stallChunk: false, lieAboutSize: false, impatientOpen: false), true, false),
            ("ok", "Body is waiting for OK", Faults(flakyHandshake: false, requireOk: true, stallChunk: false, lieAboutSize: false, impatientOpen: false), false, true),
            ("stall", "Wi-Fi dies mid-file", Faults(flakyHandshake: false, requireOk: false, stallChunk: true, lieAboutSize: false, impatientOpen: false), true, false),
            ("size", "Size field stuck at 100 KB", Faults(flakyHandshake: false, requireOk: false, stallChunk: false, lieAboutSize: true, impatientOpen: false), true, false),
            ("settle", "OpenSession before 50 ms", Faults(flakyHandshake: false, requireOk: false, stallChunk: false, lieAboutSize: false, impatientOpen: true), true, false),
        ]
        var rows: [CompareRow] = []
        for item in cases {
            let xapp = await one(.xapp, frames: frames, faults: item.2, autoOK: item.3, probe: item.4)
            let latch = await one(.latch, frames: frames, faults: item.2, autoOK: item.3, probe: item.4)
            rows.append(CompareRow(id: item.0, fault: item.1, xapp: xapp.summary, latch: latch.summary, xappOk: xapp.ok, latchOk: latch.ok))
        }
        return rows
    }

    private static func one(_ kind: ClientKind, frames: [CardFrame], faults: Faults, autoOK: Bool, probe: Bool) async -> RunResult {
        let control = RunControl()
        control.ok = autoOK
        let body = VirtualBody(faults: faults, control: control, frames: frames)
        let link = VirtualLink(body: body)
        return await run(link: link, options: RunOptions(kind: kind, frames: frames, faults: faults, control: control, probeOK: probe), log: { _ in })
    }

    private static func gallery(_ io: IO) async {
        let steps: [(String, UInt16, [UInt32])] = [
            ("Get DF28", Fuji.getProp, [Fuji.remotePhotoView]),
            ("Set D226 = 0", Fuji.setProp, []),
            ("GetExtensionObjectInfo", Fuji.getExtensionInfo, [0x1000_0001]),
            ("GetExtensionThumb", Fuji.getExtensionThumb, [0x1000_0001]),
            ("GetImageImportFolders", Fuji.getFolders, []),
            ("GetImageImportDates", Fuji.getDates, [0, 30000]),
            ("Get D621 handles", Fuji.getProp, [Fuji.importHandles]),
        ]
        for step in steps {
            if step.1 == Fuji.setProp {
                _ = try? await io.setProp(Fuji.compressSmall, value: LE.data16(0), title: step.0)
            } else if step.1 == Fuji.getProp {
                _ = try? await io.getProp(step.2[0], title: step.0)
            } else {
                _ = try? await io.command(step.1, tid: io.tid, params: step.2, title: step.0)
                io.tid += 1
            }
        }
    }

    private static func stop(_ files: [FileResult], _ io: IO) -> RunResult {
        io.fail("Stopped", "Bytes already kept stay on the frames that finished.")
        return RunResult(ok: false, reason: "aborted", summary: "Stopped.", files: files)
    }
}

private struct Exchange {
    var payload: Data
    var completed: Bool
    var bytes: Int { payload.count }
}

private final class IO {
    let link: ByteLink
    let log: (TraceLine) -> Void
    var tid: UInt32 = 1
    private var clock = 0
    private var seq = 1

    init(link: ByteLink, log: @escaping (TraceLine) -> Void) {
        self.link = link
        self.log = log
    }

    func note(_ title: String, _ detail: String) { emit("...", title, detail, Data(), "info") }
    func out(_ title: String, _ detail: String, _ data: Data) { emit("OUT", title, detail, data, "info") }
    func ok(_ title: String, _ detail: String) { emit("IN", title, detail, Data(), "ok") }
    func wait(_ title: String, _ detail: String) { emit("IN", title, detail, Data(), "wait") }
    func fail(_ title: String, _ detail: String) { emit("ERR", title, detail, Data(), "fail") }

    func readPacket() async throws -> Data {
        let head = try await link.read(count: 4)
        let length = Int(LE.u32(head, 0))
        if length < 4 { throw LinkError.shortRead }
        if length == 4 { return head }
        let rest = try await link.read(count: length - 4)
        return head + rest
    }

    func finishInit(name: String) async throws -> Bool {
        let packet = Packets.initCommand(name: name)
        out("Init \(name)", "Reconnect.", packet)
        try await link.write(packet)
        let reply = try await readPacket()
        let type = LE.u32(reply, 4)
        if type == 5 {
            fail("Init Fail", "Retrying the reconnect.")
            try await link.write(packet)
            let again = try await readPacket()
            return LE.u32(again, 4) != 5
        }
        ok("Init Ack", "Command socket is back.")
        return true
    }

    @discardableResult
    func command(_ code: UInt16, tid: UInt32, params: [UInt32], title: String) async throws -> Data {
        let packet = Packets.command(code: code, tid: tid, params: params)
        out(title, Packets.hex(packet), packet)
        try await link.write(packet)
        let first = try await readPacket()
        if Packets.ptpType(first) == 2 {
            _ = try await readPacket()
            return Packets.payload(first)
        }
        return Data()
    }

    func getProp(_ prop: UInt32, title: String) async throws -> Data {
        let data = try await command(Fuji.getProp, tid: tid, params: [prop], title: title)
        tid += 1
        return data
    }

    func setProp(_ prop: UInt32, value: Data, title: String) async throws {
        let packet = Packets.command(code: Fuji.setProp, tid: tid, params: [prop])
        let phase = Packets.dataPhase(code: Fuji.setProp, tid: tid, payload: value)
        out(title, Packets.hex(value), packet)
        try await link.write(packet)
        try await link.write(phase)
        _ = try await readPacket()
        tid += 1
    }

    func getData(_ code: UInt16, params: [UInt32], title: String) async throws -> Data {
        let data = try await command(code, tid: tid, params: params, title: title)
        tid += 1
        return data
    }

    func cameraState() async throws -> UInt32 {
        let data = try await getProp(Fuji.events, title: "Get 0xD212")
        guard data.count >= 8 else { return 0 }
        return LE.u32(data, 4)
    }

    func partial(handle: Int, offset: Int, ask: Int, name: String) async -> Exchange {
        let packet = Packets.command(code: Fuji.getPartial, tid: tid, params: [UInt32(handle), UInt32(offset), UInt32(ask)])
        out("GetPartialObject \(name)", "Offset \(offset), max \(ask).", packet)
        let current = tid
        tid += 1
        do {
            try await link.write(packet)
            let first = try await readPacket()
            let payload = Packets.payload(first)
            do {
                _ = try await readPacket()
                return Exchange(payload: payload, completed: true)
            } catch LinkError.stalled {
                _ = current
                return Exchange(payload: payload, completed: false)
            }
        } catch LinkError.stalled {
            return Exchange(payload: Data(), completed: false)
        } catch {
            return Exchange(payload: Data(), completed: false)
        }
    }

    private func emit(_ dir: String, _ title: String, _ detail: String, _ data: Data, _ level: String) {
        clock += 18
        let line = TraceLine(id: seq, ms: clock, dir: dir, title: title, detail: detail, hex: data.isEmpty ? "" : Packets.hex(data), level: level)
        seq += 1
        DispatchQueue.main.async {
            self.log(line)
        }
    }
}

enum ByteFormat {
    static func string(_ bytes: Int) -> String {
        if bytes >= 1_048_576 {
            let mb = Double(bytes) / 1_048_576
            return String(format: mb >= 10 ? "%.0f MB" : "%.1f MB", mb)
        }
        if bytes >= 1024 { return "\(bytes / 1024) KB" }
        return "\(bytes) B"
    }
}
