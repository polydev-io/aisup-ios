import XCTest
@testable import AISUPSDK

final class AISUPSDKTests: XCTestCase {
    
    // MARK: - Config Tests
    
    func testConfigInitialization() {
        let config = AISUPConfig(
            apiKey: "test-key",
            apiUrl: "https://api.test.com"
        )
        
        XCTAssertEqual(config.apiKey, "test-key")
        XCTAssertEqual(config.apiUrl, "https://api.test.com")
        XCTAssertEqual(config.wsUrl, "https://api.test.com")
        XCTAssertEqual(config.userName, "Guest")
    }
    
    func testConfigWithCustomWsUrl() {
        let config = AISUPConfig(
            apiKey: "test-key",
            apiUrl: "https://api.test.com",
            wsUrl: "wss://ws.test.com",
            userName: "John"
        )
        
        XCTAssertEqual(config.wsUrl, "wss://ws.test.com")
        XCTAssertEqual(config.userName, "John")
    }
    
    // MARK: - Model Tests
    
    func testMessageRoleEnum() {
        XCTAssertEqual(MessageRole.user.rawValue, "user")
        XCTAssertEqual(MessageRole.bot.rawValue, "bot")
        XCTAssertEqual(MessageRole.admin.rawValue, "admin")
    }
    
    func testMessageTypeEnum() {
        XCTAssertEqual(MessageType.text.rawValue, "text")
        XCTAssertEqual(MessageType.photo.rawValue, "photo")
        XCTAssertEqual(MessageType.file.rawValue, "file")
    }
    
    func testConnectionStatusEnum() {
        XCTAssertEqual(ConnectionStatus.disconnected.rawValue, "disconnected")
        XCTAssertEqual(ConnectionStatus.connecting.rawValue, "connecting")
        XCTAssertEqual(ConnectionStatus.connected.rawValue, "connected")
        XCTAssertEqual(ConnectionStatus.error.rawValue, "error")
    }
    
    func testChatStatusEnum() {
        XCTAssertEqual(ChatStatus.active.rawValue, "active")
        XCTAssertEqual(ChatStatus.closed.rawValue, "closed")
        XCTAssertEqual(ChatStatus.pending.rawValue, "pending")
    }
    
    func testChatModeEnum() {
        XCTAssertEqual(ChatMode.bot.rawValue, "bot")
        XCTAssertEqual(ChatMode.operator.rawValue, "operator")
    }
    
    func testAttachmentTypeEnum() {
        XCTAssertEqual(AttachmentType.image.rawValue, "image")
        XCTAssertEqual(AttachmentType.video.rawValue, "video")
        XCTAssertEqual(AttachmentType.file.rawValue, "file")
    }
    
    // MARK: - Error Tests
    
    func testErrorDescriptions() {
        XCTAssertNotNil(AISUPError.notInitialized.errorDescription)
        XCTAssertNotNil(AISUPError.invalidResponse.errorDescription)
        XCTAssertNotNil(AISUPError.serverError("test").errorDescription)
        XCTAssertNotNil(AISUPError.socketError("test").errorDescription)
    }
    
    // MARK: - SDK Initialization Tests
    
    @MainActor
    func testSDKInitialization() {
        let config = AISUPConfig(
            apiKey: "test-key",
            apiUrl: "https://api.test.com"
        )
        
        let sdk = AISUPSDK(config: config)
        
        XCTAssertFalse(sdk.isInitialized)
        XCTAssertFalse(sdk.isConnected)
        XCTAssertEqual(sdk.connectionStatus, .disconnected)
        XCTAssertTrue(sdk.messages.isEmpty)
        XCTAssertNil(sdk.chatId)
    }
    
    @MainActor
    func testSDKDefaultState() {
        let config = AISUPConfig(apiKey: "key", apiUrl: "https://test.com")
        let sdk = AISUPSDK(config: config)
        
        XCTAssertFalse(sdk.isTyping)
        XCTAssertNil(sdk.error)
    }
    
    // MARK: - JSON Decoding Tests
    
    func testMessageDecoding() throws {
        let json = """
        {
            "_id": "msg-123",
            "chat": "chat-123",
            "content": "Hello World",
            "role": "user",
            "type": "text",
            "createdAt": "2024-01-01T12:00:00Z",
            "updatedAt": "2024-01-01T12:00:00Z"
        }
        """
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        let data = json.data(using: .utf8)!
        let message = try decoder.decode(Message.self, from: data)
        
        XCTAssertEqual(message.id, "msg-123")
        XCTAssertEqual(message.content, "Hello World")
        XCTAssertEqual(message.role, .user)
        XCTAssertEqual(message.sender, .user) // computed property
        XCTAssertEqual(message.type, .text)
    }
    
    func testChatDecoding() throws {
        let json = """
        {
            "_id": "chat-123",
            "chatId": "ext-123",
            "platform": "ios",
            "status": "active",
            "mode": "bot",
            "userName": "John",
            "createdAt": "2024-01-01T12:00:00Z",
            "updatedAt": "2024-01-01T12:00:00Z"
        }
        """
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        let data = json.data(using: .utf8)!
        let chat = try decoder.decode(Chat.self, from: data)
        
        XCTAssertEqual(chat.id, "chat-123")
        XCTAssertEqual(chat.chatId, "ext-123")
        XCTAssertEqual(chat.status, .active)
        XCTAssertEqual(chat.mode, .bot)
    }
    
    func testAttachmentDecoding() throws {
        let json = """
        {
            "type": "image",
            "url": "https://example.com/image.jpg",
            "name": "photo.jpg",
            "size": 1024,
            "mimeType": "image/jpeg"
        }
        """
        
        let data = json.data(using: .utf8)!
        let attachment = try JSONDecoder().decode(Attachment.self, from: data)
        
        XCTAssertEqual(attachment.type, .image)
        XCTAssertEqual(attachment.name, "photo.jpg")
        XCTAssertEqual(attachment.size, 1024)
    }
    
    // MARK: - Sendable Conformance Tests
    
    func testConfigIsSendable() {
        let config = AISUPConfig(apiKey: "key", apiUrl: "https://test.com")
        
        Task {
            // This should compile if Sendable conformance is correct
            let _ = config.apiKey
        }
    }
    
    func testMessageIsSendable() throws {
        let json = """
        {
            "_id": "msg-123",
            "chat": "chat-123",
            "content": "Test",
            "role": "user",
            "type": "text",
            "createdAt": "2024-01-01T12:00:00Z",
            "updatedAt": "2024-01-01T12:00:00Z"
        }
        """
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        let data = json.data(using: .utf8)!
        let message = try decoder.decode(Message.self, from: data)
        
        Task {
            // This should compile if Sendable conformance is correct
            let _ = message.content
        }
    }
}
