import Foundation

/// Lightweight DNS message helpers.  Operates on raw bytes — no Combine,
/// no Network framework dependency — so it can live in BigBrotherCore and
/// be shared by the tunnel, tests, and the harness.
public enum DNSMessage {

    // MARK: - Transaction ID

    /// Extract the 16-bit transaction ID from the first two bytes of a DNS
    /// packet.  Returns `nil` if the data is too short.
    public static func transactionID(_ packet: Data) -> UInt16? {
        guard packet.count >= 2 else { return nil }
        let base = packet.startIndex
        return UInt16(packet[base]) << 8 | UInt16(packet[base + 1])
    }

    // MARK: - Synthesized Responses

    /// Creates a minimal 12-byte DNS response header with no question,
    /// answer, authority, or additional sections.
    ///
    /// Typical usage: SERVFAIL or REFUSED for a malformed query where
    /// echoing the question section back would be unsafe.
    ///
    /// - Parameters:
    ///   - txnID: Transaction ID to echo back.
    ///   - flagsHigh: Byte 2 of the header (QR, Opcode, AA, TC, RD).
    ///     Common value: `0x81` = QR=1, RD=1.
    ///   - flagsLow: Byte 3 of the header (RA, Z, RCODE).
    ///     Common values: `0x02` = SERVFAIL, `0x05` = REFUSED.
    public static func headerOnlyResponse(
        txnID: UInt16,
        flagsHigh: UInt8,
        flagsLow: UInt8
    ) -> Data {
        var buf = Data(count: 12)
        buf[0] = UInt8(txnID >> 8)
        buf[1] = UInt8(txnID & 0xFF)
        buf[2] = flagsHigh
        buf[3] = flagsLow
        // QDCOUNT, ANCOUNT, NSCOUNT, ARCOUNT all zero (already zeroed by Data(count:))
        return buf
    }

    // MARK: - Question-Section Extraction

    /// Takes a full DNS query packet and returns a copy trimmed to just
    /// the 12-byte header + question section, with flags rewritten to a
    /// SERVFAIL response (QR=1, RD=1, RCODE=2) and answer/authority/
    /// additional counts zeroed.
    ///
    /// This strips EDNS OPT records and any other trailing sections that
    /// strict stubs would reject as trailing garbage in a SERVFAIL/REFUSED
    /// response.
    ///
    /// Returns `nil` if the packet is too short or the question section is
    /// malformed (label length > 63, premature EOF, missing QTYPE/QCLASS).
    public static func truncateToQuestion(_ query: Data) -> Data? {
        guard query.count >= 12 else { return nil }

        let base = query.startIndex
        let qdcount = UInt16(query[base + 4]) << 8 | UInt16(query[base + 5])

        // We only handle the common case of exactly 1 question.
        // Multi-question packets are legal but vanishingly rare; return nil
        // to let the caller fall back to a header-only response.
        guard qdcount == 1 else {
            return qdcount == 0 ? nil : nil
        }

        // Walk the QNAME label sequence.
        var offset = base + 12
        while offset < query.endIndex {
            let labelLen = Int(query[offset])
            if labelLen == 0 {
                // Root label terminator — advance past it.
                offset += 1
                break
            }
            if labelLen > 63 {
                // Compression pointer or illegal label length in a query.
                return nil
            }
            offset += 1 + labelLen
        }

        // After the QNAME we need QTYPE (2 bytes) + QCLASS (2 bytes).
        let questionEnd = offset + 4
        guard questionEnd <= query.endIndex else { return nil }

        // Build the truncated response: header + question section only.
        var result = Data(query[base..<questionEnd])

        // Rewrite flags: QR=1, Opcode=0, AA=0, TC=0, RD=1, RA=0, RCODE=2 (SERVFAIL)
        result[2] = 0x81
        result[3] = 0x02

        // Zero ANCOUNT, NSCOUNT, ARCOUNT (QDCOUNT stays 1).
        result[6] = 0; result[7] = 0   // ANCOUNT
        result[8] = 0; result[9] = 0   // NSCOUNT
        result[10] = 0; result[11] = 0 // ARCOUNT

        return result
    }
}
