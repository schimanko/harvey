import SwiftUI
import AppKit
import Foundation
import UniformTypeIdentifiers
import UserNotifications
import AVFoundation

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

// MARK: - View Model
@MainActor
class ChatViewModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
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
    
    // Voice & Call State
    var speechManager = SpeechManager()
    private var audioPlayer: AVAudioPlayer?
    
    @Published var isVoiceOutputEnabled: Bool = true
    @Published var isCallMode: Bool = false
    @Published var isListening: Bool = false
    @Published var isSpeaking: Bool = false
    @Published var callStatusText: String = "Connecting..."
    @Published var liveTranscription: String = ""
    
    private var metricsTimer: Timer?

    private var storageURL: URL {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let dir = paths[0].appendingPathComponent("Harvey")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sessions.json")
    }

    override init() {
        super.init()
        ServerManager.shared.viewModel = self
        requestNotificationPermission()
        loadSessionsFromDisk()
        startMetricsPolling()
        
        // Wire up STT logic
        speechManager.onTranscriptionUpdated = { [weak self] text in
            Task { @MainActor in
                self?.liveTranscription = text
            }
        }
        
        speechManager.onSilenceDetected = { [weak self] text in
            Task { @MainActor in
                guard let self = self else { return }
                self.inputMessage = text
                self.sendMessage()
                self.liveTranscription = ""
                self.isListening = false
                self.callStatusText = "Thinking..."
            }
        }
    }
    
    // MARK: - Call Mechanics
    func startCall() {
        isCallMode = true
        startListening()
    }
    
    func endCall() {
        isCallMode = false
        isListening = false
        isSpeaking = false
        speechManager.stopListening()
        audioPlayer?.stop()
        liveTranscription = ""
    }
    
    func startListening() {
        isListening = true
        isSpeaking = false
        callStatusText = "Listening..."
        liveTranscription = ""
        speechManager.startListening(callMode: isCallMode)
    }
    
    func speakText(_ text: String) async {
        guard !text.isEmpty else { return }
        
        await MainActor.run {
            self.isSpeaking = true
            self.callStatusText = "Speaking..."
        }
        
        guard let url = URL(string: "http://127.0.0.1:8000/api/tts") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text])

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            
            if statusCode == 200 {
                await MainActor.run {
                    do {
                        self.audioPlayer = try AVAudioPlayer(data: data)
                        self.audioPlayer?.delegate = self
                        self.audioPlayer?.play()
                    } catch {
                        self.logDebug("Audio Decode Error: \(error.localizedDescription)")
                        self.audioPlayerDidFinishPlaying(self.audioPlayer ?? AVAudioPlayer(), successfully: false)
                    }
                }
            } else {
                await MainActor.run {
                    self.logDebug("TTS API Failed: HTTP \(statusCode)")
                    self.audioPlayerDidFinishPlaying(AVAudioPlayer(), successfully: false)
                }
            }
        } catch {
            await MainActor.run {
                self.logDebug("TTS Network Error: \(error.localizedDescription)")
                self.audioPlayerDidFinishPlaying(AVAudioPlayer(), successfully: false)
            }
        }
    }
    
    // AVAudioPlayer Delegate: Triggers when Harvey stops speaking
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isSpeaking = false
            if self.isCallMode {
                self.startListening() // Auto-resume listening in a call
            }
        }
    }
    
    // MARK: - Standard Logic
    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
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
        } catch { }
    }

    func loadSessionsFromDisk() {
        do {
            let data = try Data(contentsOf: storageURL)
            let decoded = try JSONDecoder().decode([ChatSession].self, from: data)
            if !decoded.isEmpty {
                self.sessions = decoded
                
                // 🔥 Always start with a blank conversation on launch
                if let lastSession = self.sessions.last, lastSession.messages.isEmpty {
                    self.activeSessionId = lastSession.id
                } else {
                    createNewSession()
                }
                return
            }
        } catch { }
        createNewSession()
    }
    
    func createNewSession() {
        let newSession = ChatSession(title: "New Chat \(sessions.count + 1)")
        sessions.append(newSession)
        activeSessionId = newSession.id
        saveSessionsToDisk()
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
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        
        if panel.runModal() == .OK {
            for url in panel.urls {
                do {
                    let content = try String(contentsOf: url, encoding: .utf8)
                    let newItem = AttachedFileItem(name: url.lastPathComponent, content: content)
                    self.attachedFiles.append(newItem)
                } catch { }
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
        let content = UNMutableNotificationContent()
        content.title = "Harvey"
        content.body = text
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
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
        } catch { }
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
            isGenerating = false
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let historyMessages = sessions[sessionIndex].messages.prefix(max(0, messageIndex - 1))
        let recentHistory = historyMessages.suffix(16)
        let formattedHistory = recentHistory.map { msg in
            let roleName = msg.role == "user" ? "Lio" : "Harvey"
            return "\(roleName): \(msg.content)"
        }.joined(separator: "\n")
        
        var body: [String: Any] = ["question": prompt, "chat_history": formattedHistory]
        if !files.isEmpty {
            let filesPayload = files.map { ["name": $0.name, "content": $0.content] }
            body["files"] = filesPayload
        }
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
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
            
            // 🔥 Fetch Realistic Male TTS ONLY in Call Mode
            if isCallMode {
                let finalAnswer = sessions[sessionIndex].messages[messageIndex].content
                await speakText(finalAnswer)
            }
            
        } catch {
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
            ZStack {
                MainView()
                    .environmentObject(vm)
                
                // 🔥 The Gemini-Style Call Overlay
                if vm.isCallMode {
                    CallModeOverlay()
                        .environmentObject(vm)
                        .transition(.opacity)
                        .zIndex(100)
                }
            }
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

// MARK: - Call Mode Overlay (Gemini Style)
struct CallModeOverlay: View {
    @EnvironmentObject var vm: ChatViewModel
    @State private var isPulsing = false
    
    var orbColor: Color {
        if vm.isSpeaking { return .blue }      // Speaking
        if vm.isGenerating { return .purple }  // Thinking
        if vm.isListening { return .green }    // Listening
        return .gray
    }
    
    var animationSpeed: Double {
        if vm.isSpeaking { return 0.4 }
        if vm.isGenerating { return 1.5 }
        if vm.isListening { return 0.8 }
        return 1.0
    }
    
    var body: some View {
        ZStack {
            // Dark Frosted Background
            VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                .ignoresSafeArea()
            
            Color.black.opacity(0.6).ignoresSafeArea()
            
            VStack {
                Spacer()
                
                // Pulsing Orb
                ZStack {
                    Circle()
                        .fill(orbColor.opacity(0.3))
                        .frame(width: 220, height: 220)
                        .scaleEffect(isPulsing ? 1.4 : 1.0)
                    
                    Circle()
                        .fill(orbColor.opacity(0.6))
                        .frame(width: 160, height: 160)
                        .scaleEffect(isPulsing ? 1.2 : 1.0)
                    
                    Circle()
                        .fill(orbColor)
                        .frame(width: 120, height: 120)
                }
                .animation(.easeInOut(duration: animationSpeed).repeatForever(autoreverses: true), value: isPulsing)
                .onAppear { isPulsing = true }
                
                Spacer().frame(height: 60)
                
                // Status Text
                Text(vm.callStatusText)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                
                // Live Transcription
                if !vm.liveTranscription.isEmpty {
                    Text(vm.liveTranscription)
                        .font(.system(size: 18, weight: .regular))
                        .foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                        .padding(.top, 10)
                }
                
                Spacer()
                
                // End Call Button
                Button(action: { vm.endCall() }) {
                    ZStack {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 70, height: 70)
                        Image(systemName: "phone.down.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.white)
                    }
                }
                .buttonStyle(.plain)
                .padding(.bottom, 60)
            }
        }
    }
}

// Helper for Background Blur
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
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

                // 🔥 SORTED: Newest chats at the top, oldest at the bottom
                List(vm.sessions.sorted(by: { $0.createdAt > $1.createdAt }), selection: $vm.activeSessionId) { session in
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

                    // 🔥 RESTORED & UPGRADED: Debug Logs
                    if vm.isDebugMode {
                        DebugConsoleView()
                            .frame(height: 140)
                        Divider()
                    }

                    // Input Bar with Call Mechanics
                    VStack(spacing: 6) {
                        HStack(spacing: 10) {
                            Button(action: { vm.selectFilesForAnalysis() }) {
                                Image(systemName: "paperclip")
                                    .font(.system(size: 18))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)

                            // Voice Dictation (Non-Call Mode)
                            Button(action: {
                                if vm.isListening {
                                    vm.speechManager.stopListening()
                                    vm.isListening = false
                                    if !vm.liveTranscription.isEmpty {
                                        vm.inputMessage = vm.liveTranscription
                                        vm.liveTranscription = ""
                                        vm.sendMessage()
                                    }
                                } else {
                                    vm.startListening()
                                }
                            }) {
                                Image(systemName: vm.isListening && !vm.isCallMode ? "mic.fill" : "mic")
                                    .font(.system(size: 18))
                                    .foregroundColor(vm.isListening && !vm.isCallMode ? .red : .secondary)
                            }
                            .buttonStyle(.plain)

                            TextField("Ask Harvey anything...", text: vm.isListening ? $vm.liveTranscription : $vm.inputMessage, axis: .vertical)
                                .textFieldStyle(.plain)
                                .padding(10)
                                .background(Color.gray.opacity(0.12))
                                .cornerRadius(10)
                                .lineLimit(1...5)
                                .onSubmit { 
                                    if vm.isListening {
                                        vm.speechManager.stopListening()
                                        vm.isListening = false
                                        vm.inputMessage = vm.liveTranscription
                                        vm.liveTranscription = ""
                                    }
                                    vm.sendMessage() 
                                }

                            // Call Button
                            Button(action: { 
                                if vm.isCallMode {
                                    vm.endCall()
                                } else {
                                    vm.startCall()
                                }
                            }) {
                                Image(systemName: "phone.circle.fill")
                                    .font(.system(size: 24))
                                    .foregroundColor(.green)
                            }
                            .buttonStyle(.plain)
                            .help("Call Harvey")

                            Button(action: { 
                                if vm.isListening {
                                    vm.speechManager.stopListening()
                                    vm.isListening = false
                                    vm.inputMessage = vm.liveTranscription
                                    vm.liveTranscription = ""
                                }
                                vm.sendMessage() 
                            }) {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.system(size: 24))
                                    .foregroundColor((vm.inputMessage.isEmpty && vm.attachedFiles.isEmpty && vm.liveTranscription.isEmpty) ? .gray : .accentColor)
                            }
                            .buttonStyle(.plain)
                            .disabled(((vm.inputMessage.isEmpty && vm.liveTranscription.isEmpty) && vm.attachedFiles.isEmpty) || vm.isGenerating)
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

// MARK: - Rest of UI Components
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

// 🔥 UPGRADED DEBUG CONSOLE WITH COPY BUTTON AND VISIBLE TEXT
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
                
                // Copy Logs Button
                Button(action: {
                    vm.copyAllLogsToClipboard()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                        Text("Copy Logs")
                    }
                }
                .font(.caption2)
                .buttonStyle(.plain)
                .padding(.trailing, 8)

                // Clear Button
                Button(action: {
                    vm.debugLogs.removeAll()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                        Text("Clear")
                    }
                }
                .font(.caption2)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if vm.debugLogs.isEmpty {
                            Text("Waiting for logs...")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.gray)
                        } else {
                            ForEach(Array(vm.debugLogs.enumerated()), id: \.offset) { index, log in
                                // Text color logic: Red if error, otherwise bright green terminal color
                                Text(log)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(log.contains("Error") || log.contains("❌") ? .red : .green)
                                    .textSelection(.enabled)
                                    .id(index)
                            }
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color.black.opacity(0.9)) // Force deep black background
                .cornerRadius(6)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .onChange(of: vm.debugLogs.count) { _, _ in
                    if let lastIndex = vm.debugLogs.indices.last {
                        proxy.scrollTo(lastIndex, anchor: .bottom)
                    }
                }
            }
        }
    }
}