import AppKit
import DesklogCore
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var controller: DesklogController
    let openMainWindow: () -> Void

    var body: some View {
        if let alert = controller.audioAlertKind {
            Button {
                controller.dismissAudioAlertForTenMinutes()
            } label: {
                Label(alert.message, systemImage: "exclamationmark.triangle.fill")
            }
            .help("クリックすると、この表示を10分間隠します")
        } else if let state = controller.menuBarDisplayText {
            Text("状態: \(state)")
        }

        Button(controller.isRunning ? "記録を停止" : "記録を開始（画面のみ）") {
            controller.isRunning ? controller.stop() : controller.start()
        }
        .disabled(controller.isTerminating)

        if controller.isRunning {
            Button(controller.isAudioRecording || controller.isStarting ? "録音を停止" : "録音を開始") {
                controller.isAudioRecording || controller.isStarting
                    ? controller.stopAudioRecording()
                    : controller.startAudioRecording()
            }
            .disabled(
                controller.isTerminating ||
                    (!controller.configuration.microphoneCaptureEnabled && !controller.isAudioRecording)
            )
        }

        Button("要約を開始") { controller.summarize() }
            .disabled(controller.isSummarizing || controller.isTerminating)

        Divider()

        Button("Desklogを開く…") { openMainWindow() }
            .keyboardShortcut("o")

        Divider()

        Button("Desklogを終了") {
            controller.requestTermination()
        }
        .keyboardShortcut("q")
        .disabled(controller.isTerminating)
    }
}

struct MainWindowView: View {
    @ObservedObject var controller: DesklogController
    @State private var selection: Section = .dashboard

    private enum Section: String, CaseIterable, Identifiable {
        case dashboard = "ワークログ"
        case webex = "Webex"
        case speakers = "話者"
        case settings = "設定"

        var id: Self { self }
        var icon: String {
            switch self {
            case .dashboard: return "waveform.path.ecg"
            case .webex: return "bubble.left.and.bubble.right.fill"
            case .speakers: return "person.2.wave.2"
            case .settings: return "gearshape"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .tag(section)
            }
            .navigationTitle("Desklog")
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            VStack(spacing: 0) {
                if let error = controller.errorMessage {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(error)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        Button {
                            controller.dismissError()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .help("閉じる")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.red.opacity(0.08))
                    Divider()
                }

                Group {
                    switch selection {
                    case .dashboard:
                        DashboardView(controller: controller)
                    case .webex:
                        WebexSettingsView(controller: controller)
                    case .speakers:
                        SpeakerManagementView(controller: controller)
                    case .settings:
                        SettingsView(controller: controller)
                    }
                }
            }
        }
        .frame(minWidth: 780, minHeight: 560)
        .disabled(controller.isTerminating)
    }
}

private struct DashboardView: View {
    @ObservedObject var controller: DesklogController
    @ObservedObject private var speech: SpeechTranscriber
    @ObservedObject private var permissions: PermissionCoordinator
    @State private var showsOCRImageReview = false
    // Keep the review that opened this sheet stable while a retry publishes a
    // newer capture. A successful retry clears the controller's failure state,
    // but the sheet must remain able to show its success result and close.
    @State private var ocrImageReview: FailedOCRCaptureReview?

    init(controller: DesklogController) {
        self.controller = controller
        speech = controller.speechTranscriber
        permissions = controller.permissions
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Circle()
                        .fill(controller.isRunning ? Color.green : (controller.isStarting ? Color.orange : Color.secondary))
                        .frame(width: 10, height: 10)
                    Text(controller.statusMessage).font(.title2.bold())
                    Spacer()
                    if controller.isStarting || controller.isCapturing {
                        ProgressView().controlSize(.small)
                    }
                }

                if controller.isSummarizing {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(
                            value: Double(controller.summaryCompletedSteps),
                            total: Double(max(1, controller.summaryTotalSteps))
                        )
                        .tint(.blue)

                        HStack {
                            Text(summaryProgressLabel)
                            Spacer()
                            if controller.summaryTotalSteps > 0 {
                                Text(
                                    "\(controller.summaryCompletedSteps) / " +
                                        "\(controller.summaryTotalSteps)"
                                )
                                .monospacedDigit()
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("ワークログ要約の進捗")
                    .accessibilityValue(summaryProgressLabel)
                }

                if controller.permissionSetupRequested || !controller.canStartScreenRecording {
                    PermissionSetupView(controller: controller)
                }

                HStack {
                    Button(primaryActionTitle) {
                        controller.isRunning
                            ? controller.stop()
                            : controller.start()
                    }
                    .buttonStyle(.borderedProminent)

                    Button(audioActionTitle) {
                        controller.isAudioRecording || controller.isStarting
                            ? controller.stopAudioRecording()
                            : controller.startAudioRecording()
                    }
                    .disabled(
                        !controller.isRunning ||
                            (!controller.configuration.microphoneCaptureEnabled && !controller.isAudioRecording)
                    )

                    Button("今すぐキャプチャ") {
                        Task { await controller.captureNow() }
                    }
                    .disabled(
                        controller.isCapturing ||
                            !controller.configuration.screenCaptureEnabled
                    )

                    Button("ワークログを要約") { controller.summarize() }
                        .disabled(controller.isSummarizing)

                    Spacer()
                    Button("ログを開く") { controller.openLogDirectory() }
                }

                GroupBox("音声認識（ライブ）") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label(speech.audioStatus, systemImage: speech.hasReceivedAudioBuffers ? "mic.fill" : "mic")
                                .font(.caption)
                            Spacer()
                            Text(speech.inputDeviceName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: speech.inputLevel, total: 1)
                            .tint(speech.inputLevel >= 0.04 ? .green : .secondary)

                        if let speechError = speech.lastError {
                            Label(speechError, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }

                        ScrollView {
                            Text(speech.liveText.isEmpty ? "認識結果を待っています…" : speech.liveText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(minHeight: 54)

                        Text("12秒ごとに、境界の前後2秒を重ねて確定します。話者の登録・改名は、表示済みの発話にもすぐ反映されます。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .opacity(controller.configuration.microphoneCaptureEnabled ? 1 : 0.55)

                GroupBox("直近の画面OCR") {
                    VStack(alignment: .leading, spacing: 10) {
                        ScrollView {
                            Text(controller.latestOCR.isEmpty ? "まだキャプチャされていません。" : controller.latestOCR)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(minHeight: 120, maxHeight: 220)

                        if controller.latestOCRNeedsReview {
                            OCRReviewNotice(
                                hasSavedImage: controller.failedOCRCaptureReview != nil,
                                onReview: {
                                    ocrImageReview = controller.failedOCRCaptureReview
                                    controller.prepareFailedOCRReview()
                                    showsOCRImageReview = ocrImageReview != nil
                                },
                                onEnableSaving: {
                                    controller.configuration.saveScreenshots = true
                                }
                            )
                        }
                    }
                }

                if !controller.lastSummary.isEmpty {
                    GroupBox("直近の要約") {
                        ScrollView {
                            MarkdownSummaryView(markdown: controller.lastSummary)
                        }
                        .frame(minHeight: 180, maxHeight: 420)
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("ワークログ")
        .sheet(isPresented: $showsOCRImageReview) {
            if let review = ocrImageReview {
                OCRCaptureReviewSheet(controller: controller, review: review)
            }
        }
        .onChange(of: showsOCRImageReview) { _, isPresented in
            if !isPresented { ocrImageReview = nil }
        }
    }

    private var primaryActionTitle: String {
        if controller.isRunning { return "記録を停止" }
        return controller.canStartScreenRecording ? "記録を開始（画面のみ）" : "記録の準備"
    }

    private var audioActionTitle: String {
        if controller.isStarting { return "録音の準備を中止" }
        return controller.isAudioRecording ? "録音を停止" : "録音を開始"
    }

    private var summaryProgressLabel: String {
        guard controller.summaryTotalSteps > 0 else { return "要約するログを準備中…" }
        if controller.summaryCompletedSteps == controller.summaryTotalSteps {
            return "要約を保存中…"
        }
        return "10分チャンクを累積要約中"
    }
}

private struct OCRReviewNotice: View {
    let hasSavedImage: Bool
    let onReview: () -> Void
    let onEnableSaving: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Label(
                "文字を検出できませんでした。元画像と取得解像度を確認してください。",
                systemImage: "text.viewfinder"
            )
            .font(.callout)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)

            if hasSavedImage {
                Button("画像を確認", action: onReview)
                    .buttonStyle(.borderedProminent)
            } else {
                Button("画像確認を有効にする", action: onEnableSaving)
                    .help("次回から失敗時の画像を確認できるよう、スクリーンショット保存をオンにします")
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct OCRCaptureReviewSheet: View {
    @ObservedObject var controller: DesklogController
    let review: FailedOCRCaptureReview
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1

    private var displayedReview: FailedOCRCaptureReview {
        controller.ocrRetryCapture ?? review
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("OCR画像を確認")
                        .font(.title2.bold())
                    Text(review.displayTitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("閉じる") { dismiss() }
                    .disabled(controller.isRetryingOCR)
            }

            if let image = NSImage(contentsOfFile: displayedReview.imagePath) {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(
                            width: max(1, CGFloat(displayedReview.pixelWidth) * zoom),
                            height: max(1, CGFloat(displayedReview.pixelHeight) * zoom)
                        )
                        .background(Color.white)
                }
                .frame(minHeight: 320)
                .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 10) {
                    Text("表示倍率")
                    Slider(value: $zoom, in: 0.25...2, step: 0.25)
                    Text("\(Int(zoom * 100))%")
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }
                .font(.caption)
            } else {
                ContentUnavailableView(
                    "画像を読み込めません",
                    systemImage: "photo.badge.exclamationmark",
                    description: Text(displayedReview.imagePath)
                )
                .frame(minHeight: 320)
            }

            HStack {
                Label(
                    "\(displayedReview.pixelWidth) × \(displayedReview.pixelHeight) px",
                    systemImage: "rectangle.inset.filled"
                )
                Text("画面解像度に準拠")
                Spacer()
                Button("Finderで表示") {
                    NSWorkspace.shared.activateFileViewerSelecting([
                        URL(fileURLWithPath: displayedReview.imagePath)
                    ])
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Divider()

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("この画像にOCRしたい文字列がありますか？")
                        .font(.headline)

                    if controller.isRetryingOCR {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text(controller.ocrRetryMessage)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else if let succeeded = controller.ocrRetrySucceeded {
                        Label(
                            controller.ocrRetryMessage,
                            systemImage: succeeded
                                ? "checkmark.circle.fill"
                                : "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(succeeded ? .green : .orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("「はい」を選ぶと、このウィンドウを固定し、画面解像度のまま字幕領域を段階的に細かく切り出して、OCRできるまで直ちに再取得します。")
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        HStack {
                            Spacer()
                            Button("いいえ") {
                                controller.dismissFailedOCRReview()
                                dismiss()
                            }
                            Button("はい、OCRできるまで再取得") {
                                Task {
                                    await controller.retryFailedOCRUntilRecognized(review)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 820, minHeight: 620)
    }
}

private struct WebexSettingsView: View {
    @ObservedObject var controller: DesklogController
    @State private var accessToken = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Webex連携", systemImage: "bubble.left.and.bubble.right.fill")
                        .font(.largeTitle.bold())
                    Text("Personal Access Tokenを登録すると、DesklogがWebexの当日ログを収集します。")
                        .foregroundStyle(.secondary)
                }

                GroupBox("1. アクセストークンを取得") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Webex公式ページへサインインし、Personal Access Tokenをコピーしてください。")
                        Link(destination: WebexAPIClient.personalAccessTokenURL) {
                            Label(
                                "Webex公式のアクセストークン取得ページを開く",
                                systemImage: "arrow.up.right.square"
                            )
                        }
                        Text(WebexAPIClient.personalAccessTokenURL.absoluteString)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }

                GroupBox("2. アクセストークンを入力") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Webex Personal Access Token")
                            .font(.headline)
                        SecureField(
                            "Webexアクセストークン",
                            text: $accessToken,
                            prompt: Text(
                                controller.hasWebexCredential
                                    ? "新しいトークンを貼り付けて認証を更新"
                                    : "取得したトークンをここに貼り付け"
                            )
                        )
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.password)
                        .controlSize(.large)
                        .accessibilityLabel("Webexアクセストークン")
                        .onSubmit { connect() }

                        HStack(spacing: 12) {
                            Button(
                                controller.hasWebexCredential ? "トークンを更新" : "保存して接続",
                                action: connect
                            )
                            .buttonStyle(.borderedProminent)
                            .disabled(!canConnect)

                            if controller.isAuthenticatingWebex || controller.isSyncingWebex {
                                ProgressView().controlSize(.small)
                            }

                            Label(controller.webexStatusMessage, systemImage: statusIcon)
                                .foregroundStyle(statusColor)
                                .textSelection(.enabled)
                        }

                        Text("トークンは設定ファイルやログには書かず、このMacのKeychainだけに保存します。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }

                GroupBox("3. 収集") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(
                            "自分が投稿した日のスペースとDMを収集",
                            isOn: $controller.configuration.webexCollectionEnabled
                        )
                        .toggleStyle(.switch)
                        .disabled(!controller.hasWebexCredential)

                        Text("その日に自分が1件以上投稿したスペースとDMだけを対象に、同日の参加者全員の会話を収集します。返信は親メッセージ直下にまとめ、期間内の添付ファイルも保存します。")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 12) {
                            Button("今すぐ同期") { controller.syncWebexNow() }
                                .disabled(
                                    !controller.hasWebexCredential ||
                                        !controller.configuration.webexCollectionEnabled ||
                                        controller.isAuthenticatingWebex ||
                                        controller.isSyncingWebex
                                )

                            if controller.hasWebexCredential {
                                Button("認証情報を削除", role: .destructive) {
                                    controller.disconnectWebex()
                                }
                                .disabled(
                                    controller.isAuthenticatingWebex || controller.isSyncingWebex
                                )
                            }

                            if let lastSync = controller.lastWebexSyncAt {
                                Text("最終同期: \(lastSync.formatted(date: .abbreviated, time: .standard))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Text("暗号化などでWebexが検査できない添付も強制取得します。感染判定されたファイルはWebex側で取得できません。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }

                GroupBox("4. トラブルシュート") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Webex同期の処理段階、件数、HTTPステータス、安全化したエラー分類をJSONLで記録します。")
                            .fixedSize(horizontal: false, vertical: true)

                        Button {
                            controller.revealWebexDiagnosticLog()
                        } label: {
                            Label("診断ログをFinderで表示", systemImage: "doc.text.magnifyingglass")
                        }

                        if let diagnosticID = controller.lastWebexDiagnosticID {
                            Text("直近の診断ID: \(diagnosticID)")
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }

                        Text(controller.webexDiagnosticLogPath)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)

                        Text("アクセストークン、メッセージ本文、URL、Webex内部ID、表示名・メール、応答本文、添付名は診断ログに記録しません。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(24)
        }
        .navigationTitle("Webex")
    }

    private var canConnect: Bool {
        !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !controller.isAuthenticatingWebex
    }

    private var statusColor: Color {
        if controller.webexConnectionFailed { return .red }
        if controller.webexSyncWarning { return .orange }
        if controller.hasWebexCredential { return .green }
        return .secondary
    }

    private var statusIcon: String {
        if controller.webexConnectionFailed { return "xmark.circle.fill" }
        if controller.webexSyncWarning { return "exclamationmark.triangle.fill" }
        if controller.hasWebexCredential { return "checkmark.circle.fill" }
        return "circle"
    }

    private func connect() {
        guard canConnect else { return }
        let token = accessToken
        accessToken = ""
        controller.connectWebex(accessToken: token)
    }
}

private struct SettingsView: View {
    @ObservedObject var controller: DesklogController
    @ObservedObject private var permissions: PermissionCoordinator
    @State private var showsWindowExclusionPicker = false
    @State private var selectedExcludedWindowIDs: Set<String> = []

    init(controller: DesklogController) {
        self.controller = controller
        permissions = controller.permissions
    }

    var body: some View {
        Form {
            Section("収集") {
                Toggle("画面をOCRして記録", isOn: $controller.configuration.screenCaptureEnabled)
                    .disabled(controller.isRunning || controller.isStarting)
                Toggle("マイク音声を文字起こし", isOn: $controller.configuration.microphoneCaptureEnabled)
                    .disabled(controller.isRunning || controller.isStarting)
                Text("記録は画面OCRから開始します。マイクをオンにしていても、「録音を開始」を選ぶまでは音声を入力しません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("前面ウィンドウを1枚だけ取得します。除外対象なら、背面順の次のウィンドウを取得します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("取得しないウィンドウ")
                            .font(.headline)
                        Spacer()
                        Button("ウィンドウを選ぶ…") {
                            permissions.refresh()
                            guard permissions.screenCaptureStatus == .authorized else {
                                controller.permissionSetupRequested = true
                                controller.errorMessage =
                                    "ウィンドウを一覧表示するには、先に画面収録を許可してください。"
                                return
                            }
                            selectedExcludedWindowIDs = Set(
                                controller.configuration.excludedCaptureWindows.map(\.id)
                            )
                            showsWindowExclusionPicker = true
                            controller.refreshAvailableCaptureWindows()
                        }
                    }

                    if controller.configuration.excludedCaptureWindows.isEmpty {
                        Text("指定なし")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(controller.configuration.excludedCaptureWindows) { window in
                            HStack(spacing: 10) {
                                if let icon = excludedApplicationIcon(
                                    for: window.bundleIdentifier
                                ) {
                                    Image(nsImage: icon)
                                        .resizable()
                                        .frame(width: 28, height: 28)
                                } else {
                                    Image(systemName: "app")
                                        .frame(width: 28, height: 28)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(window.displayTitle)
                                    Text(window.applicationName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    removeExcludedCaptureWindow(window)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                }
                                .buttonStyle(.borderless)
                                .help("このウィンドウを取得対象へ戻す")
                                .accessibilityLabel(
                                    "\(window.displayTitle)を取得しない一覧から削除"
                                )
                            }
                        }
                    }

                    Text(captureExclusionHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Stepper(
                    "画面取得間隔: \(Int(controller.configuration.captureIntervalSeconds))秒",
                    value: $controller.configuration.captureIntervalSeconds,
                    in: 10...3_600,
                    step: 10
                )
                .disabled(!controller.configuration.screenCaptureEnabled)
                Text("画面はディスプレイのネイティブ解像度で取得します。字幕などの小さい文字は、解像度を変えずに画像をタイル分割してOCRします。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("スクリーンショットも保存", isOn: $controller.configuration.saveScreenshots)
                    .disabled(!controller.configuration.screenCaptureEnabled)
                TextField("OCR言語（カンマ区切り）", text: ocrLanguagesBinding)
                    .disabled(!controller.configuration.screenCaptureEnabled)
                TextField("音声認識ロケール", text: $controller.configuration.speechLocale)
                    .disabled(!controller.configuration.microphoneCaptureEnabled)
            }

            Section("Ollama") {
                TextField("URL", text: $controller.configuration.ollamaBaseURL)
                TextField("モデル", text: $controller.configuration.ollamaModel)

                HStack(alignment: .firstTextBaseline) {
                    Button("Ollama接続をテスト") { controller.testOllamaConnection() }
                        .disabled(controller.isTestingOllama)
                    if controller.isTestingOllama {
                        ProgressView().controlSize(.small)
                    }
                    Text(controller.ollamaTestMessage)
                        .font(.caption)
                        .foregroundStyle(ollamaStatusColor)
                        .textSelection(.enabled)
                }
            }

            Section("要約") {
                Stepper(
                    "直近 \(controller.configuration.summaryHours) 時間を要約",
                    value: $controller.configuration.summaryHours,
                    in: 1...24
                )

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("要約プロンプト")
                            .font(.headline)
                        Spacer()
                        Button("既定に戻す") {
                            controller.configuration.summaryPrompt =
                                DesklogConfiguration.defaultSummaryPrompt
                        }
                        .disabled(
                            controller.configuration.summaryPrompt ==
                                DesklogConfiguration.defaultSummaryPrompt
                        )
                    }

                    TextEditor(text: summaryPromptBinding)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 180)
                        .padding(6)
                        .scrollContentBackground(.hidden)
                        .background(Color(nsColor: .textBackgroundColor))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(nsColor: .separatorColor))
                        }

                    HStack(alignment: .top) {
                        Text("ログ本文と安全上の指示はDesklogが自動で追加します。変更は次回の要約から反映され、空欄の場合は既定のプロンプトを使います。")
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Text(
                            "\(controller.configuration.summaryPrompt.count) / " +
                                "\(DesklogConfiguration.maximumSummaryPromptCharacters)文字"
                        )
                        .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section("定期要約") {
                Toggle("毎日、指定時刻に要約する", isOn: $controller.configuration.summaryScheduleEnabled)

                DatePicker(
                    "実行時刻",
                    selection: summaryScheduleBinding,
                    displayedComponents: .hourAndMinute
                )
                .disabled(!controller.configuration.summaryScheduleEnabled)

                if let nextDate = controller.nextScheduledSummaryAt,
                   controller.configuration.summaryScheduleEnabled {
                    LabeledContent("次回実行") {
                        Text(nextDate.formatted(date: .abbreviated, time: .shortened))
                    }
                }

                Text("Desklogが起動している間に実行されます。Macがスリープ中の場合は、復帰後に実行されます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("外部操作") {
                Toggle(
                    "Raycastなどからの操作を許可",
                    isOn: $controller.configuration.externalControlEnabled
                )
                Text("オンにすると、このMacのほかのアプリからdesklog:// URLで記録・録音・要約を操作できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("記録の準備と権限") {
                PermissionSetupView(controller: controller, showsContainer: false)
            }

            Section("音声入力") {
                LabeledContent("STTエンジン") {
                    Text("Whisper.cpp（完全ローカル）")
                }
                LabeledContent("入力デバイス") {
                    Text(controller.speechTranscriber.inputDeviceName)
                }
                LabeledContent("マイク権限") {
                    Text(permissionLabel(permissions.microphoneStatus))
                }
                TextField("whisper-cliのパス", text: $controller.configuration.whisperExecutablePath)
                    .disabled(controller.isRunning || controller.isStarting)
                TextField("Whisperモデルのパス", text: $controller.configuration.whisperModelPath)
                    .disabled(controller.isRunning || controller.isStarting)
                LabeledContent("文字起こし") {
                    Text("12秒ごと（境界の前後2秒を重複）")
                }
                LabeledContent("Whisper構成") {
                    Label(
                        whisperReady ? "準備完了" : "実行ファイルまたはモデルがありません",
                        systemImage: whisperReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
                    )
                    .foregroundStyle(whisperReady ? .green : .orange)
                }
                Text("音声はメモリ上で分割し、一時WAVをWhisperで処理した直後に削除します。保存されるのは文字起こしだけです。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("話者認識") {
                LabeledContent("話者分離・特徴量") {
                    Text("SpeakerKit / Pyannote（完全ローカル）")
                }
                LabeledContent("話者モデル") {
                    Label(
                        controller.speechTranscriber.localSpeakerModelsReady
                            ? "配置済み"
                            : "未配置（make speaker-setup）",
                        systemImage: controller.speechTranscriber.localSpeakerModelsReady
                            ? "checkmark.circle.fill"
                            : "exclamationmark.circle.fill"
                    )
                    .foregroundStyle(
                        controller.speechTranscriber.localSpeakerModelsReady ? .green : .orange
                    )
                }
                Text("話者モデルは `make speaker-setup` で明示的に準備します。記録中のSpeakerKitはダウンロードを無効にした別プロセスで動き、macOS sandboxでも全ネットワークを遮断します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("ローカル処理") {
                Label("OCR・Whisper・話者認識はこのMac内で実行", systemImage: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                Label("要約先はlocalhostのOllamaだけ", systemImage: "network.badge.shield.half.filled")
                Label("Webex収集をオンにした場合だけWebex APIへ接続", systemImage: "network")
                Text("Webexの本文・添付はローカルに保存し、要約はlocalhostから外へ送りません。`make verify-local-only` で通信境界と保存権限のテストを再実行できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .navigationTitle("設定")
        .sheet(isPresented: $showsWindowExclusionPicker) {
            WindowExclusionPickerView(
                windows: controller.availableCaptureWindows,
                selectedWindowIDs: $selectedExcludedWindowIDs,
                isLoading: controller.isLoadingCaptureWindows,
                onRefresh: controller.refreshAvailableCaptureWindows,
                onCancel: { showsWindowExclusionPicker = false },
                onApply: applyExcludedCaptureWindows
            )
        }
    }

    private var ollamaStatusColor: Color {
        switch controller.ollamaTestSucceeded {
        case true: return .green
        case false: return .red
        case nil: return .secondary
        }
    }

    private var whisperReady: Bool {
        FileManager.default.isExecutableFile(atPath: controller.configuration.whisperExecutablePath) &&
            FileManager.default.fileExists(atPath: controller.configuration.whisperModelPath)
    }

    private func permissionLabel(_ status: DesklogPermissionStatus) -> String {
        switch status {
        case .notDetermined: return "未確認"
        case .authorized: return "許可済み"
        case .denied: return "システム設定で許可が必要"
        case .restricted: return "管理者により制限"
        }
    }

    private var captureExclusionHelp: String {
        if controller.configuration.excludedCaptureWindows.isEmpty {
            return "現在開いているウィンドウから、取得したくないものを選べます。記録中でも追加・削除できます。"
        }
        return "指定したウィンドウは取得候補から外れ、前面から背面順の次候補へ進みます。変更は次回の取得から反映されます。ウィンドウを閉じて作り直した場合は、もう一度選んでください。"
    }

    private func removeExcludedCaptureWindow(_ window: ExcludedCaptureWindow) {
        controller.configuration.excludedCaptureWindows.removeAll { $0.id == window.id }
    }

    private func applyExcludedCaptureWindows() {
        let availableIDs = Set(controller.availableCaptureWindows.map(\.id))
        let unavailableExisting = controller.configuration.excludedCaptureWindows.filter {
            !availableIDs.contains($0.id)
        }
        let selectedAvailable = controller.availableCaptureWindows.filter {
            selectedExcludedWindowIDs.contains($0.id)
        }
        controller.configuration.excludedCaptureWindows = unavailableExisting + selectedAvailable
        showsWindowExclusionPicker = false
    }

    private func excludedApplicationIcon(for bundleIdentifier: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private var ocrLanguagesBinding: Binding<String> {
        Binding(
            get: { controller.configuration.ocrLanguages.joined(separator: ",") },
            set: { value in
                controller.configuration.ocrLanguages = value
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        )
    }

    private var summaryPromptBinding: Binding<String> {
        Binding(
            get: { controller.configuration.summaryPrompt },
            set: { value in
                controller.configuration.summaryPrompt = String(
                    value.prefix(DesklogConfiguration.maximumSummaryPromptCharacters)
                )
            }
        )
    }

    private var summaryScheduleBinding: Binding<Date> {
        Binding(
            get: {
                var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
                components.hour = controller.configuration.summaryScheduleHour
                components.minute = controller.configuration.summaryScheduleMinute
                return Calendar.current.date(from: components) ?? Date()
            },
            set: { date in
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                var updated = controller.configuration
                updated.summaryScheduleHour = components.hour ?? 18
                updated.summaryScheduleMinute = components.minute ?? 0
                controller.configuration = updated
            }
        )
    }
}

private struct WindowExclusionPickerView: View {
    let windows: [ExcludedCaptureWindow]
    @Binding var selectedWindowIDs: Set<String>
    let isLoading: Bool
    let onRefresh: () -> Void
    let onCancel: () -> Void
    let onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("取得しないウィンドウを選択")
                        .font(.title2.bold())
                    Text("チェックしたウィンドウを次回の画面取得から除外します。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    onRefresh()
                } label: {
                    Label("更新", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }

            Group {
                if isLoading, windows.isEmpty {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("開いているウィンドウを確認中…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if windows.isEmpty {
                    ContentUnavailableView(
                        "選べるウィンドウがありません",
                        systemImage: "macwindow",
                        description: Text("対象のウィンドウを開いてから更新してください。")
                    )
                } else {
                    List(windows) { window in
                        Toggle(isOn: selectionBinding(for: window)) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(window.displayTitle)
                                Text(window.applicationName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .frame(minHeight: 320)

            HStack {
                Text("閉じたウィンドウは一覧に出ません。すでに除外済みの項目は設定画面で削除できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("キャンセル", action: onCancel)
                Button("反映", action: onApply)
                    .buttonStyle(.borderedProminent)
                    .disabled(isLoading)
            }
        }
        .padding(20)
        .frame(minWidth: 580, minHeight: 460)
    }

    private func selectionBinding(for window: ExcludedCaptureWindow) -> Binding<Bool> {
        Binding(
            get: { selectedWindowIDs.contains(window.id) },
            set: { isSelected in
                if isSelected {
                    selectedWindowIDs.insert(window.id)
                } else {
                    selectedWindowIDs.remove(window.id)
                }
            }
        )
    }
}

private struct PermissionSetupView: View {
    @ObservedObject var controller: DesklogController
    @ObservedObject private var permissions: PermissionCoordinator
    let showsContainer: Bool

    init(controller: DesklogController, showsContainer: Bool = true) {
        self.controller = controller
        permissions = controller.permissions
        self.showsContainer = showsContainer
    }

    var body: some View {
        if showsContainer {
            GroupBox {
                content
            } label: {
                Label("記録を始める準備", systemImage: "hand.raised.fill")
                    .font(.headline)
            }
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("使う機能に必要な権限をまとめて確認します。マイクを先に、再起動が必要になることがある画面収録を最後に確認するため、途中で再起動する必要はありません。取得・解析・保存はこのMac内で行います。")
                .font(.callout)
                .foregroundStyle(.secondary)

            if hasUndeterminedEnabledPermission {
                Button("必要な権限をまとめて許可") {
                    controller.requestEnabledPermissions()
                }
                .buttonStyle(.borderedProminent)
                .disabled(permissions.isRequesting)
            }

            if controller.configuration.screenCaptureEnabled {
                PermissionCard(
                    title: "画面収録",
                    detail: "前面から背面順に、除外されていない最初のウィンドウだけをOCRします。システム音声は取得しません。",
                    status: permissions.screenCaptureStatus
                ) {
                    screenActions
                }
            } else {
                disabledSource("画面OCRはオフです")
            }

            if controller.configuration.microphoneCaptureEnabled {
                PermissionCard(
                    title: "マイク",
                    detail: "「録音を開始」している間だけ周囲の会話をローカルWhisperで文字起こしします。一時音声は処理直後に削除し、文字起こしだけを保存します。",
                    status: permissions.microphoneStatus
                ) {
                    microphoneActions
                }
            } else {
                disabledSource("マイク文字起こしはオフです")
            }

            if controller.captureReadiness.canStart {
                Label("記録を始める準備が完了しました", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .fontWeight(.semibold)
            } else if !controller.configuration.screenCaptureEnabled {
                Label("記録を始めるには設定で画面OCRをオンにしてください", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, showsContainer ? 4 : 0)
    }

    @ViewBuilder
    private var screenActions: some View {
        switch permissions.screenCaptureStatus {
        case .notDetermined:
            Text("上のボタンからマイクと続けて許可します。")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .authorized:
            Text("取得しないウィンドウは設定でいつでも追加・削除できます。")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .denied:
            VStack(alignment: .leading, spacing: 7) {
                Text("システム設定の「プライバシーとセキュリティ」→「画面収録とシステムオーディオ録音」でDesklogをオンにしてください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("システム設定で変更") {
                        controller.openScreenCapturePrivacySettings()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("状態を再確認") { controller.refreshPermissions() }
                    Button("権限登録をやり直す") {
                        controller.retryScreenCaptureRegistration()
                    }
                    .disabled(permissions.isRequesting)
                }
            }
        case .restricted:
            Text("このMacの管理設定により変更できません。管理者へ確認してください。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var microphoneActions: some View {
        switch permissions.microphoneStatus {
        case .notDetermined:
            Text("上のボタンから画面収録より先に許可します。")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .authorized:
            EmptyView()
        case .denied:
            HStack {
                Button("システム設定で変更") { controller.openMicrophonePrivacySettings() }
                    .buttonStyle(.borderedProminent)
                Button("状態を再確認") { controller.refreshPermissions() }
            }
        case .restricted:
            Text("このMacの管理設定により変更できません。管理者へ確認してください。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func disabledSource(_ text: String) -> some View {
        Label(text, systemImage: "minus.circle")
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
    }

    private var hasUndeterminedEnabledPermission: Bool {
        (controller.configuration.screenCaptureEnabled &&
            permissions.screenCaptureStatus == .notDetermined) ||
        (controller.configuration.microphoneCaptureEnabled &&
            permissions.microphoneStatus == .notDetermined)
    }
}

private struct PermissionCard<Actions: View>: View {
    let title: String
    let detail: String
    let status: DesklogPermissionStatus
    let statusTextOverride: String?
    @ViewBuilder let actions: Actions

    init(
        title: String,
        detail: String,
        status: DesklogPermissionStatus,
        statusText: String? = nil,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.detail = detail
        self.status = status
        statusTextOverride = statusText
        self.actions = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).fontWeight(.semibold)
                Spacer()
                Label(statusTextOverride ?? statusText, systemImage: statusIcon)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            actions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
    }

    private var statusText: String {
        switch status {
        case .notDetermined: return "未確認"
        case .authorized: return "許可済み"
        case .denied: return "設定が必要"
        case .restricted: return "制限あり"
        }
    }

    private var statusIcon: String {
        switch status {
        case .authorized: return "checkmark.circle.fill"
        case .notDetermined: return "circle.dashed"
        case .denied: return "exclamationmark.circle.fill"
        case .restricted: return "lock.circle.fill"
        }
    }

    private var statusColor: Color {
        switch status {
        case .authorized: return .green
        case .notDetermined: return .secondary
        case .denied, .restricted: return .orange
        }
    }
}

private struct MarkdownSummaryView: View {
    let markdown: String

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let value):
                    Text((try? AttributedString(markdown: value)) ?? AttributedString(value))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                case .image(let title, let path):
                    VStack(alignment: .leading, spacing: 6) {
                        if let image = NSImage(contentsOfFile: path) {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: 320)
                                .background(Color.black.opacity(0.04))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            Text(title).font(.caption).foregroundStyle(.secondary)
                        } else {
                            Label("画像を読み込めません: \(path)", systemImage: "photo.badge.exclamationmark")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var textLines: [String] = []
        for line in markdown.components(separatedBy: .newlines) {
            if let image = parseImageLine(line) {
                if !textLines.isEmpty {
                    result.append(.text(textLines.joined(separator: "\n")))
                    textLines.removeAll()
                }
                result.append(.image(title: image.title, path: image.path))
            } else {
                textLines.append(line)
            }
        }
        if !textLines.isEmpty { result.append(.text(textLines.joined(separator: "\n"))) }
        return result
    }

    private func parseImageLine(_ line: String) -> (title: String, path: String)? {
        let pattern = #"^\s*!\[([^\]]*)\]\((?:<([^>]+)>|([^\)]+))\)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
            return nil
        }
        func value(at index: Int) -> String? {
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: line) else { return nil }
            return String(line[swiftRange])
        }
        guard let path = value(at: 2) ?? value(at: 3) else { return nil }
        return (value(at: 1) ?? "スクリーンショット", path)
    }

    private enum Block {
        case text(String)
        case image(title: String, path: String)
    }
}
