import AVFoundation
import Combine
@preconcurrency import Speech

@MainActor
final class DreamSpeechInput: ObservableObject {
    @Published private(set) var transcript = ""
    @Published private(set) var isRecording = false
    @Published var errorMessage: String?

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: PublicLanguage.speechLocale)
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func toggle() async {
        if isRecording { stop(); return }
        let authorized = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard authorized, await AVAudioApplication.requestRecordPermission() else {
            errorMessage = String(localized: "请允许麦克风和语音识别，或使用文字输入。")
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            errorMessage = String(localized: "当前语音识别不可用，请使用文字输入。")
            return
        }
        do {
            transcript = ""
            errorMessage = nil
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement,
                                                             options: .duckOthers)
            try AVAudioSession.sharedInstance().setActive(true)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            self.request = request
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()
            isRecording = true
            task = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
                let words = result?.bestTranscription.formattedString
                let failure = error?.localizedDescription
                Task { @MainActor [weak self] in
                    guard self?.isRecording == true else { return }
                    if let words { self?.transcript = words }
                    if let failure {
                        self?.errorMessage = failure
                        self?.stop()
                    }
                }
            }
        } catch {
            errorMessage = PublicLanguage.errorDescription(error)
            stop()
        }
    }

    func stop() {
        guard isRecording || engine.isRunning else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false,
                                                       options: .notifyOthersOnDeactivation)
    }
}
