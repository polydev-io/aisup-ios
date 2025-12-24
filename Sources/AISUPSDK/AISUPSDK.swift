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
        
        // Настройка декодирования дат с поддержкой нескольких форматов
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        
        // Создаем кастомную стратегию декодирования дат
        self.decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)
            
            // Формат 1: ISO8601 с T и Z (стандартный)
            // "2025-12-21T15:47:15Z" или "2025-12-21T15:47:15.123Z"
            dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
            if let date = dateFormatter.date(from: dateString) {
                return date
            }
            
            dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
            if let date = dateFormatter.date(from: dateString) {
                return date
            }
            
            // Формат 2: ISO8601 без Z (с таймзоной)
            // "2025-12-21T15:47:15+00:00"
            dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"
            if let date = dateFormatter.date(from: dateString) {
                return date
            }
            
            dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
            if let date = dateFormatter.date(from: dateString) {
                return date
            }
            
            // Формат 3: Простой формат без T (что приходит с сервера)
            // "2025-12-21 15:47:15"
            dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            if let date = dateFormatter.date(from: dateString) {
                return date
            }
            
            // Формат 4: С миллисекундами
            // "2025-12-21 15:47:15.123"
            dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            if let date = dateFormatter.date(from: dateString) {
                return date
            }
            
            // Формат 5: ISO8601 без секунд
            dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"
            if let date = dateFormatter.date(from: dateString) {
                return date
            }
            
            // Формат 6: Только дата
            dateFormatter.dateFormat = "yyyy-MM-dd"
            if let date = dateFormatter.date(from: dateString) {
                return date
            }
            
            // Если все форматы не подошли, выбрасываем ошибку
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Не удалось декодировать дату: \(dateString). Поддерживаемые форматы: ISO8601, yyyy-MM-dd HH:mm:ss"
            )
        }
        
        // Восстанавливаем сохранённый chatId, если он есть,
        // чтобы с одного и того же клиента всегда использовался один и тот же чат.
        let storageKey = Self.chatIdStorageKey(
            apiUrl: config.apiUrl,
            apiKey: config.apiKey,
            userName: config.userName
        )
        
        // 1) Пробуем достать chatId из Keychain (переживает переустановку приложения).
        if let storedChatId = KeychainStorage.string(forKey: storageKey) {
            self.chatId = storedChatId
        }
    }
    
    // MARK: - Public async/await API
    
    /// Start the chat session (init + connect + join)
    public func start() async throws {
        let response = try await initialize()
        
        // Load message history (non-critical, continue even if it fails)
        do {
            let messagesResponse = try await getMessages()
            self.messages = messagesResponse.messages
            print("[AISUPSDK] ✅ История загружена: \(messagesResponse.messages.count) сообщений")
        } catch {
            // Ошибка декодирования истории - не критично, продолжаем без истории
            // Новые сообщения будут приходить через WebSocket
            print("[AISUPSDK] ⚠️ Не удалось загрузить историю: \(error)")
            print("[AISUPSDK] Продолжаем работу без истории, новые сообщения придут через WebSocket")
            self.messages = []
        }
        
        // Connect socket (ALWAYS execute, even if history loading failed)
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
        
        // Если chatId уже есть (мы его восстановили получили ранее с сервера),
        // повторно используем его, чтобы не создавать новый чат для того же клиента.
        let clientChatId = chatId ?? UUID().uuidString
        let body: [String: Any] = [
            "chatId": clientChatId,
            "chatNickname": config.userName
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        
        let result = try decoder.decode(InitResponse.self, from: data)
        
        // Сохраняем фактический chatId, который вернул сервер, в память и в Keychain
        // для последующих сессий этого же клиента (переживает переустановку приложения).
        self.chatId = result.chatId
        let storageKey = Self.chatIdStorageKey(
            apiUrl: config.apiUrl,
            apiKey: config.apiKey,
            userName: config.userName
        )
        KeychainStorage.set(result.chatId, forKey: storageKey)
        
        return result
    }
    
    /// Send a message
    public func sendMessage(_ content: String, attachments: [Attachment]? = nil) async throws {
        guard let chatId = chatId else {
            throw AISUPError.notInitialized
        }
        
        let url = URL(string: "\(config.apiUrl)/api/integration/send-message")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "X-API-Key")
        
        var body: [String: Any] = ["chatId": chatId, "messageText": content]
        if let attachments = attachments {
            let encoder = JSONEncoder()
            let attachmentsData = try encoder.encode(attachments)
            body["attachments"] = try JSONSerialization.jsonObject(with: attachmentsData)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (_, response) = try await session.data(for: request)
        try validateResponse(response)
        // Message will be added via WebSocket "message_added" event
    }
    
    /// Get message history
    public func getMessages(limit: Int = 50, before: String? = nil) async throws -> MessagesResponse {
        guard let chatId = chatId else {
            throw AISUPError.notInitialized
        }
        
        let url = URL(string: "\(config.apiUrl)/api/integration/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "X-API-Key")
        
        let body: [String: Any] = ["chatId": chatId]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        
        // Логирование для отладки
        if let jsonString = String(data: data, encoding: .utf8) {
            print("[AISUPSDK] getMessages() raw response: \(jsonString.prefix(500))")
        }
        
        do {
            let result = try decoder.decode(MessagesResponse.self, from: data)
            print("[AISUPSDK] getMessages() успешно декодировано: \(result.messages.count) сообщений")
            return result
        } catch {
            print("[AISUPSDK] getMessages() ошибка декодирования: \(error)")
            if let decodingError = error as? DecodingError {
                print("[AISUPSDK] Детали ошибки: \(decodingError)")
            }
            throw error
        }
    }
    
    /// Upload a file
    public func uploadFile(_ fileData: Data, fileName: String, mimeType: String) async throws -> UploadResponse {
        guard let chatId = chatId else {
            throw AISUPError.notInitialized
        }
        
        let boundary = UUID().uuidString
        
        func makeRequest(url: URL) async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(config.apiKey, forHTTPHeaderField: "X-API-Key")
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
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AISUPError.invalidResponse
            }
            return (data, httpResponse)
        }
        
        // Единственный известный эндпоинт для загрузки файлов.
        // На текущем стенде он не реализован (Express отвечает "Cannot POST /api/integration/upload"),
        // поэтому в случае 404/405 возвращаем осмысленную ошибку без повторных запросов.
        let url = URL(string: "\(config.apiUrl)/api/integration/upload")!
        let (data, response) = try await makeRequest(url: url)
        
        switch response.statusCode {
        case 200...299:
            return try decoder.decode(UploadResponse.self, from: data)
        case 404, 405:
            throw AISUPError.serverError("Загрузка файлов на сервер не настроена (HTTP \(response.statusCode)). Обратитесь к разработчикам бэкенда, чтобы включить /api/integration/upload.")
        case 413:
            throw AISUPError.serverError("Размер файла слишком большой (HTTP 413). Пожалуйста, выберите файл меньшего размера.")
        default:
            throw AISUPError.serverError("HTTP \(response.statusCode)")
        }
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
            guard let self = self,
                  let dict = data.first as? [String: Any],
                  let messageDict = dict["message"] as? [String: Any],
                  let jsonData = try? JSONSerialization.data(withJSONObject: messageDict) else {
                return
            }
            
            do {
                let message = try self.decoder.decode(Message.self, from: jsonData)
                Task { @MainActor in
                    self.addMessage(message)
                    self.messageSubject.send(message)
                }
            } catch {
                print("[AISUPSDK] Failed to decode message: \(error)")
            }
        }
        
        socket?.on("chat_updated") { [weak self] data, _ in
            guard let self = self,
                  let dict = data.first as? [String: Any],
                  let chatDict = dict["chat"] as? [String: Any],
                  let jsonData = try? JSONSerialization.data(withJSONObject: chatDict) else {
                return
            }
            
            do {
                let chat = try self.decoder.decode(Chat.self, from: jsonData)
                Task { @MainActor in
                    self.chatUpdateSubject.send(chat)
                }
            } catch {
                print("[AISUPSDK] Failed to decode chat: \(error)")
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

// MARK: - Private persistence helpers

private extension AISUPSDK {
    static func chatIdStorageKey(apiUrl: String, apiKey: String, userName: String) -> String {
        "AISUPSDK.chatId.\(apiUrl).\(apiKey).\(userName)"
    }
}

// MARK: - Simple Keychain storage

private enum KeychainStorage {
    static func set(_ value: String, forKey key: String) {
        guard let data = value.data(using: .utf8) else { return }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        
        // Удаляем старое значение, если есть
        SecItemDelete(query as CFDictionary)
        
        var attributes = query
        attributes[kSecValueData as String] = data
        
        SecItemAdd(attributes as CFDictionary, nil)
    }
    
    static func string(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        return string
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
