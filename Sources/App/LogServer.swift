//
//  LogServer.swift
//  EquilController
//
//  Beágyazott pici HTTP log-szerver (Apple Network framework, nincs külső függőség).
//  Cél: a fejlesztő a Macen `curl http://<iphone-ip>:8080` paranccsal élőben
//  kiolvashatja az utolsó 1000 log-sort (mert a devicectl console megbízhatatlan).
//
//  - Thread-safe ring buffer (soros DispatchQueue).
//  - Minden bejövő kapcsolatra a teljes naplót adja vissza text/plain válaszként.
//  - en0 IPv4 cím lekérdezés getifaddrs-szal.
//

import Foundation
import Network

final class LogServer {

    // MARK: Ring buffer
    private var lines: [String] = []
    private let maxLines = 1000
    private let lock = DispatchQueue(label: "app.equil.logserver.buffer")

    // MARK: Listener
    private var listener: NWListener?
    private let netQueue = DispatchQueue(label: "app.equil.logserver.net")
    private(set) var port: UInt16 = 8080

    /// Append a log line (thread-safe, trimmed to last `maxLines`).
    func append(_ line: String) {
        let stamped = Self.timestamp() + " " + line
        lock.async {
            self.lines.append(stamped)
            if self.lines.count > self.maxLines {
                self.lines.removeFirst(self.lines.count - self.maxLines)
            }
        }
    }

    /// Start the HTTP listener. Robust: nem omlik össze, ha a port foglalt.
    func start(port: UInt16 = 8080) {
        self.port = port
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            print("[LogServer] érvénytelen port: \(port)")
            return
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        do {
            let l = try NWListener(using: params, on: nwPort)
            l.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("[LogServer] fut a porton \(port)")
                case .failed(let err):
                    print("[LogServer] listener hiba: \(err)")
                default:
                    break
                }
            }
            l.newConnectionHandler = { [weak self] conn in
                self?.handle(conn)
            }
            l.start(queue: netQueue)
            self.listener = l
        } catch {
            print("[LogServer] nem indult a listener (\(port)): \(error)")
        }
    }

    func stop() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
    }

    // MARK: Connection handling
    private func handle(_ conn: NWConnection) {
        conn.stateUpdateHandler = { state in
            if case .failed = state { conn.cancel() }
        }
        conn.start(queue: netQueue)
        // A HTTP kérést elolvassuk (nem parse-oljuk), majd válaszolunk és zárunk.
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, _, _ in
            self?.respond(on: conn)
        }
    }

    private func respond(on conn: NWConnection) {
        let body = snapshot().data(using: .utf8) ?? Data()
        var header = "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: text/plain; charset=utf-8\r\n"
        header += "Connection: close\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "\r\n"
        var out = Data(header.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private func snapshot() -> String {
        var copy: [String] = []
        lock.sync { copy = self.lines }
        if copy.isEmpty { return "(üres napló)\n" }
        return copy.joined(separator: "\n") + "\n"
    }

    // MARK: Helpers
    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }

    /// Az aktuális Wi-Fi (en0) IPv4 címe, vagy nil.
    var ipAddress: String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let interface = p.pointee
            let family = interface.ifa_addr.pointee.sa_family
            if family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr,
                                socklen_t(interface.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count),
                                nil, 0, NI_NUMERICHOST)
                    address = String(cString: hostname)
                }
            }
            ptr = interface.ifa_next
        }
        return address
    }
}
