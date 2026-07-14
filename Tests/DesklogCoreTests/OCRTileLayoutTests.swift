import Foundation
import DesklogCore
import Testing

@Suite struct OCRTileLayoutTests {
    @Test func largeTilesPhysicallyCropTheFailedCaptionCapture() throws {
        let regions = OCRTileLayout.regions(
            pixelWidth: 2_022,
            pixelHeight: 216,
            pass: .largeTiles
        )

        #expect(regions.count == 8)
        #expect(regions[4] == OCRPixelRegion(x: 0, y: 108, width: 505, height: 108))
        #expect(OCRRecognitionPass.largeTiles.preprocessingScale == 2)
    }

    @Test func everyPassCoversTheWholeImageWithoutGaps() {
        for pass in OCRRecognitionPass.allCases {
            let regions = OCRTileLayout.regions(
                pixelWidth: 1_919,
                pixelHeight: 1_079,
                pass: pass
            )
            let totalArea = regions.reduce(0) { partial, region in
                partial + region.width * region.height
            }
            #expect(totalArea == 1_919 * 1_079)
        }
    }

    @Test func retryFlowKeepsItsSheetContentAndOnlyPersistsSuccessfulRetries() throws {
        let dashboardSource = try source("Sources/Desklog/DashboardView.swift")
        let controllerSource = try source("Sources/Desklog/DesklogController.swift")
        let screenSource = try source("Sources/Desklog/ScreenOCRService.swift")

        #expect(dashboardSource.contains("@State private var ocrImageReview"))
        #expect(dashboardSource.contains("if let review = ocrImageReview"))
        #expect(controllerSource.contains("guard targetResult.didRecognizeText else"))
        #expect(controllerSource.contains("discardUnpersistedCaptureImages(results)"))
        #expect(screenSource.contains("hasSubstantiveText(recognized)"))
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
