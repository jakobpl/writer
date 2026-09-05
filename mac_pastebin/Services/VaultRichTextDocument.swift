import AppKit
import Foundation

enum VaultRichTextDocument {
    static let attachmentMarker = "\u{E000}"
    private static let rtfPrefix = Data("{\\rtf".utf8)

    static func isLegacyRTFD(_ data: Data) -> Bool {
        !data.starts(with: rtfPrefix) && FileWrapper(serializedRepresentation: data) != nil
    }

    static func encode(_ attributedString: NSAttributedString) -> Data? {
        let document = NSMutableAttributedString(attributedString: attributedString)
        var attachmentRanges: [NSRange] = []
        document.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: document.length)
        ) { value, range, _ in
            if value is NSTextAttachment {
                attachmentRanges.append(range)
            }
        }
        for range in attachmentRanges.reversed() {
            var attributes = document.attributes(at: range.location, effectiveRange: nil)
            attributes.removeValue(forKey: .attachment)
            document.replaceCharacters(
                in: range,
                with: NSAttributedString(string: attachmentMarker, attributes: attributes)
            )
        }
        return try? document.data(
            from: NSRange(location: 0, length: document.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }

    static func decode(_ data: Data) -> NSAttributedString? {
        if isLegacyRTFD(data),
           let legacyDocument = NSAttributedString(rtfd: data, documentAttributes: nil) {
            return legacyDocument
        }
        return try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        )
    }

    static func attachmentLocations(in attributedString: NSAttributedString) -> [Int] {
        let string = attributedString.string as NSString
        guard string.length > 0 else { return [] }

        var locations: [Int] = []
        for location in 0..<string.length {
            let character = string.character(at: location)
            if character == 0xE000 || character == 0xFFFC {
                locations.append(location)
            }
        }
        return locations
    }
}
