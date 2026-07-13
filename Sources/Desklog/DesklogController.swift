import AppKit
import DesklogCore
import Foundation

@MainActor
final class DesklogController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isStarting = false
    @Published private(set) var isTerminating = false
    @Published private(set) var isCapturing = false
    @Published private(set) var isSummarizing = false
    @Published private(set) var isTestingOllama = false
    @Published private(set) var ollamaTestSucceeded: Bool?
    @Published private(set) var ollamaTestMessage = "未テスト"
    @Published private(set) var nextScheduledSummaryAt: Date?
    @Published private(set) var lastCaptureAt: Date?
    @Published private(set) var latestOCR = ""
    @Published private(set) var lastSummary = ""
    @Published private(set) var speakerProfiles: [SpeakerProfile] = []
    @Published private(set) var recentSpeakerObservations: [SpeakerObservation] = []
    @Published private(set) var availableCaptureWindows: [ExcludedCaptureWindow] = []
    @Published private(set) var isLoadingCaptureWindows = false
    @Published private(set) var isUpdatingSpeaker = false
    @Published private(set) var updatingSpeakerID: String?
    @Published private(set) var updatingObservationID: UUID?
    @Published var permissionSetupRequested = false
    @Published var statusMessage = "停止中"
    @Published var errorMessage: String?
    @Published var configuration: DesklogConfiguration {
        didSet {
            configurationStore.save(configuration)
            if configuration.excludedCaptureWindows != oldValue.excludedCaptureWindows {
                // Changes apply from the next capture. Cancel the current OCR
                // attempt so pixels captured with the previous policy are not
                // subsequently saved as a new result.
                captureAttemptID = nil
                screenOCR.cancelPendingCaptures()
                screenOCR.updateCaptureExclusionPolicy(
                    desklogConfiguration: configuration
                )
            }
            if configuration.summaryScheduleEnabled != oldValue.summaryScheduleEnabled ||
                configuration.summaryScheduleHour != oldValue.summaryScheduleHour ||
                configuration.summaryScheduleMinute != oldValue.summaryScheduleMinute {
                restartSummaryScheduler()
            }
        }
    }

    let speechTranscriber = SpeechTranscriber()
    let permissions = PermissionCoordinator()
    let store: WorklogStore
    private let speakerIdentityStore = SpeakerIdentityStore()
    private let configurationStore = ConfigurationStore()
    private let screenOCR = ScreenOCRService()
    private var captureLoop: Task<Void, Never>?
    private var summarySchedulerTask: Task<Void, Never>?
    private var startAttemptID: UUID?
    private var captureAttemptID: UUID?
    private var pendingTranscriptWrites = 0
    private var pendingOperations = 0
    private var summaryTask: Task<Void, Never>?
    private var ollamaTestTask: Task<Void, Never>?
    private var processActivity: NSObjectProtocol?
    private var applicationActiveObserver: NSObjectProtocol?

    init() {
        configuration = configurationStore.load()
        store = WorklogStore()
        screenOCR.updateCaptureExclusionPolicy(desklogConfiguration: configuration)
        Task {
            try? await store.prepare()
            if let events = try? await store.events(from: .distantPast, to: .distantFuture) {
                var referenceEventIDByProfileID: [String: UUID] = [:]
                for event in events where event.kind == .speakerLabel {
                    guard let target = event.metadata["target_event_id"],
                          let eventID = UUID(uuidString: target),
                          let profileID = event.metadata["canonical_speaker_profile_id"]
                            ?? event.metadata["speaker_profile_id"] else {
                        continue
                    }
                    referenceEventIDByProfileID[profileID] = eventID
                }
                _ = try? await speakerIdentityStore.restoreLegacyConfirmedReferences(
                    eventIDByProfileID: referenceEventIDByProfileID
                )
            }
            // Older builds allowed two profile cards to be assigned the same
            // person name. Consolidate those clusters at launch so existing
            // duplicate people immediately become additional voice anchors.
            _ = try? await speakerIdentityStore.consolidateProfilesWithMatchingNames()
            await reloadSpeakerData()
        }
        applicationActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshPermissions()
            }
        }
        restartSummaryScheduler()
    }

    func start() {
        guard !isRunning, !isStarting, !isTerminating else { return }
        errorMessage = nil
        refreshPermissions()
        let gate = captureReadiness
        guard gate.hasEnabledCaptureSource else {
            permissionSetupRequested = true
            statusMessage = "記録する項目を選んでください"
            return
        }
        guard gate.canStart else {
            permissionSetupRequested = true
            statusMessage = "記録を始める準備が必要です"
            return
        }

        isStarting = true
        statusMessage = "ローカルモデルを確認中…"
        let attemptID = UUID()
        let startConfiguration = configuration
        startAttemptID = attemptID

        Task {
            do {
                if startConfiguration.microphoneCaptureEnabled {
                    try speechTranscriber.validateLocalResources(configuration: startConfiguration)
                    try await speechTranscriber.prepareLocalModels()
                    refreshPermissions()
                    guard startAttemptID == attemptID else { return }
                    try speechTranscriber.start(configuration: startConfiguration) { [weak self] update in
                        self?.recordTranscript(update, configuration: startConfiguration)
                    }
                }
                guard startAttemptID == attemptID else {
                    speechTranscriber.stop()
                    return
                }
                startAttemptID = nil
                isRunning = true
                isStarting = false
                permissionSetupRequested = false
                statusMessage = "記録中"
                processActivity = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiated, .idleSystemSleepDisabled],
                    reason: "Desklog is collecting the local worklog"
                )
                if startConfiguration.screenCaptureEnabled {
                    beginCaptureLoop()
                }
                let sources = [
                    startConfiguration.screenCaptureEnabled ? "画面OCR" : nil,
                    startConfiguration.microphoneCaptureEnabled ? "マイク音声" : nil
                ].compactMap { $0 }.joined(separator: "・")
                await appendSystemEvent("記録を開始しました（\(sources)）。")
            } catch {
                guard startAttemptID == attemptID else { return }
                startAttemptID = nil
                isStarting = false
                fail(error)
            }
        }
    }

    func stop() {
        guard isRunning || isStarting || isCapturing else { return }
        let wasRunning = isRunning
        let wasStarting = isStarting
        startAttemptID = nil
        captureAttemptID = nil
        captureLoop?.cancel()
        captureLoop = nil
        screenOCR.cancelPendingCaptures()
        speechTranscriber.stop()
        if let processActivity {
            ProcessInfo.processInfo.endActivity(processActivity)
            self.processActivity = nil
        }
        isStarting = false
        isRunning = false
        statusMessage = wasStarting && !wasRunning ? "準備を中止しました" : "停止中"
        if wasRunning {
            queueSystemEvent("記録を停止しました。")
        }
    }

    func requestTermination() {
        NSApplication.shared.terminate(nil)
    }

    /// Called by the application delegate for menu, Dock, keyboard, logout,
    /// and other normal macOS termination paths before allowing the process to exit.
    func prepareForTermination() async {
        if !isTerminating {
            isTerminating = true
            stop()
            statusMessage = "最後の文字起こしを保存して終了します…"
        }
        summaryTask?.cancel()
        ollamaTestTask?.cancel()
        await speechTranscriber.finishPendingTranscriptionsForTermination()
        // ScreenCaptureKit/Vision do not promise that an in-flight system call
        // will react to Swift task cancellation. Give local persistence a short,
        // shared grace period, then let the app delegate's hard deadline finish
        // termination instead of leaving Cmd-Q or logout stuck forever.
        let pendingWorkDeadline = Date().addingTimeInterval(5)
        await waitForPendingTranscriptWrites(until: pendingWorkDeadline)
        await waitForPendingOperations(until: pendingWorkDeadline)
    }

    func captureNow() async {
        guard !isTerminating else { return }
        guard configuration.screenCaptureEnabled else {
            statusMessage = "画面OCRは設定でオフです"
            return
        }
        if isRunning {
            refreshPermissions()
            guard isRunning else { return }
        } else {
            permissions.refresh()
        }
        guard permissions.screenCaptureStatus == .authorized else {
            permissionSetupRequested = true
            statusMessage = "画面収録の許可が必要です"
            return
        }
        guard !isCapturing else { return }
        beginPendingOperation()
        errorMessage = nil
        isCapturing = true
        let attemptID = UUID()
        captureAttemptID = attemptID
        defer {
            if captureAttemptID == attemptID { captureAttemptID = nil }
            isCapturing = false
            finishPendingOperation()
        }
        let timestamp = Date()
        var artifactTracker = CaptureArtifactTracker(urls: [])
        do {
            let results = try await screenOCR.capture(
                store: store,
                configuration: configuration,
                at: timestamp
            )
            artifactTracker = CaptureArtifactTracker(urls: results.compactMap { result in
                result.imagePath.map { URL(fileURLWithPath: $0) }
            })
            guard captureAttemptID == attemptID else {
                artifactTracker.discardUnpersisted()
                return
            }
            for result in results {
                guard captureAttemptID == attemptID else {
                    artifactTracker.discardUnpersisted()
                    return
                }
                guard !result.text.isEmpty else { continue }
                var metadata = ["display_title": result.displayTitle]
                if let imagePath = result.imagePath {
                    metadata["image_path"] = imagePath
                }
                try await store.append(.init(
                    timestamp: timestamp,
                    kind: .screenOCR,
                    text: result.text,
                    metadata: metadata
                ))
                artifactTracker.markPersisted(result.imagePath.map { URL(fileURLWithPath: $0) })
            }
            artifactTracker.discardUnpersisted()
            guard captureAttemptID == attemptID else { return }
            latestOCR = results.map(\.text).joined(separator: "\n\n")
            lastCaptureAt = timestamp
            statusMessage = isRunning ? "記録中" : "キャプチャ完了"
        } catch is CancellationError {
            artifactTracker.discardUnpersisted()
            // Stopping a recording intentionally cancels in-flight OCR without
            // surfacing a misleading error or overwriting the stopped state.
        } catch {
            artifactTracker.discardUnpersisted()
            guard captureAttemptID == attemptID else { return }
            fail(error, keepRunning: true)
        }
    }

    func summarize() {
        guard !isSummarizing, !isTerminating else { return }
        isSummarizing = true
        beginPendingOperation()
        errorMessage = nil
        statusMessage = "Ollamaで要約中…"
        let summaryConfiguration = configuration

        summaryTask = Task {
            defer {
                isSummarizing = false
                summaryTask = nil
                finishPendingOperation()
            }
            do {
                let end = Date()
                let start = end.addingTimeInterval(-Double(summaryConfiguration.summaryHours) * 3_600)
                let events = try await store.events(from: start, to: end)
                let profiles = try await speakerIdentityStore.profiles()
                let input = try TimelineBuilder.build(
                    events: events,
                    start: start,
                    end: end,
                    speakerProfiles: profiles
                )
                let client = OllamaClient(
                    baseURL: summaryConfiguration.ollamaBaseURL,
                    model: summaryConfiguration.ollamaModel
                )
                let summary = try await client.summarize(
                    input,
                    summaryPrompt: summaryConfiguration.summaryPrompt
                )
                let url = try await store.saveSummary(summary, at: end)
                try await store.append(.init(
                    timestamp: end,
                    kind: .summary,
                    text: summary,
                    metadata: ["file_path": url.path, "model": summaryConfiguration.ollamaModel]
                ))
                lastSummary = summary
                statusMessage = isRunning ? "記録中" : "要約完了"
            } catch {
                if !Task.isCancelled { fail(error, keepRunning: true) }
            }
        }
    }

    func openLogDirectory() {
        NSWorkspace.shared.open(store.rootDirectory)
    }

    func dismissError() {
        errorMessage = nil
    }

    func openMicrophonePrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
    }

    func openScreenCapturePrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func retryScreenCaptureRegistration() {
        errorMessage = nil
        permissionSetupRequested = true
        Task {
            await permissions.retryScreenCaptureRegistration()
            statusMessage = permissions.screenCaptureStatus == .authorized
                ? "画面収録を許可済み"
                : "システム設定でDesklogを許可してください"
        }
    }

    func refreshAvailableCaptureWindows() {
        permissions.refresh()
        guard permissions.screenCaptureStatus == .authorized else {
            permissionSetupRequested = true
            statusMessage = "ウィンドウ一覧の表示には画面収録の許可が必要です"
            return
        }
        guard !isLoadingCaptureWindows else { return }
        isLoadingCaptureWindows = true
        Task {
            defer { isLoadingCaptureWindows = false }
            do {
                availableCaptureWindows = try await screenOCR.availableWindows()
            } catch {
                fail(error, keepRunning: true)
            }
        }
    }

    func requestEnabledPermissions() {
        errorMessage = nil
        permissionSetupRequested = true
        statusMessage = "必要な権限を確認中…"
        let screenCaptureEnabled = configuration.screenCaptureEnabled
        let microphoneEnabled = configuration.microphoneCaptureEnabled
        Task {
            await permissions.requestEnabledPermissions(
                screenCaptureEnabled: screenCaptureEnabled,
                microphoneEnabled: microphoneEnabled
            )
            let gate = captureReadiness
            if gate.canStart {
                statusMessage = isRunning ? "記録中" : "必要な権限を許可済み"
            } else if screenCaptureEnabled,
                      permissions.screenCaptureStatus == .denied,
                      !microphoneEnabled || permissions.microphoneStatus != .notDetermined {
                statusMessage = "画面収録を有効にした後、一度だけ再起動してください"
            } else {
                statusMessage = "必要な権限を確認してください"
            }
        }
    }

    var captureReadiness: CaptureReadinessGate {
        CaptureReadinessGate(
            screenCaptureEnabled: configuration.screenCaptureEnabled,
            microphoneCaptureEnabled: configuration.microphoneCaptureEnabled,
            screenCaptureStatus: permissions.screenCaptureStatus,
            microphoneStatus: permissions.microphoneStatus
        )
    }

    func refreshPermissions() {
        permissions.refresh()
        guard (isRunning || isStarting), !captureReadiness.canStart else { return }
        stop()
        errorMessage = "画面収録またはマイクの権限が利用できなくなったため、準備・記録を停止しました。確認してから再開してください。"
        permissionSetupRequested = true
    }

    func testOllamaConnection() {
        guard !isTestingOllama, !isTerminating else { return }
        isTestingOllama = true
        beginPendingOperation()
        ollamaTestSucceeded = nil
        ollamaTestMessage = "接続を確認中…"
        let baseURL = configuration.ollamaBaseURL
        let model = configuration.ollamaModel

        ollamaTestTask = Task {
            defer {
                isTestingOllama = false
                ollamaTestTask = nil
                finishPendingOperation()
            }
            do {
                let info = try await OllamaClient(baseURL: baseURL, model: model).testConnection()
                ollamaTestSucceeded = info.configuredModelAvailable
                if info.configuredModelAvailable {
                    ollamaTestMessage = "接続成功（Ollama \(info.version)）。\(model)を利用できます。"
                } else {
                    let available = info.models.isEmpty ? "インストール済みモデルなし" : info.models.joined(separator: ", ")
                    ollamaTestMessage = "Ollama \(info.version)へ接続できましたが、\(model)がありません。利用可能: \(available)"
                }
            } catch {
                if !Task.isCancelled {
                    ollamaTestSucceeded = false
                    ollamaTestMessage = error.localizedDescription
                }
            }
        }
    }

    func labelSpeaker(observationID: UUID, name: String, isSelf: Bool) {
        guard !isUpdatingSpeaker, !isTerminating else { return }
        isUpdatingSpeaker = true
        beginPendingOperation()
        updatingObservationID = observationID
        errorMessage = nil
        Task {
            defer {
                isUpdatingSpeaker = false
                updatingObservationID = nil
                finishPendingOperation()
            }
            do {
                let result = try await speakerIdentityStore.labelObservation(
                    id: observationID,
                    name: name,
                    isSelf: isSelf
                )
                // Publish the persisted profile before doing secondary log I/O
                // so the live transcript relabels immediately even if logging fails.
                await reloadSpeakerData()
                try await store.append(.init(
                    kind: .speakerLabel,
                    text: "話者 \(result.sourceProfileID) を \(result.profile.displayName) として登録しました。",
                    metadata: [
                        "target_event_id": result.observation.eventID.uuidString,
                        "speaker_profile_id": result.sourceProfileID,
                        "canonical_speaker_profile_id": result.profile.id,
                        "speaker_name": result.profile.name ?? name,
                        "is_self": String(result.profile.isSelf)
                    ]
                ))
                statusMessage = isRunning ? "記録中" : "話者を登録しました"
            } catch {
                fail(error, keepRunning: true)
            }
        }
    }

    func updateSpeaker(profileID: String, name: String, isSelf: Bool) {
        guard !isUpdatingSpeaker, !isTerminating else { return }
        isUpdatingSpeaker = true
        beginPendingOperation()
        updatingSpeakerID = profileID
        errorMessage = nil
        Task {
            defer {
                isUpdatingSpeaker = false
                updatingSpeakerID = nil
                finishPendingOperation()
            }
            do {
                let profile = try await speakerIdentityStore.updateProfile(
                    id: profileID,
                    name: name,
                    isSelf: isSelf
                )
                await reloadSpeakerData()
                try await store.append(.init(
                    kind: .speakerLabel,
                    text: "話者 \(profile.id) の登録を \(profile.displayName) に更新しました。",
                    metadata: [
                        "speaker_profile_id": profile.id,
                        "speaker_name": profile.name ?? name,
                        "is_self": String(profile.isSelf)
                    ]
                ))
                statusMessage = isRunning ? "記録中" : "話者情報を更新しました"
            } catch {
                fail(error, keepRunning: true)
            }
        }
    }

    private func beginCaptureLoop() {
        captureLoop?.cancel()
        captureLoop = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.captureNow()
                let seconds = max(10, self.configuration.captureIntervalSeconds)
                do {
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                } catch {
                    return
                }
            }
        }
    }

    private func restartSummaryScheduler() {
        summarySchedulerTask?.cancel()
        summarySchedulerTask = nil
        nextScheduledSummaryAt = nil
        guard configuration.summaryScheduleEnabled else { return }

        let nextDate = Self.nextSummaryDate(
            hour: configuration.summaryScheduleHour,
            minute: configuration.summaryScheduleMinute
        )
        nextScheduledSummaryAt = nextDate
        summarySchedulerTask = Task { [weak self] in
            let delay = max(0, nextDate.timeIntervalSinceNow)
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.summarize()
            self.restartSummaryScheduler()
        }
    }

    private static func nextSummaryDate(hour: Int, minute: Int, now: Date = Date()) -> Date {
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = min(23, max(0, hour))
        components.minute = min(59, max(0, minute))
        components.second = 0
        let today = calendar.date(from: components) ?? now
        if today > now { return today }
        return calendar.date(byAdding: .day, value: 1, to: today) ?? now.addingTimeInterval(86_400)
    }

    private func recordTranscript(
        _ update: TranscriptUpdate,
        configuration transcriptConfiguration: DesklogConfiguration
    ) {
        pendingTranscriptWrites += 1
        Task {
            defer { finishTranscriptWrite() }
            let timestamp = Date()
            do {
                var metadata = [
                    "segment_id": update.segmentID,
                    "is_final": String(update.isFinal),
                    "locale": transcriptConfiguration.speechLocale,
                    "engine": "whisper.cpp",
                    "model": URL(fileURLWithPath: transcriptConfiguration.whisperModelPath).lastPathComponent,
                    "diarization_engine": "SpeakerKit/Pyannote",
                    "local_segment_speaker": String(update.localSpeakerID)
                ]
                var match: SpeakerMatch?
                if !update.speakerEmbedding.isEmpty {
                    let identified = try await speakerIdentityStore.identify(
                        embedding: update.speakerEmbedding,
                        at: timestamp
                    )
                    match = identified
                    speechTranscriber.resolveSpeaker(
                        segmentID: update.segmentID,
                        profileID: identified.profile.id
                    )
                    metadata["speaker_profile_id"] = identified.profile.id
                    metadata["speaker_id"] = identified.profile.id
                    metadata["is_self"] = String(identified.profile.isSelf)
                    if let name = identified.profile.name { metadata["speaker_name"] = name }
                    if let distance = identified.distance { metadata["speaker_distance"] = String(distance) }
                } else {
                    metadata["speaker_profile_id"] = "Speaker-Unidentified"
                    metadata["speaker_id"] = "Speaker-Unidentified"
                }

                let event = WorklogEvent(
                    timestamp: timestamp,
                    kind: .speechTranscript,
                    text: update.text,
                    metadata: metadata
                )
                try await store.append(event)
                if let match {
                    _ = try await speakerIdentityStore.recordObservation(
                        eventID: event.id,
                        timestamp: timestamp,
                        match: match,
                        text: update.text,
                        embedding: update.speakerEmbedding
                    )
                    await reloadSpeakerData()
                }
            } catch {
                fail(error, keepRunning: true)
            }
        }
    }

    private func waitForPendingTranscriptWrites(until deadline: Date) async {
        while pendingTranscriptWrites > 0, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func finishTranscriptWrite() {
        pendingTranscriptWrites = max(0, pendingTranscriptWrites - 1)
    }

    private func beginPendingOperation() {
        pendingOperations += 1
    }

    private func finishPendingOperation() {
        pendingOperations = max(0, pendingOperations - 1)
    }

    private func waitForPendingOperations(until deadline: Date) async {
        while pendingOperations > 0, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func reloadSpeakerData() async {
        do {
            let profiles = try await speakerIdentityStore.profiles()
            let observations = try await speakerIdentityStore.recentObservations(limit: 100)
            speakerProfiles = profiles
            recentSpeakerObservations = observations
            speechTranscriber.replaceSpeakerProfiles(profiles)
        } catch {
            errorMessage = "話者データを読み込めません: \(error.localizedDescription)"
        }
    }

    private func appendSystemEvent(_ text: String) async {
        beginPendingOperation()
        defer { finishPendingOperation() }
        try? await store.append(.init(kind: .system, text: text))
    }

    private func queueSystemEvent(_ text: String) {
        beginPendingOperation()
        Task {
            defer { finishPendingOperation() }
            try? await store.append(.init(kind: .system, text: text))
        }
    }

    private func fail(_ error: Error, keepRunning: Bool = false) {
        errorMessage = error.localizedDescription
        statusMessage = keepRunning && isRunning ? "記録中（一部エラー）" : "エラー"
        if !keepRunning { isRunning = false }
    }
}
