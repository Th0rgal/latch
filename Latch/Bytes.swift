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
    static let invalidObject: UInt16 = 0x2009
    static let sessionAlreadyOpen: UInt16 = 0x201e

    static let getExtensionInfo: UInt16 = 0x9054
    static let getExtensionThumb: UInt16 = 0x9055
    static let getFolders: UInt16 = 0x9050
    static let getDates: UInt16 = 0x9053

    static let cameraState: UInt32 = 0xdf00
    static let clientState: UInt32 = 0xdf01
    static let events: UInt32 = 0xd212
    static let objectCount: UInt32 = 0xd222
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
    case response(UInt16)
}

protocol ByteLink: AnyObject, Sendable {
    func open() async throws
    func write(_ data: Data) async throws
    func read(count: Int) async throws -> Data
    func close() async
}

/// Packed `PtpFujiEvents`: u16 count, then {u16 code, u32 value}. DF00 is not always first.
enum FujiEvents {
    struct Item: Equatable {
        var code: UInt16
        var value: UInt32
    }

    static func parse(_ data: Data) -> [Item] {
        guard data.count >= 2 else { return [] }
        let count = Int(LE.u16(data, 0))
        var items: [Item] = []
        var offset = 2
        for _ in 0..<count {
            guard offset + 6 <= data.count else { break }
            items.append(Item(code: LE.u16(data, offset), value: LE.u32(data, offset + 2)))
            offset += 6
        }
        return items
    }

    static func value(_ data: Data, prop: UInt32) -> UInt32? {
        let code = UInt16(prop & 0xffff)
        return parse(data).first { $0.code == code }?.value
    }
}

/// Device-prop array as libpict reads it: u32 count, then that many u32s.
enum FujiArray {
    static func handles(_ data: Data) -> [Int] {
        guard data.count >= 4 else { return [] }
        let count = Int(LE.u32(data, 0))
        guard count > 0, count <= 20_000, data.count >= 4 + count * 4 else { return [] }
        return (0..<count).map { Int(LE.u32(data, 4 + $0 * 4)) }
    }

    static func encode(_ values: [Int]) -> Data {
        var data = Data(count: 4 + values.count * 4)
        LE.put32(&data, 0, UInt32(values.count))
        for (index, value) in values.enumerated() {
            LE.put32(&data, 4 + index * 4, UInt32(value))
        }
        return data
    }
}

/// Packed `PtpFujiObjectInfo`. `compressed_size` is the unaligned u32 at offset 13.
/// The filename is a PTP string (u8 length, then UTF-16) starting at offset 52, not raw ASCII.
enum ObjectInfo {
    static let sizeOffset = 13
    static let nameOffset = 52

    static func payload(name: String, bytes: Int, maxPartial: Int) -> Data {
        var data = Data(count: 208)
        LE.put32(&data, 8, UInt32(maxPartial))
        LE.put32(&data, sizeOffset, UInt32(bytes))
        writeString(&data, nameOffset, name)
        return data
    }

    static func compressedSize(_ data: Data) -> Int? {
        guard data.count >= sizeOffset + 4 else { return nil }
        return Int(LE.u32(data, sizeOffset))
    }

    /// libfuji copies 52 fixed bytes, then `ptp_read_string` for the name.
    static func filename(_ data: Data) -> String? {
        guard data.count > nameOffset else { return nil }
        let length = Int(data[nameOffset])
        if length == 0 { return nil }
        var raw: [UInt8] = []
        var cursor = nameOffset + 1
        var left = length
        while left > 0, cursor + 1 < data.count, raw.count < 63 {
            let unit = LE.u16(data, cursor)
            cursor += 2
            left -= 1
            if unit == 0 { break }
            if unit < 32 || unit > 126 { continue }
            raw.append(UInt8(unit & 0xff))
        }
        guard !raw.isEmpty else { return nil }
        return String(bytes: raw, encoding: .utf8)
    }

    private static func writeString(_ data: inout Data, _ offset: Int, _ name: String) {
        let units = Array(name.utf16.prefix(31))
        guard offset < data.count else { return }
        data[offset] = UInt8(units.count + 1)
        var cursor = offset + 1
        for unit in units {
            guard cursor + 2 <= data.count else { return }
            LE.put16(&data, cursor, unit)
            cursor += 2
        }
        if cursor + 2 <= data.count {
            LE.put16(&data, cursor, 0)
        }
    }
}
