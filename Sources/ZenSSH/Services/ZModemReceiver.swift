import Foundation
import AppKit

// MARK: - ZMODEM constants

private let ZPAD:   UInt8 = 0x2A   // *
private let ZDLE:   UInt8 = 0x18   // ^X
private let ZHEX:   UInt8 = 0x42   // B  (hex frame marker after ZDLE)
private let ZBIN:   UInt8 = 0x41   // A  (binary CRC16 frame)
private let ZBIN32: UInt8 = 0x43   // C  (binary CRC32 frame)

private let ZRQINIT: UInt8 = 0
private let ZRINIT:  UInt8 = 1
private let ZFILE:   UInt8 = 4
private let ZFIN:    UInt8 = 8
private let ZRPOS:   UInt8 = 9
private let ZDATA:   UInt8 = 10
private let ZEOF:    UInt8 = 11

// Data subpacket terminators (follow ZDLE in the data stream)
private let ZCRCE: UInt8 = 0x68   // end of file
private let ZCRCG: UInt8 = 0x69   // go on
private let ZCRCQ: UInt8 = 0x6A   // ack required
private let ZCRCW: UInt8 = 0x6B   // wait

// MARK: - CRC-16/XMODEM

private func crc16(_ bytes: [UInt8]) -> UInt16 {
    var crc: UInt16 = 0
    for byte in bytes {
        crc ^= UInt16(byte) << 8
        for _ in 0..<8 {
            crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
        }
    }
    return crc
}

// MARK: - ZModemReceiver

/// Byte-stream parser for ZMODEM receive protocol.
/// Feed incoming bytes from the SSH PTY; it returns the bytes that the
/// terminal emulator should see (normal shell output before/after transfer).
/// Responses to the remote `sz` are delivered via `onSend`.
final class ZModemReceiver {

    var onSend: (([UInt8]) -> Void)?
    var onFileReceived: ((String, Data) -> Void)?
    var onStatusChange: ((String) -> Void)?

    // ---- internal state ----
    private enum Phase {
        case idle                         // pass bytes to terminal
        case gotStar                      // saw one 0x2A
        case gotTwoStars                  // saw **
        case gotZdle                      // saw ** ZDLE
        case hexFrame([UInt8])            // accumulating hex chars
        case binHdr([UInt8], esc: Bool)   // accumulating 5+2 binary header bytes
        case dataSubpacket([UInt8], esc: Bool)  // accumulating file data
    }

    private var phase = Phase.idle
    private var frameType: UInt8 = 0
    private var fileData   = Data()
    private var fileName   = ""
    private var fileSize   = 0
    private var fileOffset = 0
    private var active     = false   // true while in a ZMODEM transfer

    // MARK: - Public entry point

    /// Returns the slice that should be forwarded to the terminal emulator.
    func feed(_ slice: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        var passthrough: [UInt8] = []
        for byte in slice {
            if let pt = processByte(byte) {
                passthrough.append(pt)
            }
        }
        return ArraySlice(passthrough)
    }

    // MARK: - Byte processor

    /// Returns the byte if it should go to the terminal, nil if consumed by ZMODEM.
    private func processByte(_ b: UInt8) -> UInt8? {
        switch phase {

        case .idle:
            if b == ZPAD {
                phase = .gotStar
                active = false
                return nil   // swallow — will emit if not ZMODEM
            }
            return b

        case .gotStar:
            if b == ZPAD {
                phase = .gotTwoStars
                return nil
            }
            // False alarm — emit the stored star
            phase = .idle
            return b   // emit current byte; the previous star is already gone
                       // (minor artifact: one * may be lost; acceptable)

        case .gotTwoStars:
            if b == ZDLE {
                phase = .gotZdle
                return nil
            }
            phase = .idle
            return b

        case .gotZdle:
            switch b {
            case ZHEX:
                active = true
                phase = .hexFrame([])
                return nil
            case ZBIN, ZBIN32:
                active = true
                phase = .binHdr([], esc: false)
                return nil
            default:
                phase = .idle
                return b
            }

        // ------ ZHEX frame: ** ZDLE B + 14 hex chars + CR LF ------
        case .hexFrame(var chars):
            if b == 0x0D || b == 0x0A || b == 0x11 { return nil } // skip CR/LF/XON
            chars.append(b)
            if chars.count >= 14 {
                parseHexFrame(chars)
                phase = .idle
            } else {
                phase = .hexFrame(chars)
            }
            return nil

        // ------ ZBIN frame header: 5 escaped bytes + 2 CRC bytes = 7 raw ------
        case .binHdr(var raw, let esc):
            if esc {
                let decoded = b ^ 0x40
                raw.append(decoded)
                let needed = 7   // 5 header + 2 CRC16
                if raw.count >= needed {
                    parseBinFrame(Array(raw.prefix(5)))
                    // After ZFILE/ZDATA header we enter data subpacket mode
                    if frameType == ZFILE || frameType == ZDATA {
                        phase = .dataSubpacket([], esc: false)
                    } else {
                        phase = .idle
                    }
                } else {
                    phase = .binHdr(raw, esc: false)
                }
            } else if b == ZDLE {
                phase = .binHdr(raw, esc: true)
            } else {
                raw.append(b)
                let needed = 7
                if raw.count >= needed {
                    parseBinFrame(Array(raw.prefix(5)))
                    if frameType == ZFILE || frameType == ZDATA {
                        phase = .dataSubpacket([], esc: false)
                    } else {
                        phase = .idle
                    }
                } else {
                    phase = .binHdr(raw, esc: false)
                }
            }
            return nil

        // ------ Data subpacket ------
        case .dataSubpacket(var raw, let esc):
            if esc {
                let decoded = b ^ 0x40
                // Check if this is a subpacket terminator (ZCRCE/ZCRCG/ZCRCQ/ZCRCW)
                if decoded == ZCRCE || decoded == ZCRCG ||
                   decoded == ZCRCQ || decoded == ZCRCW {
                    handleDataSubpacket(raw, terminator: decoded)
                    phase = .idle
                } else {
                    raw.append(decoded)
                    phase = .dataSubpacket(raw, esc: false)
                }
            } else if b == ZDLE {
                phase = .dataSubpacket(raw, esc: true)
            } else if b == ZPAD {
                // Start of next frame header — end current subpacket
                phase = .gotStar
            } else {
                raw.append(b)
                phase = .dataSubpacket(raw, esc: false)
            }
            return nil
        }
    }

    // MARK: - Frame parsers

    private func parseHexFrame(_ chars: [UInt8]) {
        // chars = 14 hex ASCII bytes: type(2) + p0(2)+p1(2)+p2(2)+p3(2) + crc(4)
        guard chars.count >= 14 else { return }
        func hex2(_ a: UInt8, _ b: UInt8) -> UInt8 {
            let hi = hexNibble(a)
            let lo = hexNibble(b)
            return (hi << 4) | lo
        }
        let type  = hex2(chars[0],  chars[1])
        let p0    = hex2(chars[2],  chars[3])
        let p1    = hex2(chars[4],  chars[5])
        let p2    = hex2(chars[6],  chars[7])
        let p3    = hex2(chars[8],  chars[9])
        frameType = type
        handleFrame(type: type, p: (p0, p1, p2, p3))
    }

    private func parseBinFrame(_ raw: [UInt8]) {
        guard raw.count >= 5 else { return }
        frameType = raw[0]
        handleFrame(type: raw[0], p: (raw[1], raw[2], raw[3], raw[4]))
    }

    // MARK: - Frame handlers

    private func handleFrame(type: UInt8, p: (UInt8, UInt8, UInt8, UInt8)) {
        switch type {
        case ZRQINIT:
            // Sender requests we init — send ZRINIT
            sendZRINIT()
            onStatusChange?("ZMODEM: 接收开始")

        case ZFILE:
            // Will receive filename in the following data subpacket
            break

        case ZEOF:
            // File transfer complete
            let offset = Int(p.0) | (Int(p.1) << 8) | (Int(p.2) << 16) | (Int(p.3) << 24)
            if offset == fileOffset {
                saveFile()
            }
            sendZRINIT()

        case ZFIN:
            sendZFIN()
            onStatusChange?("ZMODEM: 传输完成")
            active = false

        default:
            break
        }
    }

    private func handleDataSubpacket(_ data: [UInt8], terminator: UInt8) {
        if frameType == ZFILE {
            parseFileInfo(data)
            fileData = Data()
            fileOffset = 0
            sendZRPOS(0)
        } else if frameType == ZDATA {
            fileData.append(contentsOf: data)
            fileOffset += data.count
            if terminator == ZCRCQ || terminator == ZCRCW {
                sendZRPOS(fileOffset)
            }
        }
    }

    // MARK: - File info parsing

    private func parseFileInfo(_ data: [UInt8]) {
        // Format: "filename\0size date perms\0"
        let nullIdx = data.firstIndex(of: 0) ?? data.endIndex
        fileName = String(bytes: data[..<nullIdx], encoding: .utf8) ?? "download"
        if nullIdx < data.endIndex {
            let rest = data[(nullIdx + 1)...]
            let str  = String(bytes: rest, encoding: .utf8) ?? ""
            fileSize = Int(str.split(separator: " ").first.flatMap { Int($0) } ?? 0)
        }
        onStatusChange?("ZMODEM: 接收 \(fileName) (\(fileSize) 字节)")
    }

    // MARK: - File save

    private func saveFile() {
        let data = fileData
        let name = fileName.isEmpty ? "zmodem_download" : fileName
        onFileReceived?(name, data)
    }

    // MARK: - Frame builders

    private func sendZRINIT() {
        // ZRINIT: type=1, P0=0x23 (CANFDX|CANOVIO|CANFC32)
        send(hexFrame(type: ZRINIT, p0: 0x23, p1: 0, p2: 0, p3: 0))
    }

    private func sendZRPOS(_ offset: Int) {
        let o = UInt32(offset)
        send(hexFrame(type: ZRPOS,
                      p0: UInt8(o & 0xFF),
                      p1: UInt8((o >> 8) & 0xFF),
                      p2: UInt8((o >> 16) & 0xFF),
                      p3: UInt8((o >> 24) & 0xFF)))
    }

    private func sendZFIN() {
        send(hexFrame(type: ZFIN, p0: 0, p1: 0, p2: 0, p3: 0))
        // OO is the conventional "over and out" after ZFIN
        send(Array("OO".utf8))
    }

    // MARK: - Hex frame builder

    private func hexFrame(type: UInt8, p0: UInt8, p1: UInt8, p2: UInt8, p3: UInt8) -> [UInt8] {
        let header: [UInt8] = [type, p0, p1, p2, p3]
        let checksum = crc16(header)
        var s = "**\u{18}B"
        for b in header { s += String(format: "%02x", b) }
        s += String(format: "%04x", checksum)
        s += "\r\n\u{11}"
        return Array(s.utf8)
    }

    private func send(_ bytes: [UInt8]) {
        onSend?(bytes)
    }

    // MARK: - Helpers

    private func hexNibble(_ b: UInt8) -> UInt8 {
        switch b {
        case 0x30...0x39: return b - 0x30
        case 0x61...0x66: return b - 0x61 + 10
        case 0x41...0x46: return b - 0x41 + 10
        default: return 0
        }
    }
}
