import Foundation
import MacAgentCore
import Network

/// A deliberately tiny HTTP server: one endpoint, POST /api/report. Each request must carry a
/// valid fleet-key signature; the reply lists that Mac's pending (signed) actions.
final class FleetServer: @unchecked Sendable {
    private var listener: NWListener?
    private let store: ConsoleStore
    private let library: Library
    private let fleetKey: String
    private let queue = DispatchQueue(label: "macagent.console.server")
    /// Macs waiting for requests (long-poll), by serial. Touched only on `queue`.
    private var waiters: [String: [NWConnection]] = [:]
    /// How long to hold a Mac's waiting request before answering "nothing".
    static let holdFor: TimeInterval = 55
    static let maxBody = 4 << 20   // incoming reports; outgoing files can be any size

    @MainActor
    init(store: ConsoleStore, library: Library) {
        self.store = store
        self.library = library
        self.fleetKey = store.keys.fleetKey
        // When a request is queued for a Mac that's waiting, answer it now.
        store.onQueue = { [weak self] serial in self?.queue.async { self?.wake(serial) } }
    }

    /// Answer a waiting Mac with its pending actions (on `queue`).
    private func wake(_ serial: String) {
        guard let conns = waiters.removeValue(forKey: serial), !conns.isEmpty else { return }
        Task { @MainActor [store] in
            let pending = store.pending(for: serial)
            let body = (try? FleetWire.encoder().encode(FleetResponse(actions: pending))) ?? Data()
            for c in conns { self.send(c, status: 200, body: body) }
        }
    }

    @MainActor
    func start() {
        do {
            let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: ConsoleStore.port)!)
            listener.stateUpdateHandler = { [store] state in
                Task { @MainActor in
                    switch state {
                    case .ready: store.serverStatus = "Listening on port \(ConsoleStore.port)"
                    case .failed(let e): store.serverStatus = "Server stopped: \(e.localizedDescription)"
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            store.serverStatus = "Couldn't listen on port \(ConsoleStore.port): \(error.localizedDescription)"
        }
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        read(conn, buffer: Data())
    }

    private func read(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if error != nil || buf.count > Self.maxBody { return conn.cancel() }
            if let request = HTTPRequest(buf) {
                self.respond(conn, to: request)
            } else if done {
                conn.cancel()
            } else {
                self.read(conn, buffer: buf)
            }
        }
    }

    private func respond(_ conn: NWConnection, to req: HTTPRequest) {
        // Install files: signed by the fleet key (the config holds secrets), served by SHA-256.
        if req.method == "GET", req.path.hasPrefix("/api/file/") {
            let sha = String(req.path.dropFirst("/api/file/".count))
            guard let sig = req.headers[FleetWire.signatureHeader.lowercased()],
                  FleetWire.verify(Data(req.path.utf8), signature: sig, fleetKey: fleetKey) else {
                return send(conn, status: 401, body: Data())
            }
            Task { @MainActor [library] in
                let path = library.file(sha256: sha)?.path
                let data = path.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
                if let data, FleetWire.sha256(data) == sha {
                    self.send(conn, status: 200, body: data)
                } else {
                    self.send(conn, status: 404, body: Data())
                }
            }
            return
        }
        // Long-poll: reply at once if something is pending, else hold until queued or timed out.
        if req.method == "GET", req.path.hasPrefix("/api/wait/") {
            let serial = String(req.path.dropFirst("/api/wait/".count))
            guard let sig = req.headers[FleetWire.signatureHeader.lowercased()],
                  FleetWire.verify(Data(req.path.utf8), signature: sig, fleetKey: fleetKey) else {
                return send(conn, status: 401, body: Data())
            }
            Task { @MainActor [store] in
                store.markSeen(serial)
                let pending = store.pending(for: serial)
                if !pending.isEmpty {
                    self.send(conn, status: 200, body: (try? FleetWire.encoder().encode(FleetResponse(actions: pending))) ?? Data())
                    return
                }
                self.queue.async {
                    self.waiters[serial, default: []].append(conn)
                    self.queue.asyncAfter(deadline: .now() + Self.holdFor) {
                        guard let i = self.waiters[serial]?.firstIndex(where: { $0 === conn }) else { return }
                        self.waiters[serial]?.remove(at: i)
                        self.send(conn, status: 200, body: (try? FleetWire.encoder().encode(FleetResponse(actions: []))) ?? Data())
                    }
                }
            }
            return
        }
        guard req.method == "POST", req.path == "/api/report" else { return send(conn, status: 404, body: Data()) }
        guard let sig = req.headers[FleetWire.signatureHeader.lowercased()],
              FleetWire.verify(req.body, signature: sig, fleetKey: fleetKey),
              let report = try? FleetWire.decoder().decode(FleetReport.self, from: req.body) else {
            return send(conn, status: 401, body: Data())
        }
        Task { @MainActor [store] in
            let pending = store.receive(report)
            let body = (try? FleetWire.encoder().encode(FleetResponse(actions: pending))) ?? Data()
            self.send(conn, status: 200, body: body)
        }
    }

    private func send(_ conn: NWConnection, status: Int, body: Data) {
        let reason = [200: "OK", 401: "Unauthorized", 404: "Not Found"][status] ?? "Error"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
    }
}

/// Parses a complete HTTP/1.1 request (headers + Content-Length body); nil until it's all there.
struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    init?(_ data: Data) {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines.first?.split(separator: " ") ?? []
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard data.count - bodyStart >= length else { return nil }
        method = String(first[0])
        path = String(first[1])
        self.headers = headers
        body = data.subdata(in: bodyStart..<(bodyStart + length))
    }
}
