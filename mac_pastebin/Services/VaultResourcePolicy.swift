import AppKit
import CoreGraphics
import Foundation
import ImageIO

enum VaultResourcePolicy {
    static let maximumVaultFileBytes = 80 * 1_024 * 1_024
    static let maximumCiphertextBytes = 48 * 1_024 * 1_024
    static let maximumPlaintextBytes = 48 * 1_024 * 1_024

    static let maximumNoteCount = 500
    static let maximumIdentifierBytes = 1_024
    static let maximumTitleBytes = 16 * 1_024
    static let maximumBodyBytesPerNote = 2 * 1_024 * 1_024
    static let maximumBodyBytesTotal = 8 * 1_024 * 1_024

    static let maximumRTFDBytesPerNote = 16 * 1_024 * 1_024
    static let maximumRTFDBytesTotal = 32 * 1_024 * 1_024
    static let maximumAttachmentsPerNote = 64
    static let maximumAttachmentsTotal = 256
    static let maximumImageBytes = 8 * 1_024 * 1_024
    static let maximumImageBytesTotal = 24 * 1_024 * 1_024
    nonisolated static let maximumImageDimension = 8_192
    nonisolated static let maximumImagePixels = 40_000_000
    static let maximumImagePixelsPerNote = 80_000_000
    static let maximumImagePixelsTotal = 160_000_000
    nonisolated static let maximumImageAspectRatio = 100.0
    static let maximumImageFrameCount = 1

    struct ImageMetadata: Equatable {
        let width: Int
        let height: Int
        let frameCount: Int

        var size: CGSize {
            CGSize(width: width, height: height)
        }
    }

    enum ValidationError: Error, Equatable {
        case fileIsNotRegular
        case resourceLimitExceeded
        case invalidImage
    }

    static func validatedFileSize(at url: URL, fileManager: FileManager = .default) throws -> Int {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ValidationError.fileIsNotRegular
        }
        guard let byteCount = (attributes[.size] as? NSNumber)?.intValue,
              (0...maximumVaultFileBytes).contains(byteCount)
        else {
            throw ValidationError.resourceLimitExceeded
        }
        return byteCount
    }

    static func validatedImageFileSize(at url: URL, fileManager: FileManager = .default) throws -> Int {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ValidationError.fileIsNotRegular
        }
        guard let byteCount = (attributes[.size] as? NSNumber)?.intValue,
              (1...ImageOptimizationService.maximumImportBytes).contains(byteCount)
        else {
            throw ValidationError.resourceLimitExceeded
        }
        return byteCount
    }

    static func imageMetadata(for data: Data) throws -> ImageMetadata {
        guard !data.isEmpty, data.count <= maximumImageBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [
                  kCGImageSourceShouldCache: false
              ] as CFDictionary)
        else {
            throw ValidationError.invalidImage
        }

        let frameCount = CGImageSourceGetCount(source)
        guard (1...maximumImageFrameCount).contains(frameCount),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, [
                  kCGImageSourceShouldCache: false
              ] as CFDictionary) as? [CFString: Any],
              let width = integerValue(properties[kCGImagePropertyPixelWidth]),
              let height = integerValue(properties[kCGImagePropertyPixelHeight]),
              width > 0, height > 0,
              width <= maximumImageDimension,
              height <= maximumImageDimension,
              width <= maximumImagePixels / height
        else {
            throw ValidationError.resourceLimitExceeded
        }

        let aspectRatio = max(Double(width) / Double(height), Double(height) / Double(width))
        guard aspectRatio <= maximumImageAspectRatio else {
            throw ValidationError.resourceLimitExceeded
        }

        return ImageMetadata(width: width, height: height, frameCount: frameCount)
    }

    static func isStructurallyValid(_ payload: VaultPayload) -> Bool {
        guard payload.notes.count <= maximumNoteCount,
              payload.selectedNoteID.map({ utf8Count($0) <= maximumIdentifierBytes }) ?? true
        else {
            return false
        }

        var bodyBytesTotal = 0
        var rtfdBytesTotal = 0
        var attachmentCountTotal = 0
        var imageBytesTotal = 0

        for note in payload.notes {
            let bodyBytes = utf8Count(note.body)
            guard utf8Count(note.id) <= maximumIdentifierBytes,
                  utf8Count(note.title) <= maximumTitleBytes,
                  bodyBytes <= maximumBodyBytesPerNote
            else {
                return false
            }
            bodyBytesTotal += bodyBytes
            guard bodyBytesTotal <= maximumBodyBytesTotal else {
                return false
            }

            guard let richContent = note.richContent else {
                continue
            }

            let attachmentCount = richContent.imageAttachmentIDs.count
            guard richContent.rtfdData.count <= maximumRTFDBytesPerNote,
                  attachmentCount <= maximumAttachmentsPerNote,
                  richContent.imageSources.count == attachmentCount,
                  richContent.imageDisplayWidths.count <= attachmentCount
            else {
                return false
            }
            rtfdBytesTotal += richContent.rtfdData.count
            attachmentCountTotal += attachmentCount
            guard rtfdBytesTotal <= maximumRTFDBytesTotal,
                  attachmentCountTotal <= maximumAttachmentsTotal
            else {
                return false
            }

            for identifier in richContent.imageAttachmentIDs {
                guard utf8Count(identifier) <= maximumIdentifierBytes else {
                    return false
                }
            }
            for source in richContent.imageSources {
                guard utf8Count(source.id) <= maximumIdentifierBytes,
                      utf8Count(source.typeIdentifier) <= maximumIdentifierBytes,
                      utf8Count(source.filenameExtension) <= 32,
                      source.data.count <= maximumImageBytes
                else {
                    return false
                }
                imageBytesTotal += source.data.count
                guard imageBytesTotal <= maximumImageBytesTotal else {
                    return false
                }
            }
        }

        return true
    }

    static func canAddImage(
        byteCount: Int,
        metadata: ImageMetadata,
        to existingSources: some Collection<VaultImageSource>
    ) -> Bool {
        guard byteCount > 0, byteCount <= maximumImageBytes,
              existingSources.count < maximumAttachmentsPerNote
        else {
            return false
        }
        guard existingSources.reduce(byteCount, { partialResult, source in
            partialResult + source.data.count
        }) <= maximumImageBytesTotal else {
            return false
        }

        var pixelCount = metadata.width * metadata.height
        for source in existingSources {
            guard let existingMetadata = try? imageMetadata(for: source.data) else {
                return false
            }
            pixelCount += existingMetadata.width * existingMetadata.height
            guard pixelCount <= maximumImagePixelsPerNote else {
                return false
            }
        }
        return true
    }

    static func isValidRTFD(_ data: Data, expectedImageSources: [VaultImageSource]) -> Bool {
        guard !data.isEmpty, data.count <= maximumRTFDBytesPerNote,
              let rootWrapper = FileWrapper(serializedRepresentation: data)
        else {
            return false
        }

        var pendingWrappers = [rootWrapper]
        var regularFileCount = 0
        var matchedImageSourceIDs = Set<String>()
        while let wrapper = pendingWrappers.popLast() {
            if wrapper.isDirectory {
                guard let children = wrapper.fileWrappers,
                      children.count <= maximumAttachmentsPerNote + 1
                else {
                    return false
                }
                pendingWrappers.append(contentsOf: children.values)
                continue
            }

            guard wrapper.isRegularFile,
                  let contents = wrapper.regularFileContents
            else {
                return false
            }
            regularFileCount += 1
            guard regularFileCount <= maximumAttachmentsPerNote + 1 else {
                return false
            }

            let filename = wrapper.preferredFilename ?? wrapper.filename ?? ""
            if filename.lowercased().hasSuffix(".rtf") {
                guard contents.count <= maximumRTFDBytesPerNote else {
                    return false
                }
                continue
            }

            guard let source = expectedImageSources.first(where: {
                !matchedImageSourceIDs.contains($0.id) && $0.data == contents
            }), (try? imageMetadata(for: contents)) != nil else {
                return false
            }
            matchedImageSourceIDs.insert(source.id)
        }

        return matchedImageSourceIDs.count == expectedImageSources.count
    }

    static func isValidStoredRichText(
        _ data: Data,
        expectedImageSources: [VaultImageSource]
    ) -> Bool {
        if VaultRichTextDocument.isLegacyRTFD(data) {
            return isValidRTFD(data, expectedImageSources: expectedImageSources)
        }

        guard !data.isEmpty,
              data.count <= maximumRTFDBytesPerNote,
              let document = VaultRichTextDocument.decode(data),
              VaultRichTextDocument.attachmentLocations(in: document).count
                == expectedImageSources.count
        else {
            return false
        }

        var containsUnexpectedAttachment = false
        document.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: document.length)
        ) { value, _, stop in
            guard value != nil else { return }
            containsUnexpectedAttachment = true
            stop.pointee = true
        }
        return !containsUnexpectedAttachment
    }

    static func canPersistRichContent(
        body: String,
        rtfdByteCount: Int,
        attachmentCount: Int,
        imageSources: some Collection<VaultImageSource>
    ) -> Bool {
        guard utf8Count(body) <= maximumBodyBytesPerNote,
              rtfdByteCount <= maximumRTFDBytesPerNote,
              attachmentCount <= maximumAttachmentsPerNote,
              imageSources.count == attachmentCount
        else {
            return false
        }
        return imageSources.reduce(0) { partialResult, source in
            partialResult + source.data.count
        } <= maximumImageBytesTotal
    }

    static func utf8Count(_ string: String) -> Int {
        string.utf8.count
    }

    static func maximumBase64CharacterCount(forDecodedByteCount byteCount: Int) -> Int {
        ((byteCount + 2) / 3) * 4
    }

    private static func integerValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        return nil
    }
}
