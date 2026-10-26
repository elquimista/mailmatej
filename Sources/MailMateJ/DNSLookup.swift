import Foundation
import dnssd

/// DNS lookups for working out an account's type from its address: a domain's mail servers (MX), and
/// a JMAP server announced for it (`_jmap._tcp` SRV, RFC 8620 §2.2).
enum DNSLookup {
    /// The host names a domain's mail goes to, best first; empty when there are none or the lookup fails.
    static func mailServers(_ domain: String) async -> [String] {
        let records = await query(domain, type: UInt16(kDNSServiceType_MX))
        return records.compactMap { data -> (Int, String)? in
            guard data.count > 2, let host = name(in: data, at: 2) else { return nil }
            return (Int(data[0]) << 8 | Int(data[1]), host)
        }.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// The JMAP server a domain announces (`_jmap._tcp.<domain>`), as host and port.
    static func jmapServer(_ domain: String) async -> (host: String, port: Int)? {
        let records = await query("_jmap._tcp." + domain, type: UInt16(kDNSServiceType_SRV))
        return records.compactMap { data -> (priority: Int, host: String, port: Int)? in
            guard data.count > 6, let host = name(in: data, at: 6), host != "." , !host.isEmpty else { return nil }
            let port = Int(data[4]) << 8 | Int(data[5])
            return (Int(data[0]) << 8 | Int(data[1]), host, port)
        }.min { $0.priority < $1.priority }.map { ($0.host, $0.port) }
    }

    /// A domain name in DNS wire format (labels, each preceded by its length), without the final dot.
    static func name(in data: Data, at start: Int) -> String? {
        var labels: [String] = []
        var i = data.startIndex + start
        while i < data.endIndex {
            let length = Int(data[i])
            if length == 0 { return labels.joined(separator: ".").lowercased() }
            guard length < 64, i + 1 + length <= data.endIndex else { return nil }  // no compression here
            labels.append(String(decoding: data[(i + 1)..<(i + 1 + length)], as: UTF8.self))
            i += 1 + length
        }
        return nil
    }

    /// The records' data for a name and type, collected for up to `timeout` seconds.
    private static func query(_ name: String, type: UInt16, timeout: Double = 3) async -> [Data] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[Data], Never>) in
            let lookup = Lookup(continuation)
            var ref: DNSServiceRef?
            let context = Unmanaged.passRetained(lookup).toOpaque()
            let error = DNSServiceQueryRecord(
                &ref, 0, 0, name, type, UInt16(kDNSServiceClass_IN),
                { _, flags, _, errorCode, _, _, _, length, bytes, _, context in
                    guard let context else { return }
                    let lookup = Unmanaged<Lookup>.fromOpaque(context).takeUnretainedValue()
                    if errorCode == kDNSServiceErr_NoError, let bytes, length > 0 {
                        lookup.records.append(Data(bytes: bytes, count: Int(length)))
                    }
                    // The answer is complete once no more records are coming right away.
                    if flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) == 0 { lookup.finish() }
                }, context)
            guard error == kDNSServiceErr_NoError, let ref else {
                Unmanaged<Lookup>.fromOpaque(context).release()
                return continuation.resume(returning: [])
            }
            lookup.start(ref, context: context, timeout: timeout)
        }
    }

    /// One query in flight: its records, and the socket source feeding them in.
    private final class Lookup: @unchecked Sendable {
        var records: [Data] = []
        private var continuation: CheckedContinuation<[Data], Never>?
        private var ref: DNSServiceRef?
        private var source: DispatchSourceRead?
        private var context: UnsafeMutableRawPointer?
        private let queue = DispatchQueue(label: "app.mailmatej.dns")

        init(_ continuation: CheckedContinuation<[Data], Never>) { self.continuation = continuation }

        func start(_ ref: DNSServiceRef, context: UnsafeMutableRawPointer, timeout: Double) {
            self.ref = ref
            self.context = context
            queue.sync {
                let source = DispatchSource.makeReadSource(fileDescriptor: DNSServiceRefSockFD(ref), queue: queue)
                source.setEventHandler { [weak self] in
                    guard let self, let ref = self.ref else { return }
                    if DNSServiceProcessResult(ref) != kDNSServiceErr_NoError { self.finish() }
                }
                self.source = source
                source.resume()
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish() }
            }
        }

        /// Hands over the records once, and tears the query down (on the lookup's queue).
        func finish() {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(returning: records)
            source?.cancel()
            source = nil
            if let ref { DNSServiceRefDeallocate(ref) }
            ref = nil
            if let context { Unmanaged<Lookup>.fromOpaque(context).release() }
            context = nil
        }
    }
}
