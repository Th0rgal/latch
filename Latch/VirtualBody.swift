import Foundation

struct Faults: Equatable, Sendable {
    var flakyHandshake = true
    var requireOk = true
    var stallChunk = true
    var lieAboutSize = true
    var impatientOpen = false

    static let none = Faults(
        flakyHandshake: false,
        requireOk: false,
        stallChunk: false,
        lieAboutSize: false,
        impatientOpen: false
    )
}

final class RunControl: @unchecked Sendable {
    var aborted = false
    var ok = false
}

enum Reply {
    case silent
    case bytes(Data)
    case stall(Data)
}

/// In-process X100VI. Speaks the same length-prefixed packets as the body.
final class VirtualBody: @unchecked Sendable {
    let faults: Faults
    let control: RunControl
    let frames: [CardFrame]
    private(set) var initCount = 0
    private(set) var correctSize: UInt16 = 0
    private var stallArmed: Bool
    private var pendingSet: UInt32?

    init(faults: Faults, control: RunControl, frames: [CardFrame]) {
        self.faults = faults
        self.control = control
        self.frames = frames
        self.stallArmed = faults.stallChunk
    }

    var cameraState: UInt32 {
        if !faults.requireOk || control.ok { return 2 }
        return 0
    }

    func handle(_ packet: Data) -> Reply {
        guard packet.count >= 8 else { return .bytes(Data()) }
        let kind = LE.u32(packet, 4)
        if packet.count == 82 && kind == 1 {
            return handshake()
        }
        if let prop = pendingSet, Packets.ptpType(packet) == 2 {
            pendingSet = nil
            applySet(prop, Packets.payload(packet))
            let tid = LE.u32(packet, 8)
            return .bytes(Packets.response(code: Fuji.setProp, tid: tid))
        }
        guard Packets.ptpType(packet) == 1 else { return .silent }
        return command(packet)
    }

    private func handshake() -> Reply {
        initCount += 1
        if faults.flakyHandshake && initCount == 1 {
            var fail = Data(count: 16)
            LE.put32(&fail, 0, 16)
            LE.put32(&fail, 4, 5)
            return .bytes(fail)
        }
        var ack = Data(count: 82)
        LE.put32(&ack, 0, 0x52)
        LE.put32(&ack, 4, 2)
        var offset = 28
        for unit in "X100VI".utf16 {
            LE.put16(&ack, offset, unit)
            offset += 2
        }
        return .bytes(ack)
    }

    private func command(_ packet: Data) -> Reply {
        let code = Packets.ptpCode(packet)
        let tid = LE.u32(packet, 8)
        let params = paramsOf(packet)
        switch code {
        case Fuji.setProp:
            pendingSet = params.first ?? 0
            return .silent
        case Fuji.getProp:
            let prop = params.first ?? 0
            let payload = propValue(prop)
            return .bytes(Packets.dataPhase(code: code, tid: tid, payload: payload)
                + Packets.response(code: code, tid: tid))
        case Fuji.getObjectInfo:
            let handle = Int(params.first ?? 0)
            let payload = objectInfo(handle)
            return .bytes(Packets.dataPhase(code: code, tid: tid, payload: payload)
                + Packets.response(code: code, tid: tid))
        case Fuji.getPartial:
            let handle = Int(params.first ?? 0)
            let offset = Int(params.count > 1 ? params[1] : 0)
            let ask = Int(params.count > 2 ? params[2] : 0)
            return partial(handle: handle, offset: offset, ask: ask, code: code, tid: tid)
        default:
            return .bytes(Packets.response(code: code, tid: tid))
        }
    }

    private func partial(handle: Int, offset: Int, ask: Int, code: UInt16, tid: UInt32) -> Reply {
        let total = frames.first { $0.handle == handle }?.bytes ?? ask
        let remain = max(0, total - offset)
        let give = min(ask, remain)
        if stallArmed && give > Fuji.stallBytes {
            stallArmed = false
            let payload = Data(count: Fuji.stallBytes)
            return .stall(Packets.dataPhase(code: code, tid: tid, payload: payload))
        }
        let payload = Data(count: give)
        return .bytes(Packets.dataPhase(code: code, tid: tid, payload: payload)
            + Packets.response(code: code, tid: tid))
    }

    private func propValue(_ prop: UInt32) -> Data {
        switch prop {
        case Fuji.events:
            var data = Data(count: 8)
            LE.put16(&data, 0, 1)
            LE.put16(&data, 2, UInt16(Fuji.cameraState & 0xffff))
            LE.put32(&data, 4, cameraState)
            return data
        case Fuji.objectVersion, Fuji.remoteVersion:
            return LE.data32(0x0002_000c)
        case Fuji.remoteObjectVersion:
            return LE.data32(5)
        case Fuji.imageGetVersion:
            return LE.data32(0x0002_000a)
        case Fuji.remotePhotoView:
            return LE.data32(1)
        case Fuji.importCount:
            return LE.data32(UInt32(frames.count))
        default:
            return LE.data32(0)
        }
    }

    private func applySet(_ prop: UInt32, _ payload: Data) {
        let value: UInt16
        if payload.count >= 2 {
            value = LE.u16(payload, 0)
        } else {
            value = 0
        }
        if prop == Fuji.correctSize {
            correctSize = value
        }
    }

    private func objectInfo(_ handle: Int) -> Data {
        var data = Data(count: 208)
        LE.put32(&data, 8, UInt32(Fuji.partialMax))
        let frame = frames.first { $0.handle == handle }
        let real = frame?.bytes ?? 0
        let reported = (faults.lieAboutSize && correctSize == 0) ? Fuji.liedSize : real
        LE.put32(&data, 13, UInt32(reported))
        if let name = frame?.name {
            let bytes = Array(name.utf8)
            for (index, byte) in bytes.enumerated() where 52 + index < data.count {
                data[52 + index] = byte
            }
        }
        return data
    }

    private func paramsOf(_ packet: Data) -> [UInt32] {
        guard packet.count >= 12 else { return [] }
        var params: [UInt32] = []
        var offset = 12
        while offset + 4 <= packet.count {
            params.append(LE.u32(packet, offset))
            offset += 4
        }
        return params
    }
}

final class VirtualLink: ByteLink, @unchecked Sendable {
    let body: VirtualBody
    private var incoming = Data()
    private var outgoing = Data()
    private var stalled = false

    init(body: VirtualBody) {
        self.body = body
    }

    func open() async throws {
        incoming.removeAll()
        outgoing.removeAll()
        stalled = false
    }

    func close() async {
        incoming.removeAll()
        outgoing.removeAll()
        stalled = false
    }

    func write(_ data: Data) async throws {
        incoming.append(data)
        while incoming.count >= 4 {
            let length = Int(LE.u32(incoming, 0))
            if length < 4 || incoming.count < length { return }
            let packet = Data(incoming.prefix(length))
            incoming.removeFirst(length)
            switch body.handle(packet) {
            case .silent:
                break
            case .bytes(let bytes):
                outgoing.append(bytes)
            case .stall(let bytes):
                outgoing.append(bytes)
                stalled = true
            }
        }
    }

    func read(count: Int) async throws -> Data {
        if outgoing.count < count {
            if stalled { throw LinkError.stalled }
            throw LinkError.shortRead
        }
        let chunk = Data(outgoing.prefix(count))
        outgoing.removeFirst(count)
        return chunk
    }
}
