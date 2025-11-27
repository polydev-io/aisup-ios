import Foundation
import Combine
import SocketIO

// MARK: - Main SDK (ObservableObject for SwiftUI)

/// AISUP SDK - Main entry point
/// Supports SwiftUI with ObservableObject, Combine publishers, and async/await
@MainActor
public final class AISUPSDK: ObservableObject {
    
    // MARK: - Published Properties (SwiftUI reactive)
    
    @Published public private(set) var messages: [Message] = []
    @Published public private(set) var connectionStatus: ConnectionStatus = .disconnected
    @Published public private(set) var isTyping: Bool = false
    @Published public private(set) var chatId: String?
    @Published public private(set) var error: AISUPError?
    
    // MARK: - Combine Publishers
    
    /// Publisher for new messages (real-time)
    public var messagePublisher: AnyPublisher<Message, Never> {
        messageSubject.eraseToAnyPublisher()
    }
    
    /// Publisher for chat updates
    public var chatUpdatePublisher: AnyPublisher<Chat, Never> {
        chatUpdateSubject.eraseToAnyPublisher()
    }
    
    /// Publisher for connection status changes
    public var connectionPublisher: AnyPublisher<ConnectionStatus, Never> {
        $connectionStatus.eraseToAnyPublisher()
    }
    
    // MARK: - Private Properties
    
    private let config: AISUPConfig
    private let session: URLSession
    private let decoder: JSONDecoder
    
    private var manager: SocketManager?
    private var socket: SocketIOClient?
    
    private let messageSubject = PassthroughSubject<Message, Never>()
    private let chatUpdateSubject = PassthroughSubject<Chat, Never>()
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Computed Properties
    
    public var isInitialized: Bool { chatId != nil }
    public var isConnected: Bool { connectionStatus == .connected }
    
    // MARK: - Initialization
    
    public init(config: AISUPConfig) {
        self.config = config
        self.session = URLSession.shared
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }
    
    // MARK: - Public async/await API
    
    /// Start the chat session (init + connect + join)
    public func start() async throws {
        let response = try await initialize()
        
        // Load message history
        let messagesResponse = try await getMessages()
        self.messages = messagesResponse.messages
        
        // Connect socket
        await connect()
        
        // Wait for connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var completed = false
            
            let cancellable = $connectionStatus
                .dropFirst()
                .sink { [weak self] status in
                    guard !completed else { return }
                    
                    switch status {
                    case .connected:
                        completed = true
                        Task { [weak self] in
                            do {
                                try await self?.joinChat(response.chatId)
                                continuation.resume()
                            } catch {
                                continuation.resume(throwing: error)
                            }
                        }
                    case .error:
                        completed = true
                        continuation.resume(throwing: AISUPError.socketError("Connection failed"))
                    default:
                        break
                    }
                }
            
            // Store cancellable
            self.cancellables.insert(cancellable)
            
            // Timeout
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
                if !completed {
                    completed = true
                    continuation.resume(throwing: AISUPError.socketError("Connection timeout"))
                }
            }
        }
    }
    
    /// Initialize chat session
    @discardableResult
    public func initialize() async throws -> InitResponse {
        let url = URL(string: "\(config.apiUrl)/api/integration/init")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "X-API-Key")
        
        var body: [String: Any] = ["userName": config.userName]
        if let chatId = chatId {
            body["chatId"] = chatId
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        
        let result = try decoder.decode(InitResponse.self, from: data)
        self.chatId = result.chatId
        return result
    }
    
    /// Send a message
    @discardableResult
    public func sendMessage(_ content: String, attachments: [Attachment]? = nil) async throws -> Message {
        guard let chatId = chatId else {
            throw AISUPError.notInitialized
        }
        
        let url = URL(string: "\(config.apiUrl)/api/integration/send-message")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "X-API-Key")
        
        var body: [String: Any] = ["chatId": chatId, "content": content]
        if let attachments = attachments {
            let encoder = JSONEncoder()
            let attachmentsData = try encoder.encode(attachments)
            body["attachments"] = try JSONSerialization.jsonObject(with: attachmentsData)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        
        let result = try decoder.decode(SendMessageResponse.self, from: data)
        addMessage(result.message)
        return result.message
    }
    
    /// Get message history
    public func getMessages(limit: Int = 50, before: String? = nil) async throws -> MessagesResponse {
        guard let chatId = chatId else {
            throw AISUPError.notInitialized
        }
        
        var components = URLComponents(string: "\(config.apiUrl)/api/integration/messages")!
        components.queryItems = [
            URLQueryItem(name: "chatId", value: chatId),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        if let before = before {
            components.queryItems?.append(URLQueryItem(name: "before", value: before))
        }
        
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue(config.apiKey, forHTTPHeaderField: "X-API-Key")
        
        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        
        return try decoder.decode(MessagesResponse.self, from: data)
    }
    
    /// Upload a file
    public func uploadFile(_ fileData: Data, fileName: String, mimeType: String) async throws -> UploadResponse {
        guard let chatId = chatId else {
            throw AISUPError.notInitialized
        }
        
        let url = URL(string: "\(config.apiUrl)/api/integration/upload")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(config.apiKey, forHTTPHeaderField: "X-API-Key")
        
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"chatId\"\r\n\r\n\(chatId)\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        
        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        
        return try decoder.decode(UploadResponse.self, from: data)
    }
    
    /// Stop and disconnect
    public func stop() {
        socket?.disconnect()
        manager = nil
        socket = nil
        connectionStatus = .disconnected
    }
    
    // MARK: - AsyncStream for SwiftUI
    
    /// Stream of messages for use with SwiftUI's .task modifier
    public var messageStream: AsyncStream<Message> {
        AsyncStream { continuation in
            let cancellable = messageSubject.sink { message in
                continuation.yield(message)
            }
            
            continuation.onTermination = { _ in
                cancellable.cancel()
            }
        }
    }
    
    // MARK: - Private Socket Methods
    
    private func connect() async {
        connectionStatus = .connecting
        
        guard let url = URL(string: config.wsUrl) else {
            connectionStatus = .error
            error = AISUPError.socketError("Invalid WebSocket URL")
            return
        }
        
        manager = SocketManager(socketURL: url, config: [
            .log(false),
            .compress,
            .connectParams(["apiKey": config.apiKey]),
            .extraHeaders(["X-API-Key": config.apiKey])
        ])
        
        socket = manager?.defaultSocket
        setupSocketListeners()
        socket?.connect()
    }
    
    private func joinChat(_ chatId: String) async throws {
        guard let socket = socket, socket.status == .connected else {
            throw AISUPError.socketError("Socket not connected")
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            socket.emitWithAck("integration_join", ["chatId": chatId]).timingOut(after: 10) { data in
                if let response = data.first as? [String: Any],
                   let status = response["status"] as? String,
                   status == "ok" {
                    continuation.resume()
                } else {
                    let message = (data.first as? [String: Any])?["message"] as? String ?? "Failed to join"
                    continuation.resume(throwing: AISUPError.socketError(message))
                }
            }
        }
    }
    
    private func setupSocketListeners() {
        socket?.on(clientEvent: .connect) { [weak self] _, _ in
            Task { @MainActor in
                self?.connectionStatus = .connected
            }
        }
        
        socket?.on(clientEvent: .disconnect) { [weak self] _, _ in
            Task { @MainActor in
                self?.connectionStatus = .disconnected
            }
        }
        
        socket?.on(clientEvent: .error) { [weak self] data, _ in
            Task { @MainActor in
                self?.connectionStatus = .error
                self?.error = AISUPError.socketError(data.first as? String ?? "Unknown error")
            }
        }
        
        socket?.on("message_added") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let messageDict = dict["message"] as? [String: Any],
                  let jsonData = try? JSONSerialization.data(withJSONObject: messageDict),
                  let message = try? JSONDecoder().decode(Message.self, from: jsonData) else {
                return
            }
            
            Task { @MainActor in
                self?.addMessage(message)
                self?.messageSubject.send(message)
            }
        }
        
        socket?.on("chat_updated") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let chatDict = dict["chat"] as? [String: Any],
                  let jsonData = try? JSONSerialization.data(withJSONObject: chatDict),
                  let chat = try? JSONDecoder().decode(Chat.self, from: jsonData) else {
                return
            }
            
            Task { @MainActor in
                self?.chatUpdateSubject.send(chat)
            }
        }
        
        socket?.on("typing") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let typing = dict["isTyping"] as? Bool else {
                return
            }
            
            Task { @MainActor in
                self?.isTyping = typing
            }
        }
    }
    
    // MARK: - Private Helpers
    
    private func addMessage(_ message: Message) {
        if !messages.contains(where: { $0.id == message.id }) {
            messages.append(message)
            messages.sort { $0.createdAt < $1.createdAt }
        }
    }
    
    private func validateResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AISUPError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw AISUPError.serverError("HTTP \(httpResponse.statusCode)")
        }
    }
}

// MARK: - SwiftUI Convenience Extension

public extension AISUPSDK {
    /// Create a binding for sending messages (useful for TextField)
    func sendMessageBinding() -> (String) -> Void {
        { [weak self] content in
            guard !content.isEmpty else { return }
            Task {
                try? await self?.sendMessage(content)
            }
        }
    }
}
