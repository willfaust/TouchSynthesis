import Foundation

/// Represents a single DTX channel within a connection.
/// Channels multiplex different services over one TCP connection.
class DTXChannel {
    let code: Int32
    let identifier: String
    weak var connection: DTXConnection?

    /// Handler for incoming messages on this channel (e.g., callbacks from testmanagerd)
    var messageHandler: ((DTXMessage) -> Void)?

    init(code: Int32, identifier: String, connection: DTXConnection) {
        self.code = code
        self.identifier = identifier
        self.connection = connection
    }

    /// Invoke a remote method and wait for the response
    func invoke(selector: String, arguments: [Any] = [], expectsReply: Bool = true) async throws -> DTXMessage? {
        guard let conn = connection else {
            throw DTXError.channelError("Channel \(code) has no connection")
        }

        let msg = DTXMessage.methodInvocation(
            selector: selector,
            arguments: arguments,
            channel: code,
            identifier: conn.nextMessageID(),
            expectsReply: expectsReply
        )

        if expectsReply {
            return try await conn.sendAndWaitForReply(msg)
        } else {
            try await conn.send(msg)
            return nil
        }
    }

    /// Send a reply to an incoming message
    func reply(to request: DTXMessage, returnValue: Any? = nil) async throws {
        guard let conn = connection else {
            throw DTXError.channelError("Channel \(code) has no connection")
        }

        let msg = DTXMessage.reply(to: request, returnValue: returnValue)
        try await conn.send(msg)
    }

    /// Dispatch an incoming message to the handler
    func dispatchIncoming(_ message: DTXMessage) {
        messageHandler?(message)
    }
}
