import Foundation

#if canImport(Citadel) && canImport(NIOCore) && canImport(NIOPosix) && canImport(NIOSSH)
@preconcurrency import Citadel
import Crypto
import NIOCore
import NIOPosix
@preconcurrency import NIOSSH

final class CitadelSSHSessionDriver: SSHSessionDriver {
    private let eventStream: AsyncStream<SSHSessionEvent>
    private var eventContinuation: AsyncStream<SSHSessionEvent>.Continuation?
    private var group: EventLoopGroup?
    private var parentChannel: Channel?
    private var sessionChannel: Channel?

    var events: AsyncStream<SSHSessionEvent> {
        eventStream
    }

    init() {
        var continuation: AsyncStream<SSHSessionEvent>.Continuation?
        eventStream = AsyncStream { continuation = $0 }
        eventContinuation = continuation
    }

    func connect(config: SSHConnectionConfig) async throws {
        emit(.connecting)
        let handshakeHandler = SSHClientHandshakeHandler(loginTimeout: .seconds(30))
        let authDelegate: any NIOSSHClientUserAuthenticationDelegate
        do {
            switch config.auth {
            case .password(let password):
                authDelegate = SingleOfferAuthenticationDelegate(
                    username: config.username,
                    offer: .password(.init(password: password)),
                    requiredMethod: .password,
                    unsupportedError: .unsupported(
                        "Server does not offer SSH password auth. Use an SSH key; keyboard-interactive is not supported by this backend."
                    ),
                    rejectedError: .authenticationFailed,
                    onFailure: { [weak self, handshakeHandler] error in
                        handshakeHandler.failAuthentication(error)
                        self?.emit(.failed(error))
                    },
                    onStatus: { [weak self] status in
                        self?.emit(.status(status))
                    }
                )
                emit(.status("Prepared SSH password authentication."))
            case .privateKey(let privateKey, let passphrase):
                authDelegate = SingleOfferAuthenticationDelegate(
                    username: config.username,
                    offer: try SSHPrivateKeyAuthentication.offer(
                        privateKey: privateKey,
                        passphrase: passphrase
                    ),
                    requiredMethod: .publicKey,
                    unsupportedError: .unsupported("Server does not offer SSH public key auth."),
                    rejectedError: .unknown(
                        "SSH key authentication failed. Verify the host username, authorized_keys entry, key type, and passphrase."
                    ),
                    onFailure: { [weak self, handshakeHandler] error in
                        handshakeHandler.failAuthentication(error)
                        self?.emit(.failed(error))
                    },
                    onStatus: { [weak self] status in
                        self?.emit(.status(status))
                    }
                )
                emit(.status("Prepared SSH public key authentication."))
            }
        } catch {
            let mappedError = SSHSessionError.map(error)
            emit(.failed(mappedError))
            throw mappedError
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group

        emit(.authenticating)
        emit(.status("Opening TCP connection to \(config.host):\(config.port)."))
        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { [weak self] channel in
                let sshHandler = NIOSSHHandler(
                    role: .client(
                        SSHClientConfiguration(
                            userAuthDelegate: authDelegate,
                            serverAuthDelegate: HostKeyTrustStore.validator()
                        )
                    ),
                    allocator: channel.allocator,
                    inboundChildChannelInitializer: nil
                )
                return channel.pipeline.addHandler(sshHandler).flatMap {
                    channel.pipeline.addHandler(handshakeHandler)
                }.flatMap {
                    channel.pipeline.addHandler(SSHDriverErrorHandler { error in
                        self?.emit(.failed(SSHSessionError.map(error)))
                    })
                }
            }
            .connectTimeout(.seconds(30))
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)

        do {
            let channel = try await bootstrap.connect(host: config.host, port: config.port).get()
            parentChannel = channel
            emit(.status("TCP connected; waiting for SSH authentication."))
            channel.closeFuture.whenComplete { [weak self] _ in
                self?.emit(.disconnected(reason: nil))
                self?.shutdownGroup()
            }

            do {
                try await handshakeHandler.authenticated.get()
                emit(.status("SSH authentication succeeded."))
                emit(.connected)
            } catch {
                try? await channel.close().get()
                throw error
            }
        } catch {
            shutdownGroup()
            throw SSHSessionError.map(error)
        }
    }

    func startPTY(term: String, columns: Int, rows: Int) async throws {
        guard let parentChannel else {
            throw SSHSessionError.connectionFailed("SSH channel is not connected.")
        }

        do {
            emit(.status("Requesting remote PTY \(columns)x\(rows)."))
            let initialSize = (columns: max(columns, 1), rows: max(rows, 1))

            sessionChannel = try await parentChannel.eventLoop.flatSubmit { [weak self] in
                let promise = parentChannel.eventLoop.makePromise(of: Channel.self)
                return parentChannel.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler in
                    sshHandler.createChannel(promise, channelType: .session) { [weak self] childChannel, channelType in
                        guard channelType == .session else {
                            return childChannel.eventLoop.makeFailedFuture(SSHDriverChannelError.invalidChannelType)
                        }

                        return childChannel.pipeline.addHandler(
                            SSHPTYChannelHandler(
                                term: term,
                                environment: ["LANG": "en_US.UTF-8"],
                                initialSize: initialSize,
                                onEvent: { event in
                                    self?.emit(event)
                                }
                            )
                        ).flatMap {
                            childChannel.pipeline.addHandler(SSHDriverErrorHandler { error in
                                self?.emit(.failed(SSHSessionError.map(error)))
                            })
                        }
                    }
                    return promise.futureResult
                }
            }.get()
        } catch {
            throw SSHSessionError.ptyFailed(String(describing: error))
        }
    }

    func write(_ data: Data) async throws {
        guard let sessionChannel else {
            throw SSHSessionError.disconnected("PTY is not open.")
        }
        guard !data.isEmpty else { return }

        try await sessionChannel.eventLoop.flatSubmit {
            var buffer = sessionChannel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            let payload = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
            return sessionChannel.writeAndFlush(payload)
        }.get()
    }

    func resize(columns: Int, rows: Int) async throws {
        guard let sessionChannel else { return }
        let columns = max(columns, 1)
        let rows = max(rows, 1)

        try await sessionChannel.eventLoop.flatSubmit {
            let event = SSHChannelRequestEvent.WindowChangeRequest(
                terminalCharacterWidth: columns,
                terminalRowHeight: rows,
                terminalPixelWidth: 0,
                terminalPixelHeight: 0
            )
            return sessionChannel.triggerUserOutboundEvent(event)
        }.get()
        emit(.resized(columns: columns, rows: rows))
    }

    func disconnect() async {
        let child = sessionChannel
        let parent = parentChannel
        sessionChannel = nil
        parentChannel = nil

        if let child, child.isActive {
            try? await child.close().get()
        }
        if let parent, parent.isActive {
            try? await parent.close().get()
        } else {
            shutdownGroup()
        }
        emit(.disconnected(reason: "Closed by user"))
        eventContinuation?.finish()
    }

    private func emit(_ event: SSHSessionEvent) {
        eventContinuation?.yield(event)
    }

    private func shutdownGroup() {
        guard let group else { return }
        self.group = nil
        group.shutdownGracefully { _ in }
    }
}

private enum SSHDriverChannelError: Error {
    case invalidChannelType
}

private enum HostKeyTrustStore {
    static func validator() -> SSHHostKeyValidator {
        #if DEBUG
        .acceptAnything()
        #else
        .trustedKeys(Set<NIOSSHPublicKey>())
        #endif
    }
}

private enum SSHPrivateKeyAuthentication {
    static func offer(
        privateKey: String,
        passphrase: String?
    ) throws -> NIOSSHUserAuthenticationOffer.Offer {
        let privateKey = normalizeOpenSSHPrivateKey(privateKey)
        let envelope = try OpenSSHPrivateKeyEnvelope.parse(privateKey)
        if let envelope {
            guard ["none", "aes128-ctr", "aes256-ctr"].contains(envelope.cipherName) else {
                throw SSHSessionError.unsupported(
                    "Unsupported OpenSSH private key cipher '\(envelope.cipherName)'. Re-save the key with aes256-ctr: ssh-keygen -p -o -a 16 -Z aes256-ctr -f <keyfile>"
                )
            }
            guard ["none", "bcrypt"].contains(envelope.kdfName) else {
                throw SSHSessionError.unsupported(
                    "Unsupported OpenSSH private key KDF '\(envelope.kdfName)'. Re-save the key with OpenSSH bcrypt KDF."
                )
            }
            if let publicKeyType = envelope.publicKeyType,
               !["ssh-ed25519", "ssh-rsa"].contains(publicKeyType) {
                throw SSHSessionError.unsupported(
                    "Unsupported SSH private key type '\(publicKeyType)'. Use OpenSSH Ed25519 or RSA."
                )
            }
            if let bcryptRounds = envelope.bcryptRounds, bcryptRounds >= 32 {
                throw SSHSessionError.unsupported(
                    "Unsupported OpenSSH bcrypt KDF rounds \(bcryptRounds). Re-save the key with fewer rounds: ssh-keygen -p -o -a 16 -Z aes256-ctr -f <keyfile>"
                )
            }
        }

        let decryptionKey = passphrase
            .flatMap { $0.isEmpty ? nil : Data($0.utf8) }
        let isEncrypted = envelope.map { $0.cipherName != "none" } ?? false

        do {
            let ed25519Key = try Curve25519.Signing.PrivateKey(
                sshEd25519: privateKey,
                decryptionKey: decryptionKey
            )
            return .privateKey(.init(privateKey: .init(ed25519Key: ed25519Key)))
        } catch {
            if isEncrypted, decryptionKey == nil {
                throw SSHSessionError.unknown("SSH private key is encrypted. Enter the key passphrase.")
            }
        }

        do {
            let rsaKey = try Insecure.RSA.PrivateKey(
                sshRsa: privateKey,
                decryptionKey: decryptionKey
            )
            return .privateKey(.init(privateKey: .init(custom: rsaKey)))
        } catch {
            if isEncrypted {
                throw SSHSessionError.unknown("SSH private key could not be decrypted. Verify the key passphrase and pasted key content.")
            }
        }

        throw SSHSessionError.unsupported(
            "Unsupported SSH private key. Use an OpenSSH Ed25519 or RSA private key with the correct passphrase."
        )
    }

    private static func normalizeOpenSSHPrivateKey(_ privateKey: String) -> String {
        let begin = "-----BEGIN OPENSSH PRIVATE KEY-----"
        let end = "-----END OPENSSH PRIVATE KEY-----"
        var trimmed = privateKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("\\n"), !trimmed.contains("\n") {
            trimmed = trimmed.replacingOccurrences(of: "\\n", with: "\n")
        }

        guard trimmed.contains(begin), trimmed.contains(end) else {
            return trimmed
        }

        var body = trimmed
        body = body.replacingOccurrences(of: begin, with: "")
        body = body.replacingOccurrences(of: end, with: "")
        let base64Scalars = body.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }
        let base64 = String(String.UnicodeScalarView(base64Scalars))
        return "\(begin)\n\(base64)\n\(end)"
    }
}

private struct OpenSSHPrivateKeyEnvelope {
    let cipherName: String
    let kdfName: String
    let bcryptRounds: UInt32?
    let publicKeyType: String?

    static func parse(_ privateKey: String) throws -> OpenSSHPrivateKeyEnvelope? {
        let begin = "-----BEGIN OPENSSH PRIVATE KEY-----"
        let end = "-----END OPENSSH PRIVATE KEY-----"
        guard privateKey.contains(begin), privateKey.contains(end) else {
            return nil
        }

        var body = privateKey
        body = body.replacingOccurrences(of: begin, with: "")
        body = body.replacingOccurrences(of: end, with: "")
        let base64Scalars = body.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }
        let base64 = String(String.UnicodeScalarView(base64Scalars))

        guard let data = Data(base64Encoded: base64) else {
            throw SSHSessionError.unknown("SSH private key content is not valid OpenSSH base64. Re-paste the full private key.")
        }

        var reader = SSHBinaryReader(data: data)
        guard reader.readCString("openssh-key-v1") else {
            throw SSHSessionError.unsupported("Invalid OpenSSH private key envelope.")
        }
        let cipherName = try reader.readSSHString()
        let kdfName = try reader.readSSHString()
        let kdfOptions = try reader.readSSHData()
        let keyCount = try reader.readUInt32()
        let publicKeyType = try readPublicKeyType(from: &reader, keyCount: keyCount)
        let bcryptRounds = try readBCryptRounds(from: kdfOptions, kdfName: kdfName)
        return OpenSSHPrivateKeyEnvelope(
            cipherName: cipherName,
            kdfName: kdfName,
            bcryptRounds: bcryptRounds,
            publicKeyType: publicKeyType
        )
    }

    private static func readBCryptRounds(from kdfOptions: Data, kdfName: String) throws -> UInt32? {
        guard kdfName == "bcrypt" else {
            return nil
        }

        var reader = SSHBinaryReader(data: kdfOptions)
        _ = try reader.readSSHData()
        return try reader.readUInt32()
    }

    private static func readPublicKeyType(
        from reader: inout SSHBinaryReader,
        keyCount: UInt32
    ) throws -> String? {
        guard keyCount == 1 else {
            return nil
        }

        let publicKeyData = try reader.readSSHData()
        var publicKeyReader = SSHBinaryReader(data: publicKeyData)
        return try publicKeyReader.readSSHString()
    }
}

private struct SSHBinaryReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(data: Data) {
        bytes = Array(data)
    }

    mutating func readCString(_ value: String) -> Bool {
        let expected = Array(value.utf8) + [0]
        guard remaining >= expected.count else { return false }
        guard Array(bytes[offset..<(offset + expected.count)]) == expected else { return false }
        offset += expected.count
        return true
    }

    mutating func readSSHString() throws -> String {
        let data = try readSSHData()
        guard let value = String(data: data, encoding: .utf8) else {
            throw SSHSessionError.unsupported("Invalid OpenSSH private key envelope.")
        }
        return value
    }

    mutating func readSSHData() throws -> Data {
        let length = try readUInt32()
        guard remaining >= Int(length) else {
            throw SSHSessionError.unsupported("Invalid OpenSSH private key envelope.")
        }
        let data = Data(bytes[offset..<(offset + Int(length))])
        offset += Int(length)
        return data
    }

    mutating func readUInt32() throws -> UInt32 {
        guard remaining >= 4 else {
            throw SSHSessionError.unsupported("Invalid OpenSSH private key envelope.")
        }
        let value = bytes[offset..<(offset + 4)].reduce(UInt32(0)) { partialResult, byte in
            (partialResult << 8) | UInt32(byte)
        }
        offset += 4
        return value
    }

    private var remaining: Int {
        bytes.count - offset
    }
}

private nonisolated final class SingleOfferAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private let offer: NIOSSHUserAuthenticationOffer.Offer
    private let requiredMethod: NIOSSHAvailableUserAuthenticationMethods
    private let unsupportedError: SSHSessionError
    private let rejectedError: SSHSessionError
    private let onFailure: (SSHSessionError) -> Void
    private let onStatus: (String) -> Void
    private var didOffer = false
    private var didReportFailure = false

    init(
        username: String,
        offer: NIOSSHUserAuthenticationOffer.Offer,
        requiredMethod: NIOSSHAvailableUserAuthenticationMethods,
        unsupportedError: SSHSessionError,
        rejectedError: SSHSessionError,
        onFailure: @escaping (SSHSessionError) -> Void,
        onStatus: @escaping (String) -> Void
    ) {
        self.username = username
        self.offer = offer
        self.requiredMethod = requiredMethod
        self.unsupportedError = unsupportedError
        self.rejectedError = rejectedError
        self.onFailure = onFailure
        self.onStatus = onStatus
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        onStatus("SSH server offered auth methods: \(describeAuthenticationMethods(availableMethods)).")
        guard availableMethods.contains(requiredMethod) else {
            fail(unsupportedError, promise: nextChallengePromise)
            return
        }

        guard !didOffer else {
            onStatus("SSH authentication offer was rejected by the server.")
            fail(rejectedError, promise: nextChallengePromise)
            return
        }

        didOffer = true
        onStatus("Offering SSH authentication request.")
        nextChallengePromise.succeed(
            NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "",
                offer: offer
            )
        )
    }

    private func fail(
        _ error: SSHSessionError,
        promise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        if !didReportFailure {
            didReportFailure = true
            onFailure(error)
        }
        promise.fail(error)
    }
}

private nonisolated func describeAuthenticationMethods(_ methods: NIOSSHAvailableUserAuthenticationMethods) -> String {
    var names: [String] = []
    if methods.contains(.publicKey) {
        names.append("publickey")
    }
    if methods.contains(.password) {
        names.append("password")
    }
    if methods.contains(.hostBased) {
        names.append("hostbased")
    }
    return names.isEmpty ? "none" : names.joined(separator: ", ")
}

private nonisolated final class SSHClientHandshakeHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any

    private let loginTimeout: TimeAmount
    private var promise: EventLoopPromise<Void>?
    private var timeoutTask: Scheduled<Void>?
    private var completed = false

    var authenticated: EventLoopFuture<Void> {
        guard let promise else {
            preconditionFailure("SSHClientHandshakeHandler must be added before awaiting authentication.")
        }
        return promise.futureResult
    }

    init(loginTimeout: TimeAmount) {
        self.loginTimeout = loginTimeout
    }

    func handlerAdded(context: ChannelHandlerContext) {
        promise = context.eventLoop.makePromise(of: Void.self)
        timeoutTask = context.eventLoop.scheduleTask(in: loginTimeout) { [weak self, weak context] in
            guard let self else { return }
            self.complete(.failure(ChannelError.connectTimeout(self.loginTimeout)))
            context?.close(promise: nil)
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            complete(.success(()))
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        complete(.failure(error))
        context.fireErrorCaught(error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        complete(.failure(SSHSessionError.authenticationFailed))
        context.fireChannelInactive()
    }

    func failAuthentication(_ error: SSHSessionError) {
        complete(.failure(error))
    }

    private func complete(_ result: Result<Void, Error>) {
        guard !completed else { return }
        completed = true
        timeoutTask?.cancel()
        timeoutTask = nil

        switch result {
        case .success:
            promise?.succeed(())
        case .failure(let error):
            promise?.fail(error)
        }
    }
}

private nonisolated final class SSHDriverErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    private let onError: (Error) -> Void

    init(onError: @escaping (Error) -> Void) {
        self.onError = onError
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        onError(error)
        context.close(promise: nil)
    }
}

private nonisolated final class SSHPTYChannelHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private let term: String
    private let environment: [String: String]
    private let initialSize: (columns: Int, rows: Int)
    private let onEvent: (SSHSessionEvent) -> Void
    private var successfulStartupReplies = 0
    private var ptyStarted = false

    init(
        term: String,
        environment: [String: String],
        initialSize: (columns: Int, rows: Int),
        onEvent: @escaping (SSHSessionEvent) -> Void
    ) {
        self.term = term
        self.environment = environment
        self.initialSize = initialSize
        self.onEvent = onEvent
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { error in
            context.fireErrorCaught(error)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: term,
            terminalCharacterWidth: initialSize.columns,
            terminalRowHeight: initialSize.rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        context.triggerUserOutboundEvent(pty, promise: nil)

        for (name, value) in environment {
            let env = SSHChannelRequestEvent.EnvironmentRequest(wantReply: false, name: name, value: value)
            context.triggerUserOutboundEvent(env, promise: nil)
        }

        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: true), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = payload.data else { return }
        guard let bytes = buffer.readBytes(length: buffer.readableBytes), !bytes.isEmpty else { return }
        onEvent(.output(Data(bytes)))
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is ChannelSuccessEvent {
            successfulStartupReplies += 1
            onEvent(.status("Remote accepted PTY startup request \(successfulStartupReplies)/2."))
            if successfulStartupReplies >= 2, !ptyStarted {
                ptyStarted = true
                onEvent(.status("Remote PTY shell started."))
                onEvent(.ptyStarted)
            }
        } else if event is ChannelFailureEvent {
            onEvent(.status("Remote rejected PTY or shell request."))
            onEvent(.failed(.ptyFailed("Remote rejected PTY or shell request.")))
        } else if let status = event as? SSHChannelRequestEvent.ExitStatus {
            onEvent(.disconnected(reason: "Remote shell exited with status \(status.exitStatus)."))
        } else if let signal = event as? SSHChannelRequestEvent.ExitSignal {
            onEvent(.disconnected(reason: "Remote shell closed: \(signal.signalName)."))
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        onEvent(.disconnected(reason: nil))
    }
}

#elseif canImport(Citadel)
import Citadel

final class CitadelSSHSessionDriver: SSHSessionDriver {
    private let eventStream: AsyncStream<SSHSessionEvent>
    private var eventContinuation: AsyncStream<SSHSessionEvent>.Continuation?

    var events: AsyncStream<SSHSessionEvent> {
        eventStream
    }

    init() {
        var continuation: AsyncStream<SSHSessionEvent>.Continuation?
        eventStream = AsyncStream { continuation = $0 }
        eventContinuation = continuation
    }

    func connect(config: SSHConnectionConfig) async throws {
        throw SSHSessionError.unsupported("NIOSSH modules are unavailable in this target.")
    }

    func startPTY(term: String, columns: Int, rows: Int) async throws {}

    func write(_ data: Data) async throws {}

    func resize(columns: Int, rows: Int) async throws {}

    func disconnect() async {
        eventContinuation?.finish()
    }
}
#endif
