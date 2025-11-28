# AISUP SDK for iOS

Современный Swift Package для интеграции чата поддержки AISUP.

**Возможности:**
- ✅ SwiftUI + ObservableObject
- ✅ Combine Publishers
- ✅ async/await
- ✅ AsyncStream для real-time
- ✅ Swift 6 Sendable

## Установка

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/polydev-io/aisup-ios", .upToNextMinor(from: "1.0.1"))
]
```

Или через Xcode: **File → Add Package Dependencies** → URL репозитория.

---

## SwiftUI (рекомендуется)

SDK — это `ObservableObject` с `@Published` свойствами:

```swift
import SwiftUI
import AISUPSDK

struct ChatView: View {
    @StateObject private var sdk = AISUPSDK(config: AISUPConfig(
        apiKey: "YOUR_API_KEY",
        apiUrl: "https://your-api.com"
    ))
    
    @State private var inputText = ""
    
    var body: some View {
        VStack {
            // Статус подключения
            HStack {
                Circle()
                    .fill(sdk.isConnected ? .green : .red)
                    .frame(width: 8, height: 8)
                Text(sdk.connectionStatus.rawValue)
            }
            
            // Сообщения (автоматически обновляются)
            ScrollView {
                LazyVStack(alignment: .leading) {
                    ForEach(sdk.messages) { message in
                        MessageBubble(message: message)
                    }
                }
            }
            
            // Индикатор набора
            if sdk.isTyping {
                Text("Оператор печатает...")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            
            // Ввод
            HStack {
                TextField("Сообщение...", text: $inputText)
                    .textFieldStyle(.roundedBorder)
                
                Button("Отправить") {
                    sendMessage()
                }
                .disabled(inputText.isEmpty)
            }
            .padding()
        }
        .task {
            do {
                try await sdk.start()
            } catch {
                print("Error: \(error)")
            }
        }
    }
    
    private func sendMessage() {
        let text = inputText
        inputText = ""
        Task {
            try? await sdk.sendMessage(text)
        }
    }
}

struct MessageBubble: View {
    let message: Message
    
    var body: some View {
        HStack {
            if message.sender == .user { Spacer() }
            
            Text(message.content)
                .padding(12)
                .background(message.sender == .user ? Color.blue : Color.gray.opacity(0.2))
                .foregroundColor(message.sender == .user ? .white : .primary)
                .cornerRadius(16)
            
            if message.sender != .user { Spacer() }
        }
        .padding(.horizontal)
    }
}
```

---

## Combine Publishers

```swift
import Combine
import AISUPSDK

class ChatViewModel: ObservableObject {
    private let sdk: AISUPSDK
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        sdk = AISUPSDK(config: AISUPConfig(
            apiKey: "xxx",
            apiUrl: "https://..."
        ))
        
        // Подписка на новые сообщения
        sdk.messagePublisher
            .receive(on: DispatchQueue.main)
            .sink { message in
                print("New message: \(message.content)")
            }
            .store(in: &cancellables)
        
        // Подписка на статус подключения
        sdk.connectionPublisher
            .sink { status in
                print("Connection: \(status)")
            }
            .store(in: &cancellables)
        
        // Подписка на обновления чата
        sdk.chatUpdatePublisher
            .sink { chat in
                print("Chat updated: \(chat.mode)")
            }
            .store(in: &cancellables)
    }
}
```

---

## async/await API

```swift
import AISUPSDK

let sdk = AISUPSDK(config: AISUPConfig(
    apiKey: "YOUR_API_KEY",
    apiUrl: "https://your-api.com"
))

// Полный старт (init + connect + join)
try await sdk.start()

// Отправка сообщения
let message = try await sdk.sendMessage("Привет!")

// Получение истории
let response = try await sdk.getMessages(limit: 50)

// Загрузка файла
let upload = try await sdk.uploadFile(
    imageData,
    fileName: "photo.jpg",
    mimeType: "image/jpeg"
)

// Отключение
sdk.stop()
```

---

## AsyncStream для .task

```swift
struct ChatView: View {
    @StateObject private var sdk = AISUPSDK(config: ...)
    
    var body: some View {
        List(sdk.messages) { message in
            Text(message.content)
        }
        .task {
            try? await sdk.start()
        }
        .task {
            // Реагируем на новые сообщения
            for await message in sdk.messageStream {
                // Показать уведомление, звук и т.д.
                print("Received: \(message.content)")
            }
        }
    }
}
```

---

## Доступные свойства

| Свойство | Тип | Описание |
|----------|-----|----------|
| `messages` | `[Message]` | История сообщений (реактивная) |
| `connectionStatus` | `ConnectionStatus` | Статус подключения |
| `isTyping` | `Bool` | Печатает ли оператор |
| `chatId` | `String?` | ID текущего чата |
| `error` | `AISUPError?` | Последняя ошибка |
| `isInitialized` | `Bool` | Инициализирован ли чат |
| `isConnected` | `Bool` | Подключен ли WebSocket |

---

## Требования

- iOS 15.0+ / macOS 12.0+
- Swift 5.7+
- Xcode 14+
