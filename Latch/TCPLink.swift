import Foundation
import Network

/// TCP to the camera's command port. The phone has to already be on FUJIFILM-xxxx.
final class TCPLink: ByteLink, @unchecked Sendable {
    private let host: String
    private let port: UInt16
    private var connection: NWConnection?
    private var buffer = Data()
    private let queue = DispatchQueue(label: "md.thomas.latch.tcp")
    private var resumed = false

    init(host: String = Fuji.cameraHost, port: UInt16 = Fuji.port) {
        self.host = host
        self.port = port
    }

    func open() async throws {
        let endpoint = NWEndpoint.Host(host)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw LinkError.rejected }
        let connection = NWConnection(host: endpoint, port: nwPort, using: .tcp)
        self.connection = connection
        buffer.removeAll()
        resumed = false
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { [weak self] state in
                guard let self, !self.resumed else { return }
                switch state {
                case .ready:
                    self.resumed = true
                    connection.stateUpdateHandler = nil
                    cont.resume()
                case .failed(let error):
                    self.resumed = true
                    cont.resume(throwing: error)
                case .cancelled:
                    self.resumed = true
                    cont.resume(throwing: LinkError.closed)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    func close() async {
        connection?.cancel()
        connection = nil
        buffer.removeAll()
    }

    func write(_ data: Data) async throws {
        guard let connection else { throw LinkError.closed }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }

    func read(count: Int) async throws -> Data {
        while buffer.count < count {
            let more = try await receive()
            if more.isEmpty { throw LinkError.closed }
            buffer.append(more)
        }
        let chunk = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        return chunk
    }

    private func receive() async throws -> Data {
        guard let connection else { throw LinkError.closed }
        return try await withCheckedThrowingContinuation { cont in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                if let data, !data.isEmpty {
                    cont.resume(returning: data)
                    return
                }
                if isComplete {
                    cont.resume(returning: Data())
                    return
                }
                cont.resume(returning: Data())
            }
        }
    }
}
