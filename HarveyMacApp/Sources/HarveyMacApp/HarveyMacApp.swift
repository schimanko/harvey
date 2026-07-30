import SwiftUI
import AppKit
import Foundation
import UniformTypeIdentifiers

// MARK: - Data Models

struct AttachedFileItem: Identifiable, Codable {
    var id = UUID()
    var name: String
    var content: String
}

struct ChatMessage: Identifiable, Codable {
    var id = UUID()
    var role: String
    var content: String
    var thought: String = ""
    var attachedFiles: [String] = []
    var timestamp = Date()
}

struct ChatSession: Identifiable, Codable {
    var id = UUID()
    var title: String
    var messages: [ChatMessage] = []
    var createdAt = Date()
}

struct HardwareMetricsData: Codable {
    var sys_ram_pct: String = "0%"
    var sys_ram_gb: String = "0 GB"
    var sys_cpu: String = "0%"
    var thermal: String = "Cool"
    var harvey_ram_gb: String = "0 GB"
    var harvey_cpu: String = "0%"
}

struct ContentBlock: Identifiable {
    let id = UUID()
    let isCode: Bool
    let language: String
    let text: String
}

// MARK: - Process & Server Management

class ServerManager {
    static let shared = ServerManager()
    private var process: Process?
    weak var viewModel: ChatViewModel?

    func startServer() {
        guard process == nil else { return }
        
        let killTask = Process()
        killTask.launchPath = "/usr/bin/pkill"
        killTask.arguments = ["-f", "server.py"]
        try? killTask.run()
        killTask.waitUntilExit()

        let p = Process()
        let pythonPath = "/Users/lio/Documents/Projects/harvey/.venv/bin/python"
        let scriptPath = "/Users/lio/Documents/Projects/harvey/server.py"
        let workDir = "/Users/lio/Documents/Projects/harvey"

        p.executableURL = URL(fileURLWithPath: pythonPath)
        p.arguments = [scriptPath]
        p.currentDirectoryURL = URL(fileURLWithPath: workDir)
        
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PATH"] = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:" + (env["PATH"] ?? "")
        p.environment = env

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    Task { @MainActor in
                        self?.viewModel?.logDebug("[Server] \(trimmed)")
                    }
                }
            }
        }

        do {
            try p.run()
            self.process = p
            Task { @MainActor in
                self.viewModel?.logDebug("🚀 Harvey local backend started on port 8000.")
            }
        } catch {
            Task { @MainActor in
                self.viewModel?.logDebug("❌ Failed to start server.py: \(error.localizedDescription)")
            }
        }
    }

    func stopServer() {
        if let process = process, process.isRunning {
            process.terminate()
        }
        process = nil
    }
}

// MARK: - View Model (Multi-File Support)

@MainActor
class ChatViewModel: ObservableObject {
    @Published var sessions: [ChatSession] = []
    @Published var activeSessionId: UUID?
    @Published var inputMessage: String = ""
    @Published var isGenerating: Bool = false
    
    @Published var isDebugMode: Bool = false
    @Published var isMetricsMode: Bool = false
    @Published var debugLogs: [String] = []
    @Published var metrics: HardwareMetricsData = HardwareMetricsData()
    @Published var scrollTrigger: UUID = UUID()
    
    @Published var attachedFiles: [AttachedFileItem] = []
    
    private var metricsTimer: Timer?

    private var storageURL: URL {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let dir = paths[0].appendingPathComponent("Harvey")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sessions.json")
    }

    init() {
        ServerManager.shared.viewModel = self
        loadSessionsFromDisk()
        startMetricsPolling()
    }
    
    var activeSession: ChatSession? {
        get { sessions.first(where: { $0.id == activeSessionId }) }
        set {
            if let index = sessions.firstIndex(where: { $0.id == activeSessionId }), let newValue = newValue {
                sessions[index] = newValue
                saveSessionsToDisk()
            }
        }
    }
    
    func saveSessionsToDisk() {
        do {
            let data = try JSONEncoder().encode(sessions)
            try data.write(to: storageURL)
        } catch {
            logDebug("Failed to persist sessions: \(error.localizedDescription)")
        }
    }

    func loadSessionsFromDisk() {
        do {
            let data = try Data(contentsOf: storageURL)
            let decoded = try JSONDecoder().decode([ChatSession].self, from: data)
            if !decoded.isEmpty {
                self.sessions = decoded
                self.activeSessionId = decoded.first?.id
                logDebug("Loaded \(decoded.count) saved chat session(s).")
                return
            }
        } catch {
            logDebug("No previous chat sessions found.")
        }
        createNewSession()
    }
    
    func createNewSession() {
        let newSession = ChatSession(title: "New Chat \(sessions.count + 1)")
        sessions.append(newSession)
        activeSessionId = newSession.id
        saveSessionsToDisk()
        logDebug("Created chat session: \(newSession.id)")
    }
    
    func deleteSession(id: UUID) {
        sessions.removeAll(where: { $0.id == id })
        if activeSessionId == id {
            activeSessionId = sessions.first?.id
        }
        if sessions.isEmpty { createNewSession() }
        saveSessionsToDisk()
    }
    
    func selectFilesForAnalysis() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true // Multi-file selection enabled
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        
        if panel.runModal() == .OK {
            for url in panel.urls {
                do {
                    let content = try String(contentsOf: url, encoding: .utf8)
                    let newItem = AttachedFileItem(name: url.lastPathComponent, content: content)
                    self.attachedFiles.append(newItem)
                    logDebug("Attached file: \(url.lastPathComponent)")
                } catch {
                    logDebug("Error reading file \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
    }
    
    func removeAttachedFile(id: UUID) {
        attachedFiles.removeAll(where: { $0.id == id })
    }
    
    func logDebug(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())
        let entry = "[\(timestamp)] \(message)"
        debugLogs.append(entry)
        print(entry)
    }
    
    func copyAllLogsToClipboard() {
        let allLogs = debugLogs.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(allLogs, forType: .string)
        triggerNativeNotification("Debug logs copied to clipboard.")
    }
    
    func triggerNativeNotification(_ text: String) {
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        let safeText = text.replacingOccurrences(of: "\"", with: "\\\"")
        task.arguments = ["-e", "display notification \"\(safeText)\" with title \"Harvey\""]
        try? task.run()
        logDebug("Triggered Mac Notification: \(text)")
    }
    
    func startMetricsPolling() {
        metricsTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.isMetricsMode else { return }
                await self.fetchMetrics()
            }
        }
    }
    
    func fetchMetrics() async {
        guard let url = URL(string: "http://127.0.0.1:8000/api/metrics") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let decoded = try? JSONDecoder().decode(HardwareMetricsData.self, from: data) {
                self.metrics = decoded
            }
        } catch {
            logDebug("Metrics fetch failed: \(error.localizedDescription)")
        }
    }

    func sendMessage(overridePrompt: String? = nil) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == activeSessionId }) else { return }
        
        let userText = overridePrompt ?? inputMessage.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if userText.isEmpty && attachedFiles.isEmpty { return }
        
        let sentFiles = attachedFiles
        let fileNames = sentFiles.map { $0.name }
        
        if overridePrompt == nil {
            inputMessage = ""
            attachedFiles.removeAll()
            
            if sessions[sessionIndex].messages.isEmpty {
                let titleText = fileNames.first ?? userText
                sessions[sessionIndex].title = String(titleText.prefix(25)) + (titleText.count > 25 ? "..." : "")
            }
            sessions[sessionIndex].messages.append(ChatMessage(role: "user", content: userText, attachedFiles: fileNames))
        }
        
        sessions[sessionIndex].messages.append(ChatMessage(role: "assistant", content: ""))
        let assistantMsgIndex = sessions[sessionIndex].messages.count - 1
        
        isGenerating = true
        scrollTrigger = UUID()
        saveSessionsToDisk()
        
        Task {
            await streamResponse(
                sessionIndex: sessionIndex, 
                messageIndex: assistantMsgIndex, 
                prompt: userText,
                files: sentFiles
            )
        }
    }
    
    func regenerateResponse(for messageId: UUID) {
        guard !isGenerating,
              let sessionIndex = sessions.firstIndex(where: { $0.id == activeSessionId }),
              let msgIndex = sessions[sessionIndex].messages.firstIndex(where: { $0.id == messageId }),
              msgIndex > 0 else { return }
        
        let previousUserPrompt = sessions[sessionIndex].messages[msgIndex - 1].content
        sessions[sessionIndex].messages.removeSubrange(msgIndex...)
        sendMessage(overridePrompt: previousUserPrompt)
    }
    
    private func streamResponse(sessionIndex: Int, messageIndex: Int, prompt: String, files: [AttachedFileItem]) async {
        guard let url = URL(string: "http://127.0.0.1:8000/api/chat") else {
            logDebug("Network Error: Invalid endpoint URL")
            isGenerating = false
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        var body: [String: Any] = ["question": prompt, "chat_history": ""]
        if !files.isEmpty {
            let filesPayload = files.map { ["name": $0.name, "content": $0.content] }
            body["files"] = filesPayload
        }
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                logDebug("HTTP Error: \(httpResponse.statusCode)")
                isGenerating = false
                return
            }
            
            var rawAccumulated = ""
            var lastRenderTime = Date()
            
            for try await line in bytes.lines {
                if line.hasPrefix("data: ") {
                    let jsonString = String(line.dropFirst(6))
                    if let data = jsonString.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        
                        if let toastText = json["toast"] as? String {
                            triggerNativeNotification(toastText)
                        } else if let error = json["error"] as? String {
                            logDebug("Error: \(error)")
                        } else if let chunk = json["chunk"] as? String {
                            rawAccumulated += chunk
                            
                            let now = Date()
                            if now.timeIntervalSince(lastRenderTime) > 0.15 {
                                parseThoughtAndContent(raw: rawAccumulated, sessionIndex: sessionIndex, messageIndex: messageIndex)
                                scrollTrigger = UUID()
                                lastRenderTime = now
                            }
                        }
                    }
                }
            }
            parseThoughtAndContent(raw: rawAccumulated, sessionIndex: sessionIndex, messageIndex: messageIndex)
            scrollTrigger = UUID()
            saveSessionsToDisk()
            
        } catch {
            logDebug("Network Error: \(error.localizedDescription)")
            sessions[sessionIndex].messages[messageIndex].content = "Connection failed. Is server.py active?"
        }
        isGenerating = false
    }
    
    private func parseThoughtAndContent(raw: String, sessionIndex: Int, messageIndex: Int) {
        let cleanRaw = raw.replacingOccurrences(
            of: "(?s)<file name=\"[^\"]+\">",
            with: "",
            options: .regularExpression
        ).replacingOccurrences(of: "</file>", with: "")
        
        let pattern = #"(?i)<(thought|summary|think)>(.*?)</\1>"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) {
            let nsString = cleanRaw as NSString
            let matches = regex.matches(in: cleanRaw, options: [], range: NSRange(location: 0, length: nsString.length))
            
            if let firstMatch = matches.first {
                let thoughtRange = firstMatch.range(at: 2)
                let extractedThought = nsString.substring(with: thoughtRange).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                let postTagIndex = firstMatch.range.location + firstMatch.range.length
                let extractedContent = nsString.substring(from: postTagIndex).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                
                sessions[sessionIndex].messages[messageIndex].thought = extractedThought
                sessions[sessionIndex].messages[messageIndex].content = extractedContent
                return
            }
        }
        
        if cleanRaw.contains("<thought>") || cleanRaw.contains("<summary>") || cleanRaw.contains("<think>") {
            let cleanThought = cleanRaw
                .replacingOccurrences(of: "<thought>", with: "")
                .replacingOccurrences(of: "<summary>", with: "")
                .replacingOccurrences(of: "<think>", with: "")
            sessions[sessionIndex].messages[messageIndex].thought = cleanThought.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            sessions[sessionIndex].messages[messageIndex].content = ""
        } else {
            sessions[sessionIndex].messages[messageIndex].content = cleanRaw
        }
    }
}

// MARK: - App Entry Point

@main
struct HarveyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var vm = ChatViewModel()

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(vm)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        ServerManager.shared.startServer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ServerManager.shared.stopServer()
    }
}

// MARK: - Main UI Layout

struct MainView: View {
    @EnvironmentObject var vm: ChatViewModel

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Harvey")
                        .font(.headline)
                        .fontWeight(.bold)
                    Spacer()
                    Button(action: { vm.createNewSession() }) {
                        Image(systemName: "square.and.pencil")
                    }
                    .buttonStyle(.plain)
                }
                .padding([.horizontal, .top])

                List(vm.sessions, selection: $vm.activeSessionId) { session in
                    HStack {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .foregroundColor(.gray)
                        Text(session.title)
                            .lineLimit(1)
                        Spacer()
                    }
                    .tag(session.id)
                    .contextMenu {
                        Button("Delete", role: .destructive) { vm.deleteSession(id: session.id) }
                    }
                }
                .listStyle(.sidebar)
            }
            .frame(minWidth: 180, idealWidth: 200)
        } detail: {
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Text(vm.activeSession?.title ?? "Chat")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        Button(action: { 
                            vm.isMetricsMode.toggle()
                            if vm.isMetricsMode { Task { await vm.fetchMetrics() } }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "cpu")
                                Text("Metrics")
                            }
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(vm.isMetricsMode ? Color.blue.opacity(0.2) : Color.gray.opacity(0.15))
                            .foregroundColor(vm.isMetricsMode ? .blue : .primary)
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                        
                        Button(action: { vm.isDebugMode.toggle() }) {
                            HStack(spacing: 4) {
                                Image(systemName: "ladybug")
                                Text("Debugging")
                            }
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(vm.isDebugMode ? Color.orange.opacity(0.2) : Color.gray.opacity(0.15))
                            .foregroundColor(vm.isDebugMode ? .orange : .primary)
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor))

                    Divider()

                    if vm.isMetricsMode {
                        HardwareMetricsView()
                        Divider()
                    }

                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 16) {
                                if let messages = vm.activeSession?.messages {
                                    ForEach(messages) { msg in
                                        MessageBubbleView(message: msg) {
                                            vm.regenerateResponse(for: msg.id)
                                        }
                                        .id(msg.id)
                                    }
                                }
                                Color.clear.frame(height: 1).id("bottomAnchor")
                            }
                            .padding()
                        }
                        .onChange(of: vm.scrollTrigger) { _, _ in
                            withAnimation(.easeOut(duration: 0.1)) {
                                proxy.scrollTo("bottomAnchor", anchor: .bottom)
                            }
                        }
                    }

                    Divider()

                    if vm.isDebugMode {
                        DebugConsoleView()
                            .frame(height: 140)
                        Divider()
                    }

                    // Input Bar with Multi-File Attachment Chips
                    VStack(spacing: 6) {
                        if !vm.attachedFiles.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(vm.attachedFiles) { file in
                                        HStack(spacing: 4) {
                                            Image(systemName: "doc.fill")
                                                .foregroundColor(.accentColor)
                                            Text(file.name)
                                                .font(.caption)
                                                .fontWeight(.medium)
                                            Button(action: { vm.removeAttachedFile(id: file.id) }) {
                                                Image(systemName: "xmark.circle.fill")
                                                    .foregroundColor(.gray)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.accentColor.opacity(0.15))
                                        .cornerRadius(8)
                                    }
                                }
                            }
                        }

                        HStack(spacing: 10) {
                            Button(action: { vm.selectFilesForAnalysis() }) {
                                Image(systemName: "paperclip")
                                    .font(.system(size: 18))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Attach Files for Analysis")

                            TextField("Ask Harvey anything...", text: $vm.inputMessage, axis: .vertical)
                                .textFieldStyle(.plain)
                                .padding(10)
                                .background(Color.gray.opacity(0.12))
                                .cornerRadius(10)
                                .lineLimit(1...5)
                                .onSubmit { vm.sendMessage() }

                            Button(action: { vm.sendMessage() }) {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.system(size: 24))
                                    .foregroundColor((vm.inputMessage.isEmpty && vm.attachedFiles.isEmpty) ? .gray : .accentColor)
                            }
                            .buttonStyle(.plain)
                            .disabled((vm.inputMessage.isEmpty && vm.attachedFiles.isEmpty) || vm.isGenerating)
                        }
                    }
                    .padding()
                    .background(Color(NSColor.windowBackgroundColor))
                }
            }
        }
        .frame(minWidth: 700, minHeight: 520)
    }
}

// MARK: - Hardware Metrics Panel

struct HardwareMetricsView: View {
    @EnvironmentObject var vm: ChatViewModel

    var body: some View {
        HStack(spacing: 20) {
            MetricBadge(label: "Mac RAM", value: "\(vm.metrics.sys_ram_pct) (\(vm.metrics.sys_ram_gb))")
            MetricBadge(label: "Mac CPU", value: vm.metrics.sys_cpu)
            MetricBadge(label: "Thermal State", value: vm.metrics.thermal)
            Divider().frame(height: 24)
            MetricBadge(label: "Harvey RAM", value: vm.metrics.harvey_ram_gb)
            MetricBadge(label: "Harvey CPU", value: vm.metrics.harvey_cpu)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .background(Color.blue.opacity(0.06))
    }
}

struct MetricBadge: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(.primary)
        }
    }
}

// MARK: - Message Bubble View (Renders Markdown & File Chips)

struct MessageBubbleView: View {
    let message: ChatMessage
    var onRegenerate: () -> Void
    
    @State private var isThoughtExpanded: Bool = false
    @EnvironmentObject var vm: ChatViewModel
    
    var isUser: Bool { message.role == "user" }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isUser { Spacer(minLength: 50) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                
                if !isUser && !message.thought.isEmpty {
                    DisclosureGroup(isExpanded: $isThoughtExpanded) {
                        Text(message.thought)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.black.opacity(0.15))
                            .cornerRadius(6)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "brain")
                                .font(.caption2)
                            Text("Harvey's Reasoning")
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                        .foregroundColor(.gray)
                    }
                    .frame(maxWidth: 450, alignment: .leading)
                }

                // Render User Bubble with Multiple Gemini-style File Chips
                if isUser {
                    VStack(alignment: .trailing, spacing: 6) {
                        if !message.attachedFiles.isEmpty {
                            HStack(spacing: 6) {
                                ForEach(message.attachedFiles, id: \.self) { fn in
                                    HStack(spacing: 4) {
                                        Image(systemName: "doc.text.fill")
                                            .foregroundColor(.white)
                                        Text(fn)
                                            .font(.caption)
                                            .fontWeight(.semibold)
                                            .foregroundColor(.white)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.blue.opacity(0.4))
                                    .cornerRadius(10)
                                }
                            }
                        }

                        if !message.content.isEmpty {
                            Text(message.content)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .foregroundColor(.white)
                                .background(Color.accentColor)
                                .cornerRadius(16)
                        }
                    }
                } else {
                    if !message.content.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(parseBlocks(raw: message.content)) { block in
                                if block.isCode {
                                    CodeBlockContainer(language: block.language, code: block.text)
                                } else {
                                    // LocalizedStringKey renders rich Markdown bold, lists, and headers
                                    Text(LocalizedStringKey(block.text))
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 10)
                                        .foregroundColor(.primary)
                                        .background(Color.gray.opacity(0.18))
                                        .cornerRadius(16)
                                }
                            }
                        }
                    } else if message.thought.isEmpty {
                        ProgressView()
                            .scaleEffect(0.7)
                            .padding(8)
                    }
                }
                
                if !isUser && !message.content.isEmpty && !vm.isGenerating {
                    HStack(spacing: 12) {
                        Button(action: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.content, forType: .string)
                            vm.triggerNativeNotification("Copied answer to clipboard.")
                        }) {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.plain)
                        .help("Copy Entire Answer")
                        
                        Button(action: {
                            let panel = NSSavePanel()
                            panel.allowedContentTypes = [.text, .plainText]
                            panel.nameFieldStringValue = "Harvey_Output.md"
                            if panel.runModal() == .OK, let url = panel.url {
                                try? message.content.write(to: url, atomically: true, encoding: .utf8)
                                vm.triggerNativeNotification("File saved.")
                            }
                        }) {
                            Image(systemName: "square.and.arrow.down")
                        }
                        .buttonStyle(.plain)
                        .help("Save as File")
                        
                        Button(action: onRegenerate) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.plain)
                        .help("Regenerate Answer")
                    }
                    .foregroundColor(.gray)
                    .font(.caption)
                    .padding(.top, 2)
                    .padding(.leading, 6)
                }
            }

            if !isUser { Spacer(minLength: 50) }
        }
    }
    
    private func parseBlocks(raw: String) -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        let components = raw.components(separatedBy: "```")
        
        for (index, component) in components.enumerated() {
            let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            
            if index % 2 == 1 {
                let lines = component.components(separatedBy: "\n")
                let lang = lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
                let codeText = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                blocks.append(ContentBlock(isCode: true, language: lang.isEmpty ? "code" : lang, text: codeText.isEmpty ? component : codeText))
            } else {
                blocks.append(ContentBlock(isCode: false, language: "", text: trimmed))
            }
        }
        return blocks.isEmpty ? [ContentBlock(isCode: false, language: "", text: raw)] : blocks
    }
}

// MARK: - Code Block Container

struct CodeBlockContainer: View {
    let language: String
    let code: String
    @State private var isCodeExpanded: Bool = true
    @EnvironmentObject var vm: ChatViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.capitalized.isEmpty ? "Code" : language.capitalized)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                
                Spacer()
                
                HStack(spacing: 14) {
                    Button(action: {
                        withAnimation { isCodeExpanded.toggle() }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: isCodeExpanded ? "chevron.up" : "chevron.down")
                            Text(isCodeExpanded ? "Hide" : "Show")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        let panel = NSSavePanel()
                        panel.allowedContentTypes = [.text, .plainText]
                        let ext = language.lowercased() == "bash" ? "sh" : (language.lowercased() == "python" ? "py" : "txt")
                        panel.nameFieldStringValue = "snippet.\(ext)"
                        if panel.runModal() == .OK, let url = panel.url {
                            try? code.write(to: url, atomically: true, encoding: .utf8)
                            vm.triggerNativeNotification("Snippet saved.")
                        }
                    }) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 15))
                            .foregroundColor(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                    .help("Download Snippet")

                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                        vm.triggerNativeNotification("Code copied to clipboard.")
                    }) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                    .help("Copy Code")
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, isCodeExpanded ? 10 : 14)

            if isCodeExpanded {
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(code)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(Color.white.opacity(0.92))
                        .padding(.horizontal, 18)
                        .padding(.bottom, 16)
                        .padding(.top, 2)
                }
            }
        }
        .background(Color(red: 0.08, green: 0.08, blue: 0.09))
        .cornerRadius(18)
    }
}

// MARK: - Debug Console View

struct DebugConsoleView: View {
    @EnvironmentObject var vm: ChatViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "terminal")
                Text("Debug Logs")
                    .font(.caption)
                    .fontWeight(.bold)
                Spacer()
                
                Button("Copy Logs") {
                    vm.copyAllLogsToClipboard()
                }
                .font(.caption2)
                .buttonStyle(.plain)
                .padding(.trailing, 8)

                Button("Clear") {
                    vm.debugLogs.removeAll()
                }
                .font(.caption2)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(vm.debugLogs.enumerated()), id: \.offset) { index, log in
                            Text(log)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(log.contains("Error") || log.contains("❌") ? .red : .green)
                                .textSelection(.enabled)
                                .id(index)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color.black.opacity(0.85))
                .onChange(of: vm.debugLogs.count) { _, _ in
                    if let lastIndex = vm.debugLogs.indices.last {
                        proxy.scrollTo(lastIndex, anchor: .bottom)
                    }
                }
            }
        }
    }
}