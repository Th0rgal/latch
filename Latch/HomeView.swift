import SwiftUI

struct HomeView: View {
    @State private var model = BenchModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    Hairline()
                    linkPicker
                    status
                    if let summary = model.summary {
                        Text(summary)
                            .font(Ink.prose(15))
                            .foregroundStyle(model.phase == "Stopped" ? Ink.bad : Ink.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    actions
                    if model.mode == .virtual {
                        Hairline()
                        faults
                        Hairline()
                        card
                    }
                    if !model.compare.isEmpty {
                        Hairline()
                        compare
                    }
                    if !model.saved.isEmpty {
                        Hairline()
                        saved
                    }
                    Hairline()
                    NavigationLink {
                        TraceView(lines: model.lines)
                    } label: {
                        Stat(label: "Trace", value: "\(model.lines.count)")
                    }
                    .buttonStyle(.plain)
                    NavigationLink {
                        NotesView()
                    } label: {
                        Stat(label: "Protocol", value: "55740")
                    }
                    .buttonStyle(.plain)
                }
                .padding(22)
            }
            .background(Ink.paper)
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(Ink.ink)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Tag("X100 VI")
            Text("Latch")
                .font(Ink.serif(40))
                .foregroundStyle(Ink.ink)
            Text("The Wi-Fi import, written so a dropped socket is a line in the trace instead of a spinner.")
                .font(Ink.prose(16))
                .foregroundStyle(Ink.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var linkPicker: some View {
        Picker("Link", selection: $model.mode) {
            ForEach(BenchMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .disabled(model.busy)
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 8) {
            Stat(
                label: "Status",
                value: model.phase,
                tone: model.phase == "Stopped" ? Ink.bad : (model.phase == "On the phone" ? Ink.good : Ink.ink)
            )
            Stat(label: "Body", value: model.mode == .camera ? Fuji.cameraHost : "virtual")
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            if model.mode == .camera {
                Text("Join FUJIFILM-xxxx in Settings, allow Local Network, then come back. OK is on the camera, not here.")
                    .font(Ink.prose(14))
                    .foregroundStyle(Ink.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.waiting {
                QuietButton(title: "OK on the virtual body", filled: true) {
                    model.pressOK()
                }
            }
            QuietButton(title: model.mode == .camera ? "Import from the camera" : "Import with Latch", filled: true) {
                model.start(.latch)
            }
            .disabled(model.busy || (model.mode == .virtual && model.selected.isEmpty))
            if model.mode == .virtual {
                QuietButton(title: "Replay XApp") {
                    model.start(.xapp)
                }
                .disabled(model.busy || model.selected.isEmpty)
                QuietButton(title: model.phase == "Comparing" ? "Comparing..." : "Compare the five stalls") {
                    model.runCompare()
                }
                .disabled(model.busy || model.selected.isEmpty)
            }
            if model.busy {
                Button("Stop") { model.stop() }
                    .font(Ink.mono(13))
                    .foregroundStyle(Ink.muted)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
    }

    private var faults: some View {
        VStack(alignment: .leading, spacing: 4) {
            Tag("Faults")
            fault("First init fails", model.faults.flakyHandshake) { model.faults.flakyHandshake.toggle() }
            fault("Body waits for OK", model.faults.requireOk) { model.faults.requireOk.toggle() }
            fault("Wi-Fi dies mid-file", model.faults.stallChunk) { model.faults.stallChunk.toggle() }
            fault("Size stuck at 100 KB", model.faults.lieAboutSize) { model.faults.lieAboutSize.toggle() }
            fault("Skip the 50 ms settle", model.faults.impatientOpen) { model.faults.impatientOpen.toggle() }
        }
    }

    private func fault(_ label: String, _ on: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            Stat(label: label, value: on ? "on" : "off", tone: on ? Ink.bad : Ink.muted)
                .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .disabled(model.busy)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 4) {
            Tag("Card")
            ForEach(Catalog.roll) { frame in
                let on = model.selected.contains(frame.handle)
                let file = model.files.first { $0.handle == frame.handle }
                Button {
                    if model.selected.contains(frame.handle) {
                        model.selected.remove(frame.handle)
                    } else {
                        model.selected.insert(frame.handle)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Stat(
                            label: frame.name,
                            value: file.map { caption($0) } ?? (on ? "selected" : "left"),
                            tone: file?.state == "full" ? Ink.good : (file?.state == "partial" || file?.state == "lost" ? Ink.bad : Ink.ink)
                        )
                        Text("\(frame.recipe) · \(ByteFormat.string(frame.bytes))")
                            .font(Ink.mono(12))
                            .foregroundStyle(Ink.muted)
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .disabled(model.busy)
            }
        }
    }

    private var compare: some View {
        VStack(alignment: .leading, spacing: 12) {
            Tag("Same card")
            ForEach(model.compare) { row in
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.fault)
                        .font(Ink.serif(18))
                        .foregroundStyle(Ink.ink)
                    Text("XApp · \(row.xappOk ? "keeps going" : "stops")")
                        .font(Ink.mono(12))
                        .foregroundStyle(row.xappOk ? Ink.good : Ink.bad)
                    Text(row.xapp)
                        .font(Ink.prose(14))
                        .foregroundStyle(Ink.ink2)
                    Text("Latch · \(row.latchOk ? "keeps going" : "stops")")
                        .font(Ink.mono(12))
                        .foregroundStyle(row.latchOk ? Ink.good : Ink.bad)
                    Text(row.latch)
                        .font(Ink.prose(14))
                        .foregroundStyle(Ink.ink2)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var saved: some View {
        VStack(alignment: .leading, spacing: 8) {
            Tag("Files")
            ForEach(model.saved, id: \.path) { url in
                ShareLink(item: url) {
                    Stat(label: url.lastPathComponent, value: "share")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func caption(_ file: FileResult) -> String {
        switch file.state {
        case "full": return "copied"
        case "partial": return "short"
        case "lost": return "discarded"
        default: return file.state
        }
    }
}

struct TraceView: View {
    let lines: [TraceLine]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if lines.isEmpty {
                    Text("Run an import. Containers land here, in order.")
                        .font(Ink.prose(15))
                        .foregroundStyle(Ink.ink2)
                        .padding(22)
                }
                ForEach(lines) { line in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(line.dir)
                                .frame(width: 28, alignment: .leading)
                            Text("\(line.ms)")
                                .frame(width: 52, alignment: .leading)
                            Text(line.title)
                        }
                        .font(Ink.mono(12, .medium))
                        .foregroundStyle(line.level == "fail" ? Ink.bad : Ink.ink)
                        if !line.detail.isEmpty {
                            Text(line.detail)
                                .font(Ink.mono(12))
                                .foregroundStyle(Ink.ink2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !line.hex.isEmpty {
                            Text(line.hex)
                                .font(Ink.mono(11))
                                .foregroundStyle(Ink.muted)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                    Hairline()
                        .padding(.horizontal, 22)
                }
            }
        }
        .background(Ink.paper)
        .navigationTitle("Trace")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct NotesView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("The body speaks Fuji PTP on TCP 55740: an 82-byte init, then USB-style containers. Not ISO PTP/IP.")
                    .font(Ink.prose(16))
                    .foregroundStyle(Ink.ink2)
                note("1", "Init", "Length 0x52, type 1, version 0x8f53e4f2, then the GUID, then the name in UTF-16. The first try often comes back Init Fail. Latch sends it again.")
                note("2", "Settle, then OpenSession", "Wait 50 ms. Transaction id starts at 1, not 0.")
                note("3", "0xD212", "CameraState 0xDF00 stays 0 until OK is pressed on the body.")
                note("4", "DF01 = 20", "Remote image view, the XApp gallery dialect. Classic playback writes 2.")
                note("5", "D227", "Until this is 1, ObjectInfo reports about 100 KB and a client that trusts it writes a short JPEG.")
                note("6", "0x101B", "GetPartialObject, at most 1 MB. If the socket dies, keep the offset and ask again. The body usually does not ask for OK a second time.")
                Text("The sequence follows the published libfuji client, not a decompile of XApp. This phone cannot prove what today's iOS XApp binary does. It can show where a session that behaves like that client gives up, and it can talk to the camera when you are on its Wi-Fi.")
                    .font(Ink.prose(15))
                    .foregroundStyle(Ink.muted)
            }
            .padding(22)
        }
        .background(Ink.paper)
        .navigationTitle("Protocol")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func note(_ index: String, _ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(index)
                .font(Ink.mono(11, .medium))
                .tracking(1.4)
                .foregroundStyle(Ink.muted)
            Text(title)
                .font(Ink.serif(20))
                .foregroundStyle(Ink.ink)
            Text(body)
                .font(Ink.prose(15))
                .foregroundStyle(Ink.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}
