import AppKit
import Foundation
import Citadel
import NIOCore
import NIOPosix
import NIOSSH
import SwiftTerm
import Crypto

// MARK: - Thread-safe callback holder
// Marked @unchecked Sendable: we guarantee all accesses to terminalView
// happen on the main thread via DispatchQueue.main.async.

private final class TerminalCallbacks: @unchecked Sendable {
    weak var view: SshTerminalView?
    var onDisconnect: (() -> Void)?          // always called on main thread

    func feedBytes(_ bytes: [UInt8]) {
        DispatchQueue.main.async { [weak self] in
            self?.view?.feed(byteArray: ArraySlice(bytes))
        }
    }
    func feedText(_ text: String) {
        DispatchQueue.main.async { [weak self] in self?.view?.feed(text: text) }
    }
    func disconnect() {
        DispatchQueue.main.async { [weak self] in
            self?.onDisconnect?()
        }
    }
}

// MARK: - Host key validator (accept all, same as SFTP service)

private final class AcceptAllHostKeys: NIOSSHClientServerAuthenticationDelegate,
                                        @unchecked Sendable {
    func validateHostKey(hostKey: NIOSSHPublicKey,
                         validationCompletePromise: EventLoopPromise<Void>) {
        validationCompletePromise.succeed(())
    }
}

// MARK: - NIO error handler

private final class SSHErrorHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any
    private let onError: (Error) -> Void
    init(onError: @escaping (Error) -> Void) { self.onError = onError }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        onError(error); context.close(promise: nil)
    }
}

// MARK: - Shell channel handler (PTY request → shell → data bridge)

private final class SSHShellChannelHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn   = SSHChannelData
    typealias InboundOut  = SSHChannelData
    typealias OutboundIn  = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let callbacks: TerminalCallbacks
    private let initialSize: (cols: Int, rows: Int)

    init(callbacks: TerminalCallbacks, initialSize: (cols: Int, rows: Int)) {
        self.callbacks   = callbacks
        self.initialSize = initialSize
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .whenFailure { _ in }
    }

    func channelActive(context: ChannelHandlerContext) {
        context.triggerUserOutboundEvent(
            SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: false,
                term: "xterm-256color",
                terminalCharacterWidth: initialSize.cols,
                terminalRowHeight:      initialSize.rows,
                terminalPixelWidth:  0,
                terminalPixelHeight: 0,
                terminalModes: SSHTerminalModes([:])
            ),
            promise: nil
        )
        context.triggerUserOutboundEvent(
            SSHChannelRequestEvent.ShellRequest(wantReply: false),
            promise: nil
        )
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = unwrapInboundIn(data)
        guard case .byteBuffer(var buf) = payload.data,
              let bytes = buf.readBytes(length: buf.readableBytes),
              !bytes.isEmpty else { return }

        let chunkSize = 1024
        var offset = 0
        while offset < bytes.count {
            let chunk = Array(bytes[offset..<min(offset + chunkSize, bytes.count)])
            callbacks.feedBytes(chunk)
            offset += chunk.count
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let s as SSHChannelRequestEvent.ExitStatus:
            callbacks.feedText("\r\n[Session closed: exit \(s.exitStatus)]\r\n")
            callbacks.disconnect()
        case let s as SSHChannelRequestEvent.ExitSignal:
            callbacks.feedText("\r\n[Session closed: signal \(s.signalName)]\r\n")
            callbacks.disconnect()
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        callbacks.disconnect()
    }
}

// MARK: - Low-level SSH connection (wraps NIO bootstrap)

private final class SSHConnection: @unchecked Sendable {
    private let server: Server
    private let password: String?
    private let callbacks: TerminalCallbacks

    private var group: MultiThreadedEventLoopGroup?
    private var transportChannel: Channel?
    var sessionChannel: Channel?

    init(server: Server, password: String?, callbacks: TerminalCallbacks) {
        self.server     = server
        self.password   = password
        self.callbacks  = callbacks
    }

    func connect(initialCols: Int, initialRows: Int) {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group
        let cb = callbacks

        ClientBootstrap(group: group)
            .channelInitializer { [weak self] channel in
                guard let self else {
                    return channel.eventLoop.makeFailedFuture(CancellationError())
                }
                let sshHandler = NIOSSHHandler(
                    role: .client(.init(
                        userAuthDelegate:   self.buildAuthDelegate(),
                        serverAuthDelegate: AcceptAllHostKeys()
                    )),
                    allocator: channel.allocator,
                    inboundChildChannelInitializer: nil
                )
                let errHandler = SSHErrorHandler { err in
                    cb.feedText("\r\n[Connection error: \(err.localizedDescription)]\r\n")
                    cb.disconnect()
                }
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandlers(sshHandler, errHandler)
                }
            }
            .channelOption(ChannelOptions.socket(SOL_SOCKET,  SO_REUSEADDR), value: 1)
            .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY),  value: 1)
            .connect(host: server.host, port: server.port)
            .whenComplete { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let err):
                    cb.feedText("\r\n[SSH connect failed: \(err.localizedDescription)]\r\n")
                    cb.disconnect()
                    self.shutdown()
                case .success(let ch):
                    self.transportChannel = ch
                    self.openShellChannel(on: ch, cols: initialCols, rows: initialRows)
                }
            }
    }

    func send(_ data: Data) {
        guard let ch = sessionChannel else { return }
        ch.eventLoop.execute {
            var buf = ch.allocator.buffer(capacity: data.count)
            buf.writeBytes(data)
            ch.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buf)),
                             promise: nil)
        }
    }

    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0, let ch = sessionChannel else { return }
        ch.eventLoop.execute {
            ch.triggerUserOutboundEvent(
                SSHChannelRequestEvent.WindowChangeRequest(
                    terminalCharacterWidth: cols,
                    terminalRowHeight:      rows,
                    terminalPixelWidth: 0, terminalPixelHeight: 0
                ),
                promise: nil
            )
        }
    }

    func disconnect() {
        transportChannel?.close(promise: nil)
        shutdown()
    }

    // MARK: Private

    private func openShellChannel(on channel: Channel, cols: Int, rows: Int) {
        let cb = callbacks
        channel.pipeline.handler(type: NIOSSHHandler.self)
            .whenComplete { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let err):
                    cb.feedText("\r\n[SSH handler error: \(err.localizedDescription)]\r\n")
                case .success(let sshHandler):
                    let promise = channel.eventLoop.makePromise(of: Channel.self)
                    sshHandler.createChannel(promise, channelType: .session) { child, type in
                        guard type == .session else {
                            return channel.eventLoop.makeFailedFuture(
                                SSHTerminalError.invalidChannelType
                            )
                        }
                        return child.eventLoop.makeCompletedFuture {
                            try child.pipeline.syncOperations.addHandlers(
                                SSHShellChannelHandler(
                                    callbacks: cb,
                                    initialSize: (cols: max(cols, 1), rows: max(rows, 1))
                                ),
                                SSHErrorHandler { err in
                                    cb.feedText("\r\n[Channel error: \(err.localizedDescription)]\r\n")
                                }
                            )
                        }
                    }
                    promise.futureResult.whenComplete { [weak self] result in
                        switch result {
                        case .success(let ch): self?.sessionChannel = ch
                        case .failure(let err):
                            cb.feedText("\r\n[Shell channel error: \(err.localizedDescription)]\r\n")
                        }
                    }
                }
            }
    }

    private func buildAuthDelegate() -> NIOSSHClientUserAuthenticationDelegate {
        switch server.authType {
        case .password:
            return SSHAuthenticationMethod.passwordBased(username: server.username,
                                                         password: password ?? "")
        case .privateKey:
            return buildKeyDelegate()
        case .sshAgent:
            return SSHAuthenticationMethod.passwordBased(username: server.username,
                                                         password: password ?? "")
        }
    }

    private func buildKeyDelegate() -> NIOSSHClientUserAuthenticationDelegate {
        let path = server.privateKeyPath
        guard !path.isEmpty,
              let pem = try? String(contentsOfFile: path, encoding: .utf8) else {
            return SSHAuthenticationMethod.passwordBased(username: server.username,
                                                         password: password ?? "")
        }
        if let key = try? Curve25519.Signing.PrivateKey(sshEd25519: pem) {
            return SSHAuthenticationMethod.ed25519(username: server.username, privateKey: key)
        }
        if let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) {
            return SSHAuthenticationMethod.p256(username: server.username, privateKey: key)
        }
        return SSHAuthenticationMethod.passwordBased(username: server.username,
                                                     password: password ?? "")
    }

    private func shutdown() {
        if let g = group { group = nil; g.shutdownGracefully { _ in } }
    }
}

private enum SSHTerminalError: Error { case invalidChannelType }

// MARK: - SshTerminalView (macOS TerminalView + SSH backend)

/// A SwiftTerm `TerminalView` that connects directly over SSH via NIO (no spawn/expect).
/// Drop-in replacement for `LocalProcessTerminalView` for password and private-key auth.
final class SshTerminalView: TerminalView, @preconcurrency TerminalViewDelegate {

    private var connection: SSHConnection?
    private let cbs = TerminalCallbacks()

    var onDisconnect: (() -> Void)? {
        get { cbs.onDisconnect }
        set { cbs.onDisconnect = newValue }
    }
    var onTitleChange: ((String) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        cbs.view = self
        terminalDelegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        nonisolated(unsafe) let conn = connection
        conn?.disconnect()
    }

    // MARK: Public API

    func startSSH(server: Server, password: String?) {
        connection?.disconnect()
        let t = getTerminal()
        let conn = SSHConnection(server: server, password: password, callbacks: cbs)
        connection = conn
        conn.connect(initialCols: max(t.cols, 80), initialRows: max(t.rows, 24))
    }

    func closeSSH() {
        connection?.disconnect()
        connection = nil
    }

    // MARK: TerminalViewDelegate

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        connection?.resize(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        onTitleChange?(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        connection?.send(Data(data))
    }

    func scrolled(source: TerminalView, position: Double) {}

    func clipboardCopy(source: TerminalView, content: Data) {
        if let str = String(data: content, encoding: .utf8) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(str, forType: .string)
        }
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
