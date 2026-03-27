import Foundation

// MARK: - Constants

private let ZPAD:   UInt8 = 0x2A  // *
private let ZDLE:   UInt8 = 0x18  // ^X
private let ZHEX:   UInt8 = 0x42  // B  (hex frame)
private let ZBIN:   UInt8 = 0x41  // A  (binary CRC-16 frame)
private let ZBIN32: UInt8 = 0x43  // C  (binary CRC-32 frame)

private let ZRQINIT: UInt8 = 0   // remote sz  → we are receiver
private let ZRINIT:  UInt8 = 1   // remote rz  → we are sender
private let ZFILE:   UInt8 = 4
private let ZFIN:    UInt8 = 8
private let ZRPOS:   UInt8 = 9
private let ZDATA:   UInt8 = 10
private let ZEOF:    UInt8 = 11

private let ZCRCE: UInt8 = 0x68  // end of file
private let ZCRCG: UInt8 = 0x69  // go (no ack)
private let ZCRCQ: UInt8 = 0x6A  // ack required
private let ZCRCW: UInt8 = 0x6B  // wait for ack

// MARK: - CRC-16 / XMODEM

private func crc16(_ bytes: [UInt8]) -> UInt16 {
    var crc: UInt16 = 0
    for b in bytes {
        crc ^= UInt16(b) << 8
        for _ in 0..<8 {
            crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
        }
    }
    return crc
}

// MARK: - ZModemEngine

/// Combined ZMODEM engine.
/// • remote runs `sz file`  → role = .receiving  (we receive, save to ~/Downloads)
/// • remote runs `rz`       → role = .sending    (we send queued files)
/// • Drag-and-drop queues files and sends `rz\n` to remote automatically.
final class ZModemEngine {

    // MARK: Callbacks (always invoked on main thread)

    /// Raw bytes to write to SSH stdin.
    var onSend: (([UInt8]) -> Void)?
    /// A file was fully received from the remote.
    var onFileReceived: ((String, Data) -> Void)?
    /// Progress update — (filename, bytesHandled, totalBytes).
    var onProgress: ((String, Int, Int) -> Void)?
    /// Remote `rz` detected but no files are queued — caller should open file picker
    /// then call `resumeSendWithFiles(_:)`.
    var onNeedFilesForSend: (() -> Void)?
    /// Human-readable status line.
    var onStatusChange: ((String) -> Void)?
    /// Transfer finished (success or cancel).
    var onTransferDone: (() -> Void)?

    // MARK: Private: role

    private enum Role { case idle, receiving, sending }
    private var role: Role = .idle

    // MARK: Private: byte-stream parser state

    private enum Phase {
        case idle
        case gotStar
        case gotTwoStars
        case gotZdle
        case hexFrame([UInt8])
        case binHdr([UInt8], esc: Bool)
        case dataSubpacket([UInt8], esc: Bool)
        /// Drains CRC bytes that follow a data subpacket terminator (CRC-16 = 2 decoded bytes).
        /// We don't validate CRC, but must consume these bytes so they don't reach the terminal.
        /// `continueData`: if true, go back to dataSubpacket after drain (ZCRCG streaming);
        /// if false, go to idle (new frame header expected).
        case drainCrc(Int, esc: Bool, continueData: Bool)
    }
    private var phase: Phase = .idle
    private var frameType: UInt8 = 0
    /// Number of decoded bytes needed for the current binary frame header.
    /// ZBIN (CRC-16) = 7 bytes (5 hdr + 2 CRC).  ZBIN32 (CRC-32) = 9 bytes (5 hdr + 4 CRC).
    private var binHdrNeeded: Int = 7

    // MARK: Private: receive state

    private var rxData   = Data()
    private var rxName   = ""
    private var rxSize   = 0
    private var rxOffset = 0

    // MARK: Private: send state

    private var txFiles: [(name: String, data: Data)] = []
    private var txIndex  = 0
    private var txOffset = 0

    // MARK: - Public API

    /// Feed raw bytes arriving from SSH; returns the slice the terminal should display.
    func feed(_ slice: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        var out: [UInt8] = []
        out.reserveCapacity(slice.count)
        for b in slice {
            if let pt = processByte(b) { out.append(pt) }
        }
        return ArraySlice(out)
    }

    /// Queue local files to upload when remote next sends ZRINIT.
    /// Call this before sending `rz\n` to the remote.
    func queueFilesForUpload(_ files: [(name: String, data: Data)]) {
        txFiles  = files
        txIndex  = 0
        txOffset = 0
    }

    /// Called after `onNeedFilesForSend` fires and the user has picked files.
    func resumeSendWithFiles(_ files: [(name: String, data: Data)]) {
        txFiles  = files
        txIndex  = 0
        txOffset = 0
        if role == .sending {
            sendNextFile()
        }
    }

    var hasPendingFiles: Bool { !txFiles.isEmpty && txIndex < txFiles.count }

    // MARK: - Byte processor

    private func processByte(_ b: UInt8) -> UInt8? {
        switch phase {

        case .idle:
            if b == ZPAD { phase = .gotStar; return nil }
            return b

        case .gotStar:
            if b == ZPAD { phase = .gotTwoStars; return nil }
            // lrzsz binary frames (ZFILE, ZDATA) use only ONE ZPAD: *\x18A/C...
            // Hex frames (ZRQINIT, ZRINIT) use two ZPADs: **\x18B...
            if b == ZDLE { phase = .gotZdle; return nil }
            phase = .idle; return b

        case .gotTwoStars:
            if b == ZDLE { phase = .gotZdle; return nil }
            // Got ** but no ZDLE — restart ZPAD detection from scratch.
            if b == ZPAD { phase = .gotTwoStars; return nil }
            phase = .idle; return b

        case .gotZdle:
            switch b {
            case ZHEX:
                phase = .hexFrame([])
            case ZBIN:
                binHdrNeeded = 7   // 5 header + 2 CRC-16
                phase = .binHdr([], esc: false)
            case ZBIN32:
                binHdrNeeded = 9   // 5 header + 4 CRC-32
                phase = .binHdr([], esc: false)
            default:
                phase = .idle
                return b
            }
            return nil

        case .hexFrame(var chars):
            if b == 0x0D || b == 0x0A || b == 0x11 { return nil }
            chars.append(b)
            if chars.count >= 14 {
                parseHexFrame(chars)
                // ZFILE and ZDATA hex frames are followed by a data subpacket.
                phase = needsDataSubpacket() ? .dataSubpacket([], esc: false) : .idle
            } else {
                phase = .hexFrame(chars)
            }
            return nil

        case .binHdr(var raw, let esc):
            if esc {
                raw.append(b ^ 0x40)
                if raw.count >= binHdrNeeded {
                    parseBinFrame(Array(raw.prefix(5)))
                    phase = needsDataSubpacket() ? .dataSubpacket([], esc: false) : .idle
                } else {
                    phase = .binHdr(raw, esc: false)
                }
            } else if b == ZDLE {
                phase = .binHdr(raw, esc: true)
            } else {
                raw.append(b)
                if raw.count >= binHdrNeeded {
                    parseBinFrame(Array(raw.prefix(5)))
                    phase = needsDataSubpacket() ? .dataSubpacket([], esc: false) : .idle
                } else {
                    phase = .binHdr(raw, esc: false)
                }
            }
            return nil

        case .dataSubpacket(var raw, let esc):
            if esc {
                // After ZDLE, the terminator bytes are sent as-is (NOT XOR'd with 0x40).
                // Only regular escaped data bytes are XOR'd with 0x40.
                if b == ZCRCE || b == ZCRCG || b == ZCRCQ || b == ZCRCW {
                    handleDataSubpacket(raw, terminator: b)
                    // ZCRCG = streaming "go" → sender immediately sends next chunk with no
                    // new frame header, so go back to dataSubpacket after draining the CRC.
                    // ZCRCQ = "ack required" but data also continues immediately.
                    // All other terminators (ZCRCW, ZCRCE) expect a new frame header next.
                    let cont = (b == ZCRCG || b == ZCRCQ)
                    phase = .drainCrc(2, esc: false, continueData: cont)
                } else {
                    raw.append(b ^ 0x40)
                    phase = .dataSubpacket(raw, esc: false)
                }
            } else if b == ZDLE {
                phase = .dataSubpacket(raw, esc: true)
            } else {
                // ZPAD (0x2A '*') is NOT in lrzsz's escape set, so it can appear as plain
                // file data inside a subpacket. Treat it — and every other byte — as data.
                raw.append(b)
                phase = .dataSubpacket(raw, esc: false)
            }
            return nil

        case .drainCrc(let remaining, let esc, let continueData):
            if esc {
                let newRemaining = remaining - 1
                phase = newRemaining > 0
                    ? .drainCrc(newRemaining, esc: false, continueData: continueData)
                    : (continueData ? .dataSubpacket([], esc: false) : .idle)
            } else if b == ZDLE {
                phase = .drainCrc(remaining, esc: true, continueData: continueData)
            } else {
                // Treat every byte — including ZPAD (0x2A) — as a CRC byte; a legitimate
                // CRC value can be 0x2A and it is never ZDLE-escaped by lrzsz.
                let newRemaining = remaining - 1
                phase = newRemaining > 0
                    ? .drainCrc(newRemaining, esc: false, continueData: continueData)
                    : (continueData ? .dataSubpacket([], esc: false) : .idle)
            }
            return nil
        }
    }

    private func needsDataSubpacket() -> Bool {
        frameType == ZFILE || frameType == ZDATA
    }

    // MARK: - Frame parsers

    private func parseHexFrame(_ chars: [UInt8]) {
        guard chars.count >= 14 else { return }
        let type = h2(chars[0], chars[1])
        let p0   = h2(chars[2],  chars[3])
        let p1   = h2(chars[4],  chars[5])
        let p2   = h2(chars[6],  chars[7])
        let p3   = h2(chars[8],  chars[9])
        frameType = type
        handleFrame(type: type, p: (p0, p1, p2, p3))
    }

    private func parseBinFrame(_ raw: [UInt8]) {
        guard raw.count >= 5 else { return }
        frameType = raw[0]
        handleFrame(type: raw[0], p: (raw[1], raw[2], raw[3], raw[4]))
    }

    // MARK: - Frame dispatch

    private func handleFrame(type: UInt8, p: (UInt8, UInt8, UInt8, UInt8)) {
        switch type {

        // ── Receive path (remote ran sz) ──────────────────────────────────
        case ZRQINIT:
            role = .receiving
            // p0 = CANFDX(0x01) | CANOVIO(0x02) — deliberately omit CANFC32(0x20)
            // so the remote sz uses CRC-16 frames, which our parser handles.
            sendHex(ZRINIT, p0: 0x03, p1: 0, p2: 0, p3: 0)
            onStatusChange?("ZMODEM: 接收开始")

        case ZEOF where role == .receiving:
            if le32(p) == rxOffset { saveReceivedFile() }
            sendHex(ZRINIT, p0: 0x03, p1: 0, p2: 0, p3: 0)

        case ZFIN where role == .receiving:
            sendHex(ZFIN, p0: 0, p1: 0, p2: 0, p3: 0)
            send(Array("OO".utf8))
            onStatusChange?("ZMODEM: 下载完成")
            onTransferDone?()
            reset()

        // ── Send path (remote ran rz) ─────────────────────────────────────
        case ZRINIT:
            if role == .idle || role == .sending {
                role = .sending
                if txIndex < txFiles.count {
                    sendNextFile()
                } else if !txFiles.isEmpty {
                    // All files sent; wait for ZFIN exchange
                    sendHex(ZFIN, p0: 0, p1: 0, p2: 0, p3: 0)
                } else {
                    // No files queued — ask caller
                    onNeedFilesForSend?()
                }
            }

        case ZRPOS where role == .sending:
            txOffset = le32(p)
            sendDataFromCurrentOffset()

        case ZFIN where role == .sending:
            // Remote acknowledged our ZFIN
            send(Array("OO".utf8))
            onStatusChange?("ZMODEM: 上传完成")
            onTransferDone?()
            reset()

        default:
            break
        }
    }

    // MARK: - Data subpacket handler

    private func handleDataSubpacket(_ data: [UInt8], terminator: UInt8) {
        guard role == .receiving else { return }

        if frameType == ZFILE {
            parseFileInfo(data)
            rxData   = Data()
            rxOffset = 0
            sendRPOS(0)
        } else if frameType == ZDATA {
            rxData.append(contentsOf: data)
            rxOffset += data.count
            onProgress?(rxName, rxOffset, rxSize)
            if terminator == ZCRCQ || terminator == ZCRCW {
                sendRPOS(rxOffset)
            }
        }
    }

    // MARK: - Receive helpers

    private func parseFileInfo(_ data: [UInt8]) {
        let nullIdx = data.firstIndex(of: 0) ?? data.endIndex
        rxName = String(bytes: data[..<nullIdx], encoding: .utf8) ?? "download"
        if nullIdx < data.endIndex {
            let rest = String(bytes: data[(nullIdx + 1)...], encoding: .utf8) ?? ""
            rxSize   = Int(rest.split(separator: " ").first.flatMap { Int($0) } ?? 0)
        }
        onStatusChange?("ZMODEM: 接收 \(rxName) (\(rxSize) 字节)")
        onProgress?(rxName, 0, rxSize)
    }

    private func saveReceivedFile() {
        onFileReceived?(rxName.isEmpty ? "download" : rxName, rxData)
    }

    // MARK: - Send helpers

    private func sendNextFile() {
        guard txIndex < txFiles.count else {
            sendHex(ZFIN, p0: 0, p1: 0, p2: 0, p3: 0)
            return
        }
        let file = txFiles[txIndex]
        txOffset = 0
        onStatusChange?("ZMODEM: 发送 \(file.name) (\(file.data.count) 字节)")
        onProgress?(file.name, 0, file.data.count)

        // ZFILE header
        sendHex(ZFILE, p0: 0, p1: 0, p2: 0, p3: 0)

        // File info subpacket (ZCRCW → wait for ZRPOS before data)
        var info = Array(file.name.utf8)
        info.append(0)
        info += Array("\(file.data.count) 0 100644 0 1".utf8)
        info.append(0)
        send(makeDataSubpacket(info, terminator: ZCRCW))
    }

    private func sendDataFromCurrentOffset() {
        guard txIndex < txFiles.count else { return }
        let file   = txFiles[txIndex]
        let data   = file.data
        let offset = txOffset

        guard offset < data.count else {
            sendEOF(size: data.count)
            return
        }

        // ZDATA header at current offset
        let o = UInt32(offset)
        sendHex(ZDATA,
                p0: UInt8(o & 0xFF),
                p1: UInt8((o >> 8) & 0xFF),
                p2: UInt8((o >> 16) & 0xFF),
                p3: UInt8((o >> 24) & 0xFF))

        // Data subpackets (1 KB each)
        let chunkSize = 1024
        var pos = offset
        while pos < data.count {
            let end  = min(pos + chunkSize, data.count)
            let chunk = Array(data[pos..<end])
            let last  = end >= data.count
            send(makeDataSubpacket(chunk, terminator: last ? ZCRCE : ZCRCG))
            pos = end
            txOffset = pos
            onProgress?(file.name, pos, data.count)
        }

        sendEOF(size: data.count)
        txIndex += 1
        // Wait for ZRINIT (next file) or ZFIN (all done)
    }

    private func sendEOF(size: Int) {
        let s = UInt32(size)
        sendHex(ZEOF,
                p0: UInt8(s & 0xFF),
                p1: UInt8((s >> 8) & 0xFF),
                p2: UInt8((s >> 16) & 0xFF),
                p3: UInt8((s >> 24) & 0xFF))
    }

    // MARK: - Frame builders

    private func sendHex(_ type: UInt8, p0: UInt8, p1: UInt8, p2: UInt8, p3: UInt8) {
        send(makeHexFrame(type: type, p0: p0, p1: p1, p2: p2, p3: p3))
    }

    private func sendRPOS(_ offset: Int) {
        let o = UInt32(offset)
        sendHex(ZRPOS,
                p0: UInt8(o & 0xFF),
                p1: UInt8((o >> 8) & 0xFF),
                p2: UInt8((o >> 16) & 0xFF),
                p3: UInt8((o >> 24) & 0xFF))
    }

    private func makeHexFrame(type: UInt8, p0: UInt8, p1: UInt8, p2: UInt8, p3: UInt8) -> [UInt8] {
        let hdr: [UInt8] = [type, p0, p1, p2, p3]
        let chk = crc16(hdr)
        var s = "**\u{18}B"
        for b in hdr { s += String(format: "%02x", b) }
        s += String(format: "%04x", chk)
        s += "\r\n\u{11}"
        return Array(s.utf8)
    }

    /// Builds an escaped data subpacket:
    /// ZDLE-escaped(data) + ZDLE + terminator + ZDLE-escaped(CRC16(data+term))
    private func makeDataSubpacket(_ data: [UInt8], terminator: UInt8) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(data.count + 8)
        for b in data { zdleAppend(b, to: &out) }
        out.append(ZDLE)
        out.append(terminator)
        let crc = crc16(data + [terminator])
        zdleAppend(UInt8((crc >> 8) & 0xFF), to: &out)
        zdleAppend(UInt8(crc & 0xFF),         to: &out)
        return out
    }

    private func zdleAppend(_ b: UInt8, to buf: inout [UInt8]) {
        switch b {
        case ZDLE, 0x10, 0x90, 0x11, 0x91, 0x13, 0x93:
            buf.append(ZDLE); buf.append(b ^ 0x40)
        default:
            buf.append(b)
        }
    }

    private func send(_ bytes: [UInt8]) { onSend?(bytes) }

    // MARK: - Reset

    private func reset() {
        role = .idle; phase = .idle; frameType = 0; binHdrNeeded = 7
        rxData = Data(); rxName = ""; rxSize = 0; rxOffset = 0
        txFiles = []; txIndex = 0; txOffset = 0
    }

    // MARK: - Helpers

    private func h2(_ a: UInt8, _ b: UInt8) -> UInt8 { (hn(a) << 4) | hn(b) }
    private func hn(_ b: UInt8) -> UInt8 {
        switch b {
        case 0x30...0x39: return b - 0x30
        case 0x61...0x66: return b - 0x61 + 10
        case 0x41...0x46: return b - 0x41 + 10
        default: return 0
        }
    }
    private func le32(_ p: (UInt8, UInt8, UInt8, UInt8)) -> Int {
        Int(p.0) | (Int(p.1) << 8) | (Int(p.2) << 16) | (Int(p.3) << 24)
    }
}
