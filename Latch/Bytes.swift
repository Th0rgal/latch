import Foundation

enum Fuji {
    static let cameraHost = "192.168.0.1"
    static let port: UInt16 = 55740
    static let version: UInt32 = 0x8f53e4f2
    static let partialMax = 0x0010_0000
    static let stallBytes = 64 * 1024
    static let liedSize = 102_400

    static let openSession: UInt16 = 0x1002
    static let getObjectInfo: UInt16 = 0x1008
    static let getProp: UInt16 = 0x1015
    static let setProp: UInt16 = 0x1016
    static let getPartial: UInt16 = 0x101b
    static let ok: UInt16 = 0x2001

    static let getExtensionInfo: UInt16 = 0x9054
    static let getExtensionThumb: UInt16 = 0x9055
    static let getFolders: UInt16 = 0x9050
    static let getDates: UInt16 = 0x9053

    static let cameraState: UInt32 = 0xdf00
    static let clientState: UInt32 = 0xdf01
    static let events: UInt32 = 0xd212
    static let imageGetVersion: UInt32 = 0xdf21
    static let objectVersion: UInt32 = 0xdf22
    static let remoteVersion: UInt32 = 0xdf24
    static let remoteObjectVersion: UInt32 = 0xdf25
    static let remotePhotoView: UInt32 = 0xdf28
    static let compressSmall: UInt32 = 0xd226
    static let correctSize: UInt32 = 0xd227
    static let unknownD22B: UInt32 = 0xd22b
    static let importCount: UInt32 = 0xd620
    static let importHandles: UInt32 = 0xd621
}

enum LE {
    static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    static func put16(_ data: inout Data, _ offset: Int, _ value: UInt16) {
        data[offset] = UInt8(value & 0xff)
        data[offset + 1] = UInt8((value >> 8) & 0xff)
    }

    static func put32(_ data: inout Data, _ offset: Int, _ value: UInt32) {
        data[offset] = UInt8(value & 0xff)
        data[offset + 1] = UInt8((value >> 8) & 0xff)
        data[offset + 2] = UInt8((value >> 16) & 0xff)
        data[offset + 3] = UInt8((value >> 24) & 0xff)
    }

    static func data16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xff), UInt8((value >> 8) & 0xff)])
    }

    static func data32(_ value: UInt32) -> Data {
        var data = Data(count: 4)
        put32(&data, 0, value)
        return data
    }
}

enum Packets {
    static func initCommand(name: String) -> Data {
        var data = Data(count: 82)
        LE.put32(&data, 0, 0x52)
        LE.put32(&data, 4, 1)
        LE.put32(&data, 8, Fuji.version)
        LE.put32(&data, 12, 0x5d48a5ad)
        LE.put32(&data, 16, 0x0b7fb287)
        LE.put32(&data, 20, 0xd0ded5d3)
        LE.put32(&data, 24, 0)
        var offset = 28
        for unit in name.utf16 {
            if offset + 4 > data.count { break }
            LE.put16(&data, offset, unit)
            offset += 2
        }
        return data
    }

    static func command(code: UInt16, tid: UInt32, params: [UInt32] = []) -> Data {
        var data = Data(count: 12 + params.count * 4)
        LE.put32(&data, 0, UInt32(data.count))
        LE.put16(&data, 4, 1)
        LE.put16(&data, 6, code)
        LE.put32(&data, 8, tid)
        for (index, param) in params.enumerated() {
            LE.put32(&data, 12 + index * 4, param)
        }
        return data
    }

    static func dataPhase(code: UInt16, tid: UInt32, payload: Data) -> Data {
        var data = Data(count: 12 + payload.count)
        LE.put32(&data, 0, UInt32(data.count))
        LE.put16(&data, 4, 2)
        LE.put16(&data, 6, code)
        LE.put32(&data, 8, tid)
        data.replaceSubrange(12..<data.count, with: payload)
        return data
    }

    static func response(code: UInt16, tid: UInt32, rc: UInt16 = Fuji.ok) -> Data {
        var data = Data(count: 12)
        LE.put32(&data, 0, 12)
        LE.put16(&data, 4, 3)
        LE.put16(&data, 6, rc)
        LE.put32(&data, 8, tid)
        _ = code
        return data
    }

    static func hex(_ data: Data, limit: Int = 24) -> String {
        data.prefix(limit).map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    static func ptpType(_ data: Data) -> UInt16 {
        data.count >= 6 ? LE.u16(data, 4) : 0
    }

    static func ptpCode(_ data: Data) -> UInt16 {
        data.count >= 8 ? LE.u16(data, 6) : 0
    }

    static func payload(_ data: Data) -> Data {
        data.count > 12 ? data.subdata(in: 12..<data.count) : Data()
    }
}

struct CardFrame: Identifiable, Equatable, Sendable {
    let handle: Int
    let name: String
    let bytes: Int
    let recipe: String
    var id: Int { handle }
}

enum Catalog {
    static let roll: [CardFrame] = [
        CardFrame(handle: 1, name: "DSCF4418.JPG", bytes: 2_400_000, recipe: "Nostalgic Neg"),
        CardFrame(handle: 2, name: "DSCF4422.JPG", bytes: 1_150_000, recipe: "Classic Chrome"),
        CardFrame(handle: 3, name: "DSCF4430.JPG", bytes: 3_200_000, recipe: "Acros+Ye"),
        CardFrame(handle: 4, name: "DSCF4436.JPG", bytes: 1_800_000, recipe: "Velvia"),
        CardFrame(handle: 5, name: "DSCF4441.JPG", bytes: 980_000, recipe: "Classic Neg"),
        CardFrame(handle: 6, name: "DSCF4448.JPG", bytes: 2_050_000, recipe: "Reala Ace"),
    ]
}

enum LinkError: Error {
    case stalled
    case shortRead
    case closed
    case timeout
    case rejected
}

protocol ByteLink: AnyObject, Sendable {
    func open() async throws
    func write(_ data: Data) async throws
    func read(count: Int) async throws -> Data
    func close() async
}
