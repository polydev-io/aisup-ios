import Foundation
import Combine

// MARK: - Configuration

public struct AISUPConfig: Sendable {
    public let apiKey: String
    public let apiUrl: String
    public let wsUrl: String
    public var userName: String
    
    public init(
        apiKey: String,
        apiUrl: String,
        wsUrl: String? = nil,
        userName: String = "Guest"
    ) {
        self.apiKey = apiKey
        self.apiUrl = apiUrl
        self.wsUrl = wsUrl ?? apiUrl
        self.userName = userName
    }
}

// MARK: - Message

public struct Message: Codable, Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let chat: String
    public let content: String
    public let sender: MessageSender
    public let senderName: String?
    public let attachments: [Attachment]?
    public let createdAt: Date
    public let updatedAt: Date
    
    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case chat, content, sender, senderName, attachments, createdAt, updatedAt
    }
    
    public static func == (lhs: Message, rhs: Message) -> Bool {
        lhs.id == rhs.id
    }
}

public enum MessageSender: String, Codable, Sendable {
    case user
    case bot
    case `operator`
}

// MARK: - Attachment

public struct Attachment: Codable, Equatable, Hashable, Sendable {
    public let type: AttachmentType
    public let url: String
    public let name: String
    public let size: Int?
    public let mimeType: String?
}

public enum AttachmentType: String, Codable, Sendable {
    case image
    case video
    case file
}

// MARK: - Chat

public struct Chat: Codable, Identifiable, Sendable {
    public let id: String
    public let chatId: String
    public let platform: String
    public let status: ChatStatus
    public let mode: ChatMode
    public let userName: String?
    public let createdAt: Date
    public let updatedAt: Date
    
    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case chatId, platform, status, mode, userName, createdAt, updatedAt
    }
}

public enum ChatStatus: String, Codable, Sendable {
    case active
    case closed
    case pending
}

public enum ChatMode: String, Codable, Sendable {
    case bot
    case `operator`
}

// MARK: - API Responses

public struct InitResponse: Codable {
    public let success: Bool
    public let chatId: String
    public let chat: Chat
    public let welcomeMessage: String?
}

public struct SendMessageResponse: Codable {
    public let success: Bool
    public let message: Message
}

public struct MessagesResponse: Codable {
    public let success: Bool
    public let messages: [Message]
    public let hasMore: Bool
}

public struct UploadResponse: Codable {
    public let success: Bool
    public let attachment: Attachment
}

// MARK: - Connection Status

public enum ConnectionStatus: String, Sendable {
    case disconnected
    case connecting
    case connected
    case error
}

// MARK: - Errors

public enum AISUPError: Error, LocalizedError {
    case notInitialized
    case networkError(Error)
    case invalidResponse
    case serverError(String)
    case socketError(String)
    
    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "Chat not initialized. Call init() first."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .invalidResponse:
            return "Invalid response from server"
        case .serverError(let message):
            return "Server error: \(message)"
        case .socketError(let message):
            return "Socket error: \(message)"
        }
    }
}
