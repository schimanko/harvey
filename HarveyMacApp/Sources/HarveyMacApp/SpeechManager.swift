import Foundation
import Speech
import AVFoundation

class SpeechManager {
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var silenceTimer: Timer?
    private var isCallMode: Bool = false

    // Callbacks to talk to the ViewModel
    var onTranscriptionUpdated: ((String) -> Void)?
    var onSilenceDetected: ((String) -> Void)?

    init() {
        SFSpeechRecognizer.requestAuthorization { _ in }
    }

    func startListening(callMode: Bool = false) {
        isCallMode = callMode
        recognitionTask?.cancel()
        recognitionTask = nil

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else { return }
        
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.requiresOnDeviceRecognition = true

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            self.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            print("AudioEngine error: \(error.localizedDescription)")
            return
        }

        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }
            if let result = result {
                let text = result.bestTranscription.formattedString
                self.onTranscriptionUpdated?(text)
                
                if self.isCallMode {
                    self.resetSilenceTimer(text: text)
                }
            }
            if error != nil || (result?.isFinal ?? false) {
                self.stopListening()
            }
        }
    }

    func stopListening() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask = nil
        silenceTimer?.invalidate()
    }
    
    private func resetSilenceTimer(text: String) {
        silenceTimer?.invalidate()
        // Wait 1.5 seconds after user stops talking to auto-send
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            guard let self = self, self.isCallMode, !text.isEmpty else { return }
            self.stopListening()
            self.onSilenceDetected?(text)
        }
    }
}