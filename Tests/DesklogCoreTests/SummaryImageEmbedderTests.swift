import DesklogCore
import Foundation
import Testing

@Suite struct SummaryImageEmbedderTests {
    @Test func nearbySpeechSelectsTheCaptureForAnImportantTopic() throws {
        let start = localDate(hour: 9, minute: 0)
        let unrelated = capture(
            at: start.addingTimeInterval(60),
            text: "メール受信トレイと予定表",
            path: "/tmp/mail.jpg",
            title: "Mail"
        )
        let relevant = capture(
            at: start.addingTimeInterval(5 * 60),
            text: "会議資料 アーキテクチャ案",
            path: "/tmp/design.jpg",
            title: "Preview — design.pdf"
        )
        let speech = WorklogEvent(
            timestamp: start.addingTimeInterval(5 * 60 + 10),
            kind: .speechTranscript,
            text: "認証フローはOAuth方式に決定して設計レビューを進めます"
        )
        let summary = """
        # ワークログ要約
        ## 主な作業
        - 認証フローのOAuth方式を決定し、設計レビューを実施
        """

        let result = SummaryImageEmbedder.embedRelevantCaptures(
            in: summary,
            events: [unrelated, relevant, speech]
        )

        #expect(result.contains("![Preview — design.pdf](</tmp/design.jpg>)"))
        #expect(!result.contains("/tmp/mail.jpg"))
    }

    @Test func explicitTimeRangeSelectsARelevantCaptureAfterParaphrasing() throws {
        let start = localDate(hour: 9, minute: 0)
        let capture = capture(
            at: start.addingTimeInterval(33 * 60),
            text: "図 3 コンポーネントの関係",
            path: "/tmp/diagram.jpg",
            title: "設計図"
        )
        let summary = """
        # ワークログ要約
        ## 主な作業
        - 09:31〜09:35 重要な方針を整理
        """

        let result = SummaryImageEmbedder.embedRelevantCaptures(
            in: summary,
            events: [capture]
        )

        #expect(result.contains("![設計図](</tmp/diagram.jpg>)"))
    }

    @Test func unrelatedCaptureIsNotInsertedWithoutTimeOrSharedTerms() throws {
        let event = capture(
            at: localDate(hour: 11, minute: 0),
            text: "売上グラフ 四半期レポート",
            path: "/tmp/sales.jpg",
            title: "Numbers"
        )
        let summary = """
        # ワークログ要約
        ## 主な作業
        - 音声認識モデルの精度を検証
        """

        let result = SummaryImageEmbedder.embedRelevantCaptures(in: summary, events: [event])

        #expect(result == summary)
    }

    @Test func existingImageAndRepeatedScreenAreNotDuplicated() throws {
        let start = localDate(hour: 13, minute: 0)
        let first = capture(
            at: start,
            text: "ログイン画面 OAuth 設定",
            path: "/tmp/login-1.jpg",
            title: "Browser"
        )
        let repeated = capture(
            at: start.addingTimeInterval(60),
            text: "ログイン画面   OAuth 設定",
            path: "/tmp/login-2.jpg",
            title: "Browser"
        )
        let summary = """
        # ワークログ要約
        ## 主な作業
        - 13:00 ログイン画面のOAuth設定を確認

        ![Browser](</tmp/login-1.jpg>)
        """

        let result = SummaryImageEmbedder.embedRelevantCaptures(
            in: summary,
            events: [first, repeated]
        )

        #expect(result == summary)
        #expect(!result.contains("/tmp/login-2.jpg"))
    }

    @Test func barePathFromTheModelIsStillConvertedToImageMarkdown() throws {
        let event = capture(
            at: localDate(hour: 14, minute: 10),
            text: "データベース構成図とテーブル設計",
            path: "/tmp/database.jpg",
            title: "構成図"
        )
        let summary = """
        # ワークログ要約
        ## 主な作業
        - 14:10 データベースのテーブル設計をレビュー（/tmp/database.jpg）
        """

        let result = SummaryImageEmbedder.embedRelevantCaptures(in: summary, events: [event])

        #expect(result.contains("![構成図](</tmp/database.jpg>)"))
    }

    private func capture(
        at timestamp: Date,
        text: String,
        path: String,
        title: String
    ) -> WorklogEvent {
        WorklogEvent(
            timestamp: timestamp,
            kind: .screenOCR,
            text: text,
            metadata: [
                "image_path": path,
                "display_title": title,
                "window_id": title,
                "bundle_identifier": "com.example.test"
            ]
        )
    }

    private func localDate(hour: Int, minute: Int) -> Date {
        Calendar.current.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 13,
            hour: hour,
            minute: minute
        ))!
    }
}
