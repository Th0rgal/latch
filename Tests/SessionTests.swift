import XCTest
@testable import Latch

final class SessionTests: XCTestCase {
    func testLatchSurvivesFlakyInitAndStall() async {
        let result = await run(
            .latch,
            handles: [1, 5],
            faults: Faults(flakyHandshake: true, requireOk: true, stallChunk: true, lieAboutSize: true, impatientOpen: false),
            autoOK: true
        )
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.reason, "imported")
        let alley = result.files.first { $0.handle == 1 }
        XCTAssertEqual(alley?.state, "full")
        XCTAssertEqual(alley?.got, alley?.total)
    }

    func testXAppStopsOnInitFail() async {
        let result = await run(
            .xapp,
            handles: [1],
            faults: Faults(flakyHandshake: true, requireOk: false, stallChunk: false, lieAboutSize: false, impatientOpen: false),
            autoOK: true
        )
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.reason, "init-fail")
    }

    func testXAppDiscardsAStalledFile() async {
        let result = await run(
            .xapp,
            handles: [1, 2],
            faults: Faults(flakyHandshake: false, requireOk: false, stallChunk: true, lieAboutSize: false, impatientOpen: false),
            autoOK: true
        )
        XCTAssertEqual(result.reason, "stall")
        XCTAssertEqual(result.files.first { $0.handle == 2 }?.state, "lost")
    }

    func testXAppTrustsTheSizeLie() async {
        let result = await run(
            .xapp,
            handles: [1],
            faults: Faults(flakyHandshake: false, requireOk: false, stallChunk: false, lieAboutSize: true, impatientOpen: false),
            autoOK: true
        )
        XCTAssertEqual(result.reason, "truncated")
        XCTAssertEqual(result.files[0].state, "partial")
        XCTAssertEqual(result.files[0].got, 102_400)
    }

    func testCompareIsolatesFaults() async {
        let rows = await Importer.compare(frames: Array(Catalog.roll.prefix(2)))
        XCTAssertEqual(rows.count, 5)
        let flaky = rows.first { $0.id == "flaky" }
        XCTAssertEqual(flaky?.xappOk, false)
        XCTAssertEqual(flaky?.latchOk, true)
        let stall = rows.first { $0.id == "stall" }
        XCTAssertEqual(stall?.xappOk, false)
        XCTAssertEqual(stall?.latchOk, true)
    }

    private func run(_ kind: ClientKind, handles: [Int], faults: Faults, autoOK: Bool) async -> RunResult {
        let frames = Catalog.roll.filter { handles.contains($0.handle) }
        let control = RunControl()
        control.ok = autoOK
        let body = VirtualBody(faults: faults, control: control, frames: frames)
        let link = VirtualLink(body: body)
        return await Importer.run(
            link: link,
            options: RunOptions(kind: kind, frames: frames, faults: faults, control: control),
            log: { _ in }
        )
    }
}
