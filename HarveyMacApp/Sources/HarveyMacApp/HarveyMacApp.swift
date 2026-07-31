import SwiftUI
import AppKit
import Foundation
import UniformTypeIdentifiers
import UserNotifications
import AVFoundation
import Charts

struct MetricPoint: Identifiable {
    let id = UUID()
    let time = Date()
    let value: Double
}

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
    var isPinned: Bool = false
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
        killTask.arguments = ["-f", "harvey.py"]
        try? killTask.run()
        killTask.waitUntilExit()

        let p = Process()
        let pythonPath = "/Users/lio/Documents/Projects/harvey/.venv/bin/python"
        let scriptPath = "/Users/lio/Documents/Projects/harvey/harvey.py"
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
            process = p
        } catch {
            Task { @MainActor in
                self.viewModel?.logDebug("❌ Failed to start Harvey's brain at harvey.py: \(error.localizedDescription)")
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
    @Published var searchText: String = ""
    @Published var showCodeSidebar: Bool = false
    @Published var sessions: [ChatSession] = []
    
    // 🔥 NEW: Set-based selection for multi-select
    @Published var selectedSessionIds: Set<UUID> = []
    
    @Published var inputMessage: String = ""
    @Published var isGenerating: Bool = false
    
    @Published var isDebugMode: Bool = false
    @Published var isMetricsMode: Bool = false
    @Published var debugLogs: [String] = []
    @Published var metrics: HardwareMetricsData = HardwareMetricsData()
    // 🔥 NEW: Store the last 60 seconds of data
    @Published var cpuHistory: [MetricPoint] = []
    @Published var ramHistory: [MetricPoint] = []
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
                
        speechManager.onTranscriptionUpdated = { [weak self] text in
            Task { @MainActor in self?.liveTranscription = text }
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
                        self.audioPlayerDidFinishPlaying(self.audioPlayer ?? AVAudioPlayer(), successfully: false)
                    }
                }
            } else {
                await MainActor.run {
                    self.audioPlayerDidFinishPlaying(AVAudioPlayer(), successfully: false)
                }
            }
        } catch {
            await MainActor.run {
                self.audioPlayerDidFinishPlaying(AVAudioPlayer(), successfully: false)
            }
        }
    }
    
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isSpeaking = false
            if self.isCallMode {
                self.startListening()
            }
        }
    }
    
    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    
    var activeSession: ChatSession? {
        get {
            guard selectedSessionIds.count == 1, let id = selectedSessionIds.first else { return nil }
            return sessions.first(where: { $0.id == id })
        }
        set {
            guard selectedSessionIds.count == 1, let id = selectedSessionIds.first else { return }
            if let index = sessions.firstIndex(where: { $0.id == id }), let newValue = newValue {
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
                if let lastSession = self.sessions.last, lastSession.messages.isEmpty {
                    self.selectedSessionIds = [lastSession.id]
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
        selectedSessionIds = [newSession.id]
        saveSessionsToDisk()
    }
    
    func deleteSession(id: UUID) {
        sessions.removeAll(where: { $0.id == id })
        selectedSessionIds.remove(id)
        if selectedSessionIds.isEmpty {
            if let first = sessions.first {
                selectedSessionIds = [first.id]
            } else {
                createNewSession()
            }
        }
        saveSessionsToDisk()
    }

    // 🔥 NEW: Batch Delete Handler
    func deleteSelectedSessions() {
        sessions.removeAll { selectedSessionIds.contains($0.id) }
        selectedSessionIds.removeAll()
        if let first = sessions.first {
            selectedSessionIds = [first.id]
        } else {
            createNewSession()
        }
        saveSessionsToDisk()
    }

    func renameSession(id: UUID, newTitle: String) {
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            let cleanTitle = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanTitle.isEmpty {
                sessions[index].title = cleanTitle
                saveSessionsToDisk()
            }
        }
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
    
    // 🔥 NEW: Hard kill/start the timer to save Mac battery
    func toggleMetricsMode() {
        isMetricsMode.toggle()
        
        if isMetricsMode {
            // Start polling every 1 second
            metricsTimer?.invalidate()
            metricsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.fetchMetrics() }
            }
            Task { await fetchMetrics() } // Initial fetch
        } else {
            // Kill the timer completely and wipe memory arrays
            metricsTimer?.invalidate()
            metricsTimer = nil
            cpuHistory.removeAll()
            ramHistory.removeAll()
        }
    }
    
    func fetchMetrics() async {
        guard let url = URL(string: "http://127.0.0.1:8000/api/metrics") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let decoded = try? JSONDecoder().decode(HardwareMetricsData.self, from: data) {
                self.metrics = decoded
                
                // Parse strings like "12.5%" into pure Doubles for the graph
                let cpuStr = decoded.sys_cpu.replacingOccurrences(of: "%", with: "")
                let ramStr = decoded.sys_ram_gb.replacingOccurrences(of: " GB", with: "")
                
                self.cpuHistory.append(MetricPoint(value: Double(cpuStr) ?? 0))
                self.ramHistory.append(MetricPoint(value: Double(ramStr) ?? 0))
                
                // Keep only the last 60 seconds (60 points) to prevent memory bloat
                if self.cpuHistory.count > 60 { self.cpuHistory.removeFirst() }
                if self.ramHistory.count > 60 { self.ramHistory.removeFirst() }
            }
        } catch { }
    }

    func sendMessage(overridePrompt: String? = nil) {
        guard let id = selectedSessionIds.first, let sessionIndex = sessions.firstIndex(where: { $0.id == id }) else { return }
        
        let userText = overridePrompt ?? inputMessage.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if userText.isEmpty && attachedFiles.isEmpty && liveTranscription.isEmpty { return }
        
        let sentFiles = attachedFiles
        let fileNames = sentFiles.map { $0.name }
        
        if overridePrompt == nil {
            inputMessage = ""
            attachedFiles.removeAll()
            
            if sessions[sessionIndex].messages.isEmpty {
                sessions[sessionIndex].title = "Thinking..."
                sessions[sessionIndex].messages.append(ChatMessage(role: "user", content: userText, attachedFiles: fileNames))
                Task {
                    await generateTitle(for: sessions[sessionIndex].id, prompt: userText)
                }
            } else {
                sessions[sessionIndex].messages.append(ChatMessage(role: "user", content: userText, attachedFiles: fileNames))
            }
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
              let id = selectedSessionIds.first,
              let sessionIndex = sessions.firstIndex(where: { $0.id == id }),
              let msgIndex = sessions[sessionIndex].messages.firstIndex(where: { $0.id == messageId }),
              msgIndex > 0 else { return }
        
        let previousUserPrompt = sessions[sessionIndex].messages[msgIndex - 1].content
        sessions[sessionIndex].messages.removeSubrange(msgIndex...)
        sendMessage(overridePrompt: previousUserPrompt)
    }
    
    private func streamResponse(sessionIndex: Int, messageIndex: Int, prompt: String, files: [AttachedFileItem]) async {
        defer {
            Task { @MainActor in
                self.isGenerating = false
                self.scrollTrigger = UUID()
                self.saveSessionsToDisk()
            }
        }

        guard let url = URL(string: "http://127.0.0.1:8000/api/chat") else {
            sessions[sessionIndex].messages[messageIndex].content = "Connection failed."
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

        var body: [String: Any] = [
            "question": prompt,
            "chat_history": formattedHistory
        ]

        if !files.isEmpty {
            let filesPayload = files.map { ["name": $0.name, "content": $0.content] }
            body["files"] = filesPayload
        }

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                sessions[sessionIndex].messages[messageIndex].content = "Harvey's sleeping. Is harvey.py active?"
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
                        } else if let errorText = json["error"] as? String {
                            rawAccumulated += "\n\n⚠️ **Backend Error:** \(errorText)"
                            self.logDebug("Backend Error: \(errorText)")
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

            if !rawAccumulated.isEmpty {
                parseThoughtAndContent(raw: rawAccumulated, sessionIndex: sessionIndex, messageIndex: messageIndex)
                scrollTrigger = UUID()
            }

            if isCallMode {
                let finalAnswer = sessions[sessionIndex].messages[messageIndex].content
                await speakText(finalAnswer)
            }

        } catch {
            sessions[sessionIndex].messages[messageIndex].content = "Harvey's sleeping. Is harvey.py active?"
        }
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

    func parseBlocks(raw: String) -> [ContentBlock] {
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
    
    var filteredSessions: [ChatSession] {
        var filtered = sessions
        if !searchText.isEmpty {
            filtered = filtered.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
        }
        return filtered.sorted {
            if $0.isPinned == $1.isPinned {
                return $0.createdAt > $1.createdAt
            }
            return $0.isPinned && !$1.isPinned
        }
    }
    
    func togglePin(for id: UUID) {
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index].isPinned.toggle()
            saveSessionsToDisk()
        }
    }
    
    func generateTitle(for sessionId: UUID, prompt: String) async {
        guard let url = URL(string: "[http://127.0.0.1:8000/api/chat](http://127.0.0.1:8000/api/chat)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "question": "Summarize this request in exactly 2 to 4 words. Use Title Case. NO punctuation, NO quotes, NO conversational text. Output ONLY the short title. Request: \(prompt)",
            "chat_history": ""
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            if (response as? HTTPURLResponse)?.statusCode != 200 { return }
            
            var accumulated = ""
            for try await line in bytes.lines {
                if line.hasPrefix("data: ") {
                    let jsonString = String(line.dropFirst(6))
                    if let data = jsonString.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let chunk = json["chunk"] as? String {
                        accumulated += chunk
                    }
                }
            }
            
            var cleanTitle = accumulated
                .replacingOccurrences(of: "(?is)<(thought|summary|think)>.*?</\\1>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\"", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            
            if cleanTitle.hasPrefix("<") || cleanTitle.isEmpty {
                cleanTitle = String(prompt.prefix(25)) + "..."
            } else if cleanTitle.count > 35 {
                cleanTitle = String(cleanTitle.prefix(32)) + "..."
            }
            
            let finalTitle = cleanTitle
            await MainActor.run {
                if let index = self.sessions.firstIndex(where: { $0.id == sessionId }) {
                    self.sessions[index].title = finalTitle
                    self.saveSessionsToDisk()
                }
            }
        } catch { }
    }
    
    func exportToMarkdown(session: ChatSession) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(session.title).md"
        if panel.runModal() == .OK, let url = panel.url {
            let text = session.messages.map { "**\($0.role == "user" ? "You" : "Harvey")**:\n\($0.content)" }.joined(separator: "\n\n---\n\n")
            try? text.write(to: url, atomically: true, encoding: .utf8)
            triggerNativeNotification("Exported chat to Markdown.")
        }
    }
    
    func exportToPDF(session: ChatSession) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(session.title).pdf"
        if panel.runModal() == .OK, let url = panel.url {
            let text = session.messages.map { "\($0.role == "user" ? "You" : "Harvey"):\n\($0.content)" }.joined(separator: "\n\n")
            let attrString = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.textColor
            ])
            
            let printInfo = NSPrintInfo.shared
            printInfo.jobDisposition = .save
            printInfo.dictionary().setObject(url, forKey: NSPrintInfo.AttributeKey.jobSavingURL as NSCopying)
            
            let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: printInfo.paperSize.width - 40, height: printInfo.paperSize.height - 40))
            textView.textStorage?.setAttributedString(attrString)
            
            let printOp = NSPrintOperation(view: textView, printInfo: printInfo)
            printOp.showsPrintPanel = false
            printOp.showsProgressPanel = false
            printOp.run()
            
            triggerNativeNotification("Exported chat to PDF.")
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

// MARK: - Call Mode Overlay
struct CallModeOverlay: View {
    @EnvironmentObject var vm: ChatViewModel
    @State private var isPulsing = false
    
    var orbColor: Color {
        if vm.isSpeaking { return .blue }
        if vm.isGenerating { return .purple }
        if vm.isListening { return .green }
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
            VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                .ignoresSafeArea()
            
            Color.black.opacity(0.6).ignoresSafeArea()
            
            VStack {
                Spacer()
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
                
                Text(vm.callStatusText)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                
                if !vm.liveTranscription.isEmpty {
                    Text(vm.liveTranscription)
                        .font(.system(size: 18, weight: .regular))
                        .foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                        .padding(.top, 10)
                }
                
                Spacer()
                
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

// MARK: - Sidebar Item View
struct SidebarItemView: View {
    let session: ChatSession
    @EnvironmentObject var vm: ChatViewModel
    @Binding var renameTitle: String
    @Binding var sessionToRename: UUID?
    @Binding var showRenameAlert: Bool
    
    @State private var isHovering = false

    var body: some View {
        HStack {
            Text(session.isPinned ? "📌 \(session.title)" : session.title)
                .lineLimit(1)
            Spacer()
            
            if isHovering {
                Menu {
                    Button(session.isPinned ? "Unpin Chat" : "Pin Chat") {
                        vm.togglePin(for: session.id)
                    }
                    Button("Rename") {
                        renameTitle = session.title
                        sessionToRename = session.id
                        showRenameAlert = true
                    }
                    Button("Delete", role: .destructive) {
                        vm.deleteSession(id: session.id)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 20)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// MARK: - Code Snippets Sidebar
struct CodeSidebarView: View {
    @EnvironmentObject var vm: ChatViewModel
    
    struct ExtractedCode: Identifiable {
        let id = UUID()
        let language: String
        let code: String
        let date: Date
    }
    
    var snippets: [ExtractedCode] {
        guard let session = vm.activeSession else { return [] }
        var result: [ExtractedCode] = []
        for msg in session.messages where msg.role == "assistant" {
            let blocks = vm.parseBlocks(raw: msg.content)
            for block in blocks where block.isCode {
                result.append(ExtractedCode(language: block.language, code: block.text, date: msg.timestamp))
            }
        }
        return result.sorted { $0.date > $1.date }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Generated Code")
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                Spacer()
                Text("\(snippets.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(4)
            }
            .padding()
            
            Divider()
            
            ScrollView {
                LazyVStack(spacing: 20) {
                    if snippets.isEmpty {
                        Text("No code generated yet.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 40)
                    } else {
                        ForEach(snippets) { snippet in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(snippet.date.formatted(date: .abbreviated, time: .standard))
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .padding(.leading, 4)
                                
                                CodeBlockContainer(language: snippet.language, code: snippet.code)
                            }
                        }
                    }
                }
                .padding()
            }
        }
        .frame(width: 320)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - Main UI Layout
struct MainView: View {
    @EnvironmentObject var vm: ChatViewModel
    
    @State private var showRenameAlert = false
    @State private var sessionToRename: UUID? = nil
    @State private var renameTitle = ""

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

                // 🔥 NEW: Set Selection enabled
                List(selection: $vm.selectedSessionIds) {
                    ForEach(vm.filteredSessions) { session in
                        SidebarItemView(
                            session: session,
                            renameTitle: $renameTitle,
                            sessionToRename: $sessionToRename,
                            showRenameAlert: $showRenameAlert
                        )
                        .tag(session.id)
                        .contextMenu {
                            Button(session.isPinned ? "Unpin Chat" : "Pin Chat") { vm.togglePin(for: session.id) }
                            Button("Rename") {
                                renameTitle = session.title
                                sessionToRename = session.id
                                showRenameAlert = true
                            }
                            Button("Delete", role: .destructive) { vm.deleteSession(id: session.id) }
                        }
                    }
                }
                .listStyle(.sidebar)
                .searchable(text: $vm.searchText, placement: .sidebar, prompt: "Search chats")
                .alert("Rename Chat", isPresented: $showRenameAlert) {
                    TextField("New name", text: $renameTitle)
                    Button("Save") {
                        if let id = sessionToRename {
                            vm.renameSession(id: id, newTitle: renameTitle)
                        }
                    }
                    Button("Cancel", role: .cancel) { }
                }
            }
            .frame(minWidth: 180, idealWidth: 200)
        } detail: {
            // 🔥 NEW: Multi-Select Deletion View vs Standard Chat View
            if vm.selectedSessionIds.count > 1 {
                VStack(spacing: 20) {
                    Image(systemName: "trash.circle.fill")
                        .font(.system(size: 70))
                        .foregroundColor(.red.opacity(0.8))
                    
                    Text("\(vm.selectedSessionIds.count) Chats Selected")
                        .font(.title)
                        .fontWeight(.bold)
                    
                    Button(action: {
                        withAnimation {
                            vm.deleteSelectedSessions()
                        }
                    }) {
                        Text("Delete Selected Chats")
                            .font(.headline)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Color.red)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.windowBackgroundColor))
            } else {
                ZStack(alignment: .top) {
                    HStack(spacing: 0) {
                        VStack(spacing: 0) {
                            HStack(spacing: 8) {
                                Text(vm.activeSession?.title ?? "Chat")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.primary)
                                
                                Button(action: { 
                                    vm.toggleMetricsMode()
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
                                .padding(.leading, 8)
                                
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
                                
                                Spacer()
                                
                                Button(action: {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        vm.showCodeSidebar.toggle()
                                    }
                                }) {
                                    Image(systemName: "sidebar.right")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(vm.showCodeSidebar ? .accentColor : .primary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(vm.showCodeSidebar ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.15))
                                        .cornerRadius(6)
                                }
                                .buttonStyle(.plain)
                                
                                Menu {
                                    Button(vm.activeSession?.isPinned == true ? "Unpin Chat" : "Pin Chat") {
                                        if let id = vm.selectedSessionIds.first { vm.togglePin(for: id) }
                                    }
                                    Button("Rename Chat") {
                                        if let session = vm.activeSession {
                                            renameTitle = session.title
                                            sessionToRename = session.id
                                            showRenameAlert = true
                                        }
                                    }
                                    Menu("Download as...") {
                                        Button("Markdown (.md)") {
                                            if let session = vm.activeSession { vm.exportToMarkdown(session: session) }
                                        }
                                        Button("PDF (.pdf)") {
                                            if let session = vm.activeSession { vm.exportToPDF(session: session) }
                                        }
                                    }
                                    Divider()
                                    Button("Delete Chat", role: .destructive) {
                                        if let id = vm.selectedSessionIds.first { vm.deleteSession(id: id) }
                                    }
                                } label: {
                                    Image(systemName: "ellipsis")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(.primary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.gray.opacity(0.15))
                                        .cornerRadius(6)
                                }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .frame(width: 32)
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
                                    .padding(.bottom, 4)
                                }

                                HStack(spacing: 10) {
                                    Button(action: { vm.selectFilesForAnalysis() }) {
                                        Image(systemName: "paperclip")
                                            .font(.system(size: 18))
                                            .foregroundColor(.secondary)
                                    }
                                    .buttonStyle(.plain)

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
                        
                        if vm.showCodeSidebar {
                            Divider()
                            CodeSidebarView()
                                .transition(.move(edge: .trailing))
                        }
                    }
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
            // LEFT SIDE: Badges
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 20) {
                    MetricBadge(label: "Mac RAM", value: "\(vm.metrics.sys_ram_pct) (\(vm.metrics.sys_ram_gb))")
                    MetricBadge(label: "Mac CPU", value: vm.metrics.sys_cpu)
                    MetricBadge(label: "Thermal", value: vm.metrics.thermal)
                }
                HStack(spacing: 20) {
                    MetricBadge(label: "Harvey RAM", value: vm.metrics.harvey_ram_gb)
                    MetricBadge(label: "Harvey CPU", value: vm.metrics.harvey_cpu)
                }
            }
            .frame(width: 280)
            
            Divider().frame(height: 70)
            
            // RIGHT SIDE: Live Graphs
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("CPU History").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundColor(.secondary)
                    Chart(vm.cpuHistory) { point in
                        LineMark(
                            x: .value("Time", point.time),
                            y: .value("CPU", point.value)
                        )
                        .foregroundStyle(Color.blue.gradient)
                        .interpolationMethod(.catmullRom) // Smooth curves
                        
                        AreaMark(
                            x: .value("Time", point.time),
                            y: .value("CPU", point.value)
                        )
                        .foregroundStyle(LinearGradient(colors: [Color.blue.opacity(0.3), .clear], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.catmullRom)
                    }
                    .chartYScale(domain: 0...100)
                    .chartXAxis(.hidden)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("RAM History (GB)").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundColor(.secondary)
                    Chart(vm.ramHistory) { point in
                        LineMark(
                            x: .value("Time", point.time),
                            y: .value("RAM", point.value)
                        )
                        .foregroundStyle(Color.purple.gradient)
                        .interpolationMethod(.catmullRom)
                        
                        AreaMark(
                            x: .value("Time", point.time),
                            y: .value("RAM", point.value)
                        )
                        .foregroundStyle(LinearGradient(colors: [Color.purple.opacity(0.3), .clear], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.catmullRom)
                    }
                    .chartYScale(domain: 0...24) // Assuming Mac is ~16GB-24GB max
                    .chartXAxis(.hidden)
                }
            }
            .frame(height: 70)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.04))
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

// MARK: - Message Bubble View
struct MessageBubbleView: View {
    let message: ChatMessage
    var onRegenerate: () -> Void
    
    @State private var isThoughtExpanded: Bool = false
    @EnvironmentObject var vm: ChatViewModel
    
    var isUser: Bool { message.role == "user" }
    
    private func styleInlineCode(_ raw: String) -> AttributedString {
        do {
            var attrString = try AttributedString(
                markdown: raw,
                options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
            )
            for run in attrString.runs {
                if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                    attrString[run.range].backgroundColor = Color.gray.opacity(0.2)
                    attrString[run.range].font = .system(size: 13, design: .monospaced)
                    attrString[run.range].foregroundColor = Color.primary
                }
            }
            return attrString
        } catch {
            return AttributedString(raw)
        }
    }

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
                            ForEach(vm.parseBlocks(raw: message.content)) { block in
                                if block.isCode {
                                    CodeBlockContainer(language: block.language, code: block.text)
                                } else {
                                    Text(styleInlineCode(block.text))
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 10)
                                        .foregroundColor(.primary)
                                        .background(Color.gray.opacity(0.18))
                                        .cornerRadius(16)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    } else if message.thought.isEmpty && vm.isGenerating {
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
}

// 🔥 UPGRADED: Code Block Container with Native Syntax Highlighting
struct CodeBlockContainer: View {
    let language: String
    let code: String
    @State private var isCodeExpanded: Bool = true
    @State private var isHovering: Bool = false
    @EnvironmentObject var vm: ChatViewModel
    
    var extractedFileName: String {
        let lines = code.components(separatedBy: .newlines)
        if let firstLine = lines.first {
            let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("#") || trimmed.hasPrefix("<!--") {
                let name = trimmed.replacingOccurrences(of: "//", with: "")
                                  .replacingOccurrences(of: "#", with: "")
                                  .replacingOccurrences(of: "<!--", with: "")
                                  .replacingOccurrences(of: "-->", with: "")
                                  .trimmingCharacters(in: .whitespaces)
                if name.contains(".") { return name }
            }
        }
        return ""
    }
    
    private func colorizeCode(_ code: String) -> AttributedString {
        var attr = AttributedString(code)
        attr.font = .system(size: 13, design: .monospaced)
        attr.foregroundColor = Color(red: 0.85, green: 0.85, blue: 0.9)
        
        let nsString = code as NSString
        let keywordColor = Color(red: 0.98, green: 0.45, blue: 0.65)
        let stringColor = Color(red: 0.95, green: 0.78, blue: 0.45)
        let commentColor = Color(red: 0.45, green: 0.75, blue: 0.45)
        let numberColor = Color(red: 0.55, green: 0.75, blue: 0.95)
        
        let patterns: [(String, Color)] = [
            ("//.*|#.*", commentColor),
            ("\".*?\"|'.*?'", stringColor),
            ("\\b\\d+(\\.\\d+)?\\b", numberColor),
            ("\\b(import|func|def|class|struct|let|var|if|else|return|guard|for|in|while|switch|case|default|self|true|false|nil|None|async|await|try|catch|print)\\b", keywordColor)
        ]
        
        for (pattern, color) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let matches = regex.matches(in: code, options: [], range: NSRange(location: 0, length: nsString.length))
                for match in matches {
                    if let stringRange = Range(match.range, in: code),
                       let attrRange = Range<AttributedString.Index>(stringRange, in: attr) {
                        attr[attrRange].foregroundColor = color
                    }
                }
            }
        }
        return attr
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Circle().fill(Color.red.opacity(0.8)).frame(width: 10, height: 10)
                    Circle().fill(Color.yellow.opacity(0.8)).frame(width: 10, height: 10)
                    Circle().fill(Color.green.opacity(0.8)).frame(width: 10, height: 10)
                }
                .padding(.trailing, 4)
                
                Text(language.capitalized.isEmpty ? "Code" : language.capitalized)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.gray)
                
                if !extractedFileName.isEmpty {
                    Text(extractedFileName)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.7))
                        .padding(.leading, 4)
                }
                
                Spacer()
                
                HStack(spacing: 12) {
                    Button(action: {
                        withAnimation(.spring()) { isCodeExpanded.toggle() }
                    }) {
                        Image(systemName: isCodeExpanded ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.plain)
                    .help(isCodeExpanded ? "Collapse Code" : "Expand Code")

                    Button(action: {
                        let panel = NSSavePanel()
                        panel.allowedContentTypes = [.text, .plainText]
                        let ext = language.lowercased() == "bash" ? "sh" : (language.lowercased() == "python" ? "py" : "txt")
                        let defaultName = extractedFileName.isEmpty ? "snippet.\(ext)" : extractedFileName
                        panel.nameFieldStringValue = defaultName
                        if panel.runModal() == .OK, let url = panel.url {
                            try? code.write(to: url, atomically: true, encoding: .utf8)
                            vm.triggerNativeNotification("Snippet saved.")
                        }
                    }) {
                        Image(systemName: "arrow.down.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Download Snippet")

                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                        vm.triggerNativeNotification("Code copied to clipboard.")
                    }) {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .help("Copy Code")
                }
                .foregroundColor(.gray)
                .opacity(isHovering ? 1.0 : 0.6)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.4))
            
            if isCodeExpanded {
                Divider().background(Color.white.opacity(0.1))
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(colorizeCode(code))
                        .padding(14)
                        .textSelection(.enabled) 
                }
            }
        }
        .background(Color(red: 0.12, green: 0.12, blue: 0.14))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.2), radius: 5, x: 0, y: 2)
        .padding(.vertical, 4)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                self.isHovering = hovering
            }
        }
        .environment(\.colorScheme, .dark)
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
                .background(Color.black.opacity(0.9))
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