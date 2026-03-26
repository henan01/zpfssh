import AppKit
import SwiftTerm

/// `LocalProcessTerminalView` subclass that intercepts the PTY byte stream,
/// detects an incoming ZMODEM transfer (`sz` on the remote), receives the file,
/// and saves it to ~/Downloads — all transparently through the existing SSH PTY.
final class ZModemTerminalView: LocalProcessTerminalView {

    private let zmodem = ZModemReceiver()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupZModem()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    // MARK: - Override data path

    override func dataReceived(slice: ArraySlice<UInt8>) {
        let passthrough = zmodem.feed(slice)
        if !passthrough.isEmpty {
            super.dataReceived(slice: passthrough)
        }
    }

    // MARK: - Setup

    private func setupZModem() {
        // Send ZMODEM responses back through the SSH process stdin
        zmodem.onSend = { [weak self] bytes in
            self?.process.send(data: ArraySlice(bytes))
        }

        // When a file is fully received, save to ~/Downloads
        zmodem.onFileReceived = { name, data in
            DispatchQueue.main.async {
                let downloads = FileManager.default.urls(
                    for: .downloadsDirectory, in: .userDomainMask
                ).first ?? URL(fileURLWithPath: NSHomeDirectory())

                var dest = downloads.appendingPathComponent(name)
                // Avoid overwriting existing files
                var counter = 1
                let base = dest.deletingPathExtension().lastPathComponent
                let ext  = dest.pathExtension
                while FileManager.default.fileExists(atPath: dest.path) {
                    let newName = ext.isEmpty ? "\(base)_\(counter)" : "\(base)_\(counter).\(ext)"
                    dest = downloads.appendingPathComponent(newName)
                    counter += 1
                }

                do {
                    try data.write(to: dest)
                    // Brief Finder reveal so the user knows where the file landed
                    NSWorkspace.shared.activateFileViewerSelecting([dest])
                } catch {
                    // Show an alert on failure
                    let alert = NSAlert()
                    alert.messageText = "ZMODEM 接收失败"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }

        zmodem.onStatusChange = { [weak self] msg in
            DispatchQueue.main.async {
                // Display status as a short message in the terminal
                self?.feed(text: "\r\n\u{1B}[32m[\(msg)]\u{1B}[0m\r\n")
            }
        }
    }
}
