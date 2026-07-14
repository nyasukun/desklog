import Foundation

public enum OCRRecognitionPass: String, CaseIterable, Sendable {
    case fullFrame = "full_frame"
    case largeTiles = "tiles_4x2"
    case fineTiles = "tiles_6x3"
    case smallestTiles = "tiles_8x4"

    public static let retryPasses: [OCRRecognitionPass] = [
        .largeTiles,
        .fineTiles,
        .smallestTiles
    ]

    public var columns: Int {
        switch self {
        case .fullFrame: return 1
        case .largeTiles: return 4
        case .fineTiles: return 6
        case .smallestTiles: return 8
        }
    }

    public var rows: Int {
        switch self {
        case .fullFrame: return 1
        case .largeTiles: return 2
        case .fineTiles: return 3
        case .smallestTiles: return 4
        }
    }

    public var preprocessingScale: Int {
        switch self {
        case .fullFrame: return 1
        case .largeTiles: return 2
        case .fineTiles, .smallestTiles: return 4
        }
    }
}

public struct OCRPixelRegion: Sendable, Equatable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public enum OCRTileLayout {
    public static func regions(
        pixelWidth: Int,
        pixelHeight: Int,
        pass: OCRRecognitionPass
    ) -> [OCRPixelRegion] {
        guard pixelWidth > 0, pixelHeight > 0 else { return [] }
        let columns = min(pass.columns, pixelWidth)
        let rows = min(pass.rows, pixelHeight)

        return (0..<rows).flatMap { row in
            (0..<columns).map { column in
                let minX = column * pixelWidth / columns
                let maxX = (column + 1) * pixelWidth / columns
                let minY = row * pixelHeight / rows
                let maxY = (row + 1) * pixelHeight / rows
                return OCRPixelRegion(
                    x: minX,
                    y: minY,
                    width: maxX - minX,
                    height: maxY - minY
                )
            }
        }
    }
}
