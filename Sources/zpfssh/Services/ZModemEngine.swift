import Foundation

// MARK: - Constants

private let ZPAD:   UInt8 = 0x2A  // *
private let ZDLE:   UInt8 = 0x18  // ^X
private let ZHEX:   UInt8 = 0x42  // B  (hex frame)
private let ZBIN:   UInt8 = 0x41  // A  (binary CRC-16 frame)
private let ZBIN32: UInt8 = 0x43  // C  (binary CRC-32 frame)

private let ZRQINIT: UInt8 = 0   // remote sz  → we are receiver
private let ZRINIT:  UInt8 = 1   // remote rz  → we are sender
private let ZSINIT:  UInt8 = 2
private let ZACK:    UInt8 = 3
private let ZFILE:   UInt8 = 4
private let ZSKIP:   UInt8 = 5
private let ZFIN:    UInt8 = 8
private let ZRPOS:   UInt8 = 9
private let ZDATA:   UInt8 = 10
private let ZEOF:    UInt8 = 11

private let ZCRCE: UInt8 = 0x68  // end of file
private let ZCRCG: UInt8 = 0x69  // go (no ack)
private let ZCRCQ: UInt8 = 0x6A  // ack required
private let ZCRCW: UInt8 = 0x6B  // wait for ack

// ZRINIT capability flags (in p0)
private let ZF0_CANFDX:  UInt8 = 0x01
private let ZF0_CANOVIO: UInt8 = 0x02
private let ZF0_CANFC32: UInt8 = 0x20
private let ZF0_ESCCTL:  UInt8 = 0x40

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

// MARK: - CRC-32 (ZMODEM)

private func crc32(_ bytes: [UInt8]) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for b in bytes {
        crc ^= UInt32(b)
        for _ in 0..<8 {
            let mask: UInt32 = (crc & 1) != 0 ? 0xEDB8_8320 : 0
            crc = (crc >> 1) ^ mask
        }
    }
    return ~crc
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
    private var dataCrcBytes: Int = 2

    // MARK: Private: receive state

    private var rxData   = Data()
    private var rxName   = ""
    private var rxSize   = 0
    private var rxOffset = 0

    // MARK: Private: send state

    private var txFiles: [(name: String, data: Data)] = []
    private var txIndex  = 0
    private var txOffset = 0
    private var txLastEOFSize = 0
    private var txEscapeCtl = false
    private var txUseCRC32 = false
    private var sendPhase: SendPhase = .idle
    private var sendRetryCount = 0
    private var sendWatchdog: DispatchWorkItem?
    private var txSending = false

    private let txQueue = DispatchQueue(label: "zmodem.tx", qos: .userInitiated)

    private enum SendPhase {
        case idle
        case waitingZRPOS
        case streamingData
        case waitingZRINITOrZFIN
    }

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
        txLastEOFSize = 0
        sendPhase = .idle
        sendRetryCount = 0
        cancelSendWatchdog()
    }

    /// Called after `onNeedFilesForSend` fires and the user has picked files.
    func resumeSendWithFiles(_ files: [(name: String, data: Data)]) {
        txFiles  = files
        txIndex  = 0
        txOffset = 0
        txLastEOFSize = 0
        sendPhase = .idle
        sendRetryCount = 0
        cancelSendWatchdog()
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
            if b == ZDLE { phase = .gotZdle; return nil }
            phase = .idle; return b

        case .gotTwoStars:
            if b == ZDLE { phase = .gotZdle; return nil }
            if b == ZPAD { phase = .gotTwoStars; return nil }
            phase = .idle; return b

        case .gotZdle:
            switch b {
            case ZHEX:
                phase = .hexFrame([])
                dataCrcBytes = 2
            case ZBIN:
                binHdrNeeded = 7   // 5 header + 2 CRC-16
                dataCrcBytes = 2
                phase = .binHdr([], esc: false)
            case ZBIN32:
                binHdrNeeded = 9   // 5 header + 4 CRC-32
                dataCrcBytes = 4
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
                if b == ZCRCE || b == ZCRCG || b == ZCRCQ || b == ZCRCW {
                    handleDataSubpacket(raw, terminator: b)
                    let cont = (b == ZCRCG || b == ZCRCQ)
                    phase = .drainCrc(dataCrcBytes, esc: false, continueData: cont)
                } else {
                    raw.append(b ^ 0x40)
                    phase = .dataSubpacket(raw, esc: false)
                }
            } else if b == ZDLE {
                phase = .dataSubpacket(raw, esc: true)
            } else {
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
            sendHex(ZRINIT, p0: ZF0_CANFDX | ZF0_CANOVIO, p1: 0, p2: 0, p3: 0)
            onStatusChange?("ZMODEM: 接收开始")

        case ZEOF where role == .receiving:
            if le32(p) == rxOffset { saveReceivedFile() }
            sendHex(ZRINIT, p0: ZF0_CANFDX | ZF0_CANOVIO, p1: 0, p2: 0, p3: 0)

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
                // ZRINIT capability flags are carried in ZF0.
                // In practice some peers expose this in p3; keep p0 as fallback for compatibility.
                let zf0 = p.3 != 0 ? p.3 : p.0
                txEscapeCtl = (zf0 & ZF0_ESCCTL) != 0
                txUseCRC32 = (zf0 & ZF0_CANFC32) != 0

                switch sendPhase {
                case .waitingZRPOS:
                    // Remote re-sent ZRINIT — it didn't understand our ZFILE.
                    // Retry sending the file header (already uses binary frame).
                    if sendRetryCount < 5 {
                        sendRetryCount += 1
                        cancelSendWatchdog()
                        sendNextFile(retrying: true)
                    } else {
                        abortSend(reason: "ZMODEM: 握手失败，已取消")
                    }

                case .streamingData:
                    break

                case .waitingZRINITOrZFIN:
                    cancelSendWatchdog()
                    sendPhase = .idle
                    sendRetryCount = 0
                    if txIndex < txFiles.count {
                        sendNextFile()
                    } else {
                        sendHex(ZFIN, p0: 0, p1: 0, p2: 0, p3: 0)
                        sendPhase = .waitingZRINITOrZFIN
                        scheduleSendWatchdog(timeout: 5.0)
                    }

                case .idle:
                    cancelSendWatchdog()
                    sendRetryCount = 0
                    if txIndex < txFiles.count {
                        sendNextFile()
                    } else if !txFiles.isEmpty {
                        sendHex(ZFIN, p0: 0, p1: 0, p2: 0, p3: 0)
                        sendPhase = .waitingZRINITOrZFIN
                        scheduleSendWatchdog(timeout: 5.0)
                    } else {
                        onNeedFilesForSend?()
                    }
                }
            }

        case ZRPOS where role == .sending:
            cancelSendWatchdog()
            sendPhase = .idle
            sendRetryCount = 0
            txOffset = le32(p)
            sendDataFromCurrentOffset()

        case ZSKIP where role == .sending:
            cancelSendWatchdog()
            sendPhase = .idle
            sendRetryCount = 0
            txIndex += 1
            sendNextFile()

        case ZFIN where role == .sending:
            cancelSendWatchdog()
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

    private func sendNextFile(retrying: Bool = false) {
        guard txIndex < txFiles.count else {
            sendPhase = .waitingZRINITOrZFIN
            scheduleSendWatchdog(timeout: 5.0)
            sendHex(ZFIN, p0: 0, p1: 0, p2: 0, p3: 0)
            return
        }
        let file = txFiles[txIndex]
        txOffset = 0
        onStatusChange?("ZMODEM: 发送 \(file.name) (\(file.data.count) 字节)")
        onProgress?(file.name, 0, file.data.count)

        // ZFILE header — must be binary frame for lrzsz compatibility
        sendBinCompat(ZFILE, p0: 0, p1: 0, p2: 0, p3: 0)

        // File info subpacket (ZCRCW → wait for ZRPOS before data)
        var info = Array(file.name.utf8)
        info.append(0)
        info += Array("\(file.data.count) 0 100644 0 1".utf8)
        info.append(0)
        send(makeDataSubpacket(info, terminator: ZCRCW))
        sendPhase = .waitingZRPOS
        if !retrying {
            sendRetryCount = 0
        }
        scheduleSendWatchdog(timeout: 5.0)
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

        sendPhase = .streamingData
        txSending = true

        // ZDATA header — binary frame at current offset
        let o = UInt32(offset)
        sendBinCompat(ZDATA,
                p0: UInt8(o & 0xFF),
                p1: UInt8((o >> 8) & 0xFF),
                p2: UInt8((o >> 16) & 0xFF),
                p3: UInt8((o >> 24) & 0xFF))

        let chunkSize = 8192
        let fileName = file.name
        let totalSize = data.count
        let escCtl = txEscapeCtl
        let fileIndex = txIndex

        txQueue.async { [weak self] in
            var pos = offset
            while pos < totalSize {
                guard let self, self.txSending, self.role == .sending else { return }

                let end  = min(pos + chunkSize, totalSize)
                let chunk = Array(data[pos..<end])
                let last  = end >= totalSize
                let packet = self.buildDataSubpacket(
                    chunk,
                    terminator: last ? ZCRCE : ZCRCG,
                    escapeCtl: escCtl,
                    useCRC32: self.txUseCRC32
                )
                self.send(packet)
                pos = end
                self.txOffset = pos

                if pos % (chunkSize * 4) == 0 || last {
                    self.onProgress?(fileName, pos, totalSize)
                }

                if !last {
                    Thread.sleep(forTimeInterval: 0.001)
                }
            }

            guard let self, self.txSending else { return }
            self.txLastEOFSize = totalSize
            self.sendEOF(size: totalSize)
            self.txIndex = fileIndex + 1
            self.sendPhase = .waitingZRINITOrZFIN
            self.sendRetryCount = 0
            self.scheduleSendWatchdog(timeout: 8.0)
        }
    }

    private func sendEOF(size: Int) {
        let s = UInt32(size)
        sendBinCompat(ZEOF,
                      p0: UInt8(s & 0xFF),
                      p1: UInt8((s >> 8) & 0xFF),
                      p2: UInt8((s >> 16) & 0xFF),
                      p3: UInt8((s >> 24) & 0xFF))
    }

    // MARK: - Frame builders

    private func sendHex(_ type: UInt8, p0: UInt8, p1: UInt8, p2: UInt8, p3: UInt8) {
        send(makeHexFrame(type: type, p0: p0, p1: p1, p2: p2, p3: p3))
    }

    private func sendBinCompat(_ type: UInt8, p0: UInt8, p1: UInt8, p2: UInt8, p3: UInt8) {
        send(makeBinFrame(type: type, p0: p0, p1: p1, p2: p2, p3: p3, useCRC32: txUseCRC32, escapeCtl: txEscapeCtl))
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

    /// Binary CRC frame:
    /// - CRC16: ZPAD ZDLE ZBIN   + escaped(hdr) + escaped(crc16)
    /// - CRC32: ZPAD ZDLE ZBIN32 + escaped(hdr) + escaped(crc32)
    private func makeBinFrame(type: UInt8, p0: UInt8, p1: UInt8, p2: UInt8, p3: UInt8, useCRC32: Bool, escapeCtl: Bool = false) -> [UInt8] {
        let hdr: [UInt8] = [type, p0, p1, p2, p3]
        var out: [UInt8] = [ZPAD, ZDLE, useCRC32 ? ZBIN32 : ZBIN]
        for b in hdr { zdleAppend(b, to: &out, escapeCtl: escapeCtl) }
        if useCRC32 {
            let chk = crc32(hdr)
            // ZMODEM uses little-endian CRC32 in lrzsz
            zdleAppend(UInt8(chk & 0xFF),         to: &out, escapeCtl: escapeCtl)
            zdleAppend(UInt8((chk >> 8) & 0xFF),  to: &out, escapeCtl: escapeCtl)
            zdleAppend(UInt8((chk >> 16) & 0xFF), to: &out, escapeCtl: escapeCtl)
            zdleAppend(UInt8((chk >> 24) & 0xFF), to: &out, escapeCtl: escapeCtl)
        } else {
            let chk = crc16(hdr)
            zdleAppend(UInt8((chk >> 8) & 0xFF), to: &out, escapeCtl: escapeCtl)
            zdleAppend(UInt8(chk & 0xFF),        to: &out, escapeCtl: escapeCtl)
        }
        return out
    }

    /// Builds an escaped data subpacket (uses instance escape setting).
    private func makeDataSubpacket(_ data: [UInt8], terminator: UInt8) -> [UInt8] {
        buildDataSubpacket(data, terminator: terminator, escapeCtl: txEscapeCtl, useCRC32: txUseCRC32)
    }

    /// Builds an escaped data subpacket:
    /// ZDLE-escaped(data) + ZDLE + terminator + ZDLE-escaped(CRC(data+term))
    private func buildDataSubpacket(_ data: [UInt8], terminator: UInt8, escapeCtl: Bool, useCRC32: Bool) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(data.count + data.count / 8 + 8)
        for b in data { zdleAppend(b, to: &out, escapeCtl: escapeCtl) }
        out.append(ZDLE)
        out.append(terminator)
        if useCRC32 {
            let crc = crc32(data + [terminator])
            zdleAppend(UInt8(crc & 0xFF),          to: &out, escapeCtl: escapeCtl)
            zdleAppend(UInt8((crc >> 8) & 0xFF),   to: &out, escapeCtl: escapeCtl)
            zdleAppend(UInt8((crc >> 16) & 0xFF),  to: &out, escapeCtl: escapeCtl)
            zdleAppend(UInt8((crc >> 24) & 0xFF),  to: &out, escapeCtl: escapeCtl)
        } else {
            let crc = crc16(data + [terminator])
            zdleAppend(UInt8((crc >> 8) & 0xFF), to: &out, escapeCtl: escapeCtl)
            zdleAppend(UInt8(crc & 0xFF),        to: &out, escapeCtl: escapeCtl)
        }
        return out
    }

    /// ZDLE-escape a byte. When `escapeCtl` is true, escapes all control chars
    /// (0x00-0x1F and 0x80-0x9F) as required by `rz -e`.
    private func zdleAppend(_ b: UInt8, to buf: inout [UInt8], escapeCtl: Bool = false) {
        if shouldEscape(b, escapeCtl: escapeCtl) {
            buf.append(ZDLE); buf.append(b ^ 0x40)
        } else {
            buf.append(b)
        }
    }

    private func shouldEscape(_ b: UInt8, escapeCtl: Bool) -> Bool {
        switch b {
        case ZDLE, 0x10, 0x90, 0x11, 0x91, 0x13, 0x93:
            return true
        case 0x00...0x1F, 0x80...0x9F:
            return escapeCtl
        default:
            return false
        }
    }

    private func send(_ bytes: [UInt8]) { onSend?(bytes) }

    // MARK: - Abort

    private func abortSend(reason: String) {
        txSending = false
        let cancel: [UInt8] = Array(repeating: 0x18, count: 8) + [0x0D, 0x0D, 0x0D]
        send(cancel)
        onStatusChange?(reason)
        onTransferDone?()
        reset()
    }

    // MARK: - Send watchdog

    private func scheduleSendWatchdog(timeout: TimeInterval) {
        cancelSendWatchdog()
        let work = DispatchWorkItem { [weak self] in
            self?.handleSendTimeout()
        }
        sendWatchdog = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: work)
    }

    private func cancelSendWatchdog() {
        sendWatchdog?.cancel()
        sendWatchdog = nil
    }

    private func handleSendTimeout() {
        guard role == .sending else { return }

        switch sendPhase {
        case .waitingZRPOS:
            if sendRetryCount < 5 {
                sendRetryCount += 1
                onStatusChange?("ZMODEM: 等待接收端确认，重试 \(sendRetryCount)/5")
                sendNextFile(retrying: true)
            } else {
                abortSend(reason: "ZMODEM: 上传超时，已取消")
            }

        case .waitingZRINITOrZFIN:
            if sendRetryCount < 3 {
                sendRetryCount += 1
                onStatusChange?("ZMODEM: 等待接收端收尾，重试 \(sendRetryCount)/3")
                if txLastEOFSize > 0 {
                    sendEOF(size: txLastEOFSize)
                } else {
                    sendHex(ZFIN, p0: 0, p1: 0, p2: 0, p3: 0)
                }
                scheduleSendWatchdog(timeout: 5.0)
            } else {
                abortSend(reason: "ZMODEM: 上传超时，已取消")
            }

        case .idle, .streamingData:
            break
        }
    }

    // MARK: - Reset

    private func reset() {
        cancelSendWatchdog()
        txSending = false
        role = .idle; phase = .idle; frameType = 0; binHdrNeeded = 7
        sendPhase = .idle; sendRetryCount = 0; txEscapeCtl = false; txUseCRC32 = false
        rxData = Data(); rxName = ""; rxSize = 0; rxOffset = 0
        txFiles = []; txIndex = 0; txOffset = 0; txLastEOFSize = 0
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
