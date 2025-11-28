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
    public let role: MessageRole
    public let type: MessageType
    public let caption: String?
    public let createdAt: Date
    public let updatedAt: Date
    
    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case chat, content, role, type, caption, createdAt, updatedAt
    }
    
    public init(
        id: String,
        chat: String,
        content: String,
        role: MessageRole,
        type: MessageType = .text,
        caption: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.chat = chat
        self.content = content
        self.role = role
        self.type = type
        self.caption = caption
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
    
    /// Convenience property for UI
    public var sender: MessageRole { role }
    
    public static func == (lhs: Message, rhs: Message) -> Bool {
        lhs.id == rhs.id
    }
}

public enum MessageRole: String, Codable, Sendable {
    case user
    case bot
    case admin
}

public enum MessageType: String, Codable, Sendable {
    case text
    case photo
    case file
    case audio
    case video
    case videoNote = "video_note"
    case voice
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
    public let response: String
    public let message: String
    public let data: InitResponseData
    
    public var chatId: String { data.chatId }
    public var startMessage: String { data.startMessage }
}

public struct InitResponseData: Codable {
    public let chatId: String
    public let startMessage: String
}

public struct SendMessageResponse: Codable {
    public let response: String
    public let message: String
}

public struct MessagesResponse: Codable {
    public let response: String
    public let message: String
    public let data: [Message]
    
    public var messages: [Message] { data }
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
