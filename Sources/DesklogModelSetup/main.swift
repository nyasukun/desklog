import DesklogCore
import Foundation
import SpeakerKit

/// The only Desklog executable that is allowed to download SpeakerKit models.
/// The main app always points SpeakerKit at this prepared folder with
/// `download: false`, so speech processing cannot trigger an outbound request.
@main
enum DesklogModelSetup {
    static func main() async throws {
        let modelRoot = WorklogStore.defaultRootDirectory
            .appendingPathComponent("speaker-models", isDirectory: true)
        try FileManager.default.createDirectory(
            at: modelRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: modelRoot.path
        )

        print("SpeakerKitモデルを明示的にダウンロードします…")
        _ = try await SpeakerKit(PyannoteConfig(
            downloadBase: modelRoot.path,
            download: true,
            load: true,
            verbose: true,
            fullRedundancy: true
        ))
        print("準備完了: \(modelRoot.path)")
        print("Desklog本体はこのフォルダをオフラインモードで使用します。")
    }
}
