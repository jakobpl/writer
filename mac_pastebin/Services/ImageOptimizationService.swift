import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageOptimizationService {
    nonisolated static let maximumImportBytes = 40 * 1_024 * 1_024
    nonisolated static let maximumStoredBytes = 750 * 1_024
    nonisolated static let maximumPixelDimension = 1_200
    private nonisolated static let minimumPixelDimension = 320

    struct Result: Equatable, Sendable {
        let data: Data
        let width: Int
        let height: Int
        let typeIdentifier: String
        let filenameExtension: String
    }

    enum OptimizationError: Error, Equatable {
        case fileIsNotRegular
        case resourceLimitExceeded
        case invalidImage
        case encodingFailed
    }

    nonisolated static func optimizeImage(at url: URL) throws -> Result {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw OptimizationError.fileIsNotRegular
        }
        guard let byteCount = (attributes[.size] as? NSNumber)?.intValue,
              (1...maximumImportBytes).contains(byteCount)
        else {
            throw OptimizationError.resourceLimitExceeded
        }

        return try optimizeImageData(Data(contentsOf: url, options: .mappedIfSafe))
    }

    nonisolated static func optimizeImageData(_ input: Data) throws -> Result {
        guard !input.isEmpty,
              input.count <= maximumImportBytes,
              let source = CGImageSourceCreateWithData(
                  input as CFData,
                  [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(
                  source,
                  0,
                  [kCGImageSourceShouldCache: false] as CFDictionary
              ) as? [CFString: Any],
              let sourceWidth = integerValue(properties[kCGImagePropertyPixelWidth]),
              let sourceHeight = integerValue(properties[kCGImagePropertyPixelHeight]),
              sourceWidth > 0,
              sourceHeight > 0,
              sourceWidth <= VaultResourcePolicy.maximumImageDimension,
              sourceHeight <= VaultResourcePolicy.maximumImageDimension,
              sourceWidth <= VaultResourcePolicy.maximumImagePixels / sourceHeight
        else {
            throw OptimizationError.invalidImage
        }

        let aspectRatio = max(
            Double(sourceWidth) / Double(sourceHeight),
            Double(sourceHeight) / Double(sourceWidth)
        )
        guard aspectRatio <= VaultResourcePolicy.maximumImageAspectRatio else {
            throw OptimizationError.resourceLimitExceeded
        }

        var pixelLimit = min(max(sourceWidth, sourceHeight), maximumPixelDimension)
        let smallestPixelLimit = min(pixelLimit, minimumPixelDimension)
        while true {
            guard let image = makeThumbnail(from: source, maximumDimension: pixelLimit) else {
                throw OptimizationError.invalidImage
            }

            let preservesAlpha = hasAlpha(image)
            let type = preservesAlpha ? UTType.png : UTType.jpeg
            let properties: [CFString: Any] = preservesAlpha
                ? [:]
                : [kCGImageDestinationLossyCompressionQuality: 0.76]
            guard let data = encode(image, as: type, properties: properties) else {
                throw OptimizationError.encodingFailed
            }

            if data.count <= maximumStoredBytes {
                return Result(
                    data: data,
                    width: image.width,
                    height: image.height,
                    typeIdentifier: type.identifier,
                    filenameExtension: preservesAlpha ? "png" : "jpg"
                )
            }

            guard pixelLimit > smallestPixelLimit else { break }
            pixelLimit = max(smallestPixelLimit, Int(Double(pixelLimit) * 0.78))
        }

        throw OptimizationError.resourceLimitExceeded
    }

    private nonisolated static func makeThumbnail(
        from source: CGImageSource,
        maximumDimension: Int
    ) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumDimension
            ] as CFDictionary
        )
    }

    private nonisolated static func encode(
        _ image: CGImage,
        as type: UTType,
        properties: [CFString: Any]
    ) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            type.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return output as Data
    }

    private nonisolated static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast:
            return true
        case .none, .noneSkipFirst, .noneSkipLast, .alphaOnly:
            return image.alphaInfo == .alphaOnly
        @unknown default:
            return true
        }
    }

    private nonisolated static func integerValue(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }
}
