import Foundation

struct VaultPayload: Codable, Equatable {
    let formatVersion: Int
    let notes: [VaultNote]
    let selectedNoteID: String?

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case notes
        case selectedNoteID
    }

    init(formatVersion: Int, notes: [VaultNote], selectedNoteID: String?) {
        self.formatVersion = formatVersion
        self.notes = notes
        self.selectedNoteID = selectedNoteID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        selectedNoteID = try container.decodeIfPresent(String.self, forKey: .selectedNoteID)

        var notesContainer = try container.nestedUnkeyedContainer(forKey: .notes)
        if let count = notesContainer.count, count > VaultResourcePolicy.maximumNoteCount {
            throw DecodingError.dataCorruptedError(
                in: notesContainer,
                debugDescription: "Vault contains too many notes."
            )
        }

        var decodedNotes: [VaultNote] = []
        decodedNotes.reserveCapacity(min(notesContainer.count ?? 0, VaultResourcePolicy.maximumNoteCount))
        while !notesContainer.isAtEnd {
            guard decodedNotes.count < VaultResourcePolicy.maximumNoteCount else {
                throw DecodingError.dataCorruptedError(
                    in: notesContainer,
                    debugDescription: "Vault contains too many notes."
                )
            }
            decodedNotes.append(try notesContainer.decode(VaultNote.self))
        }
        notes = decodedNotes
    }

    static func singleEditorNote(body: String, now: Date = Date()) -> VaultPayload {
        let note = VaultNote(
            id: "primary",
            title: "Untitled",
            body: body,
            createdAt: now,
            updatedAt: now,
            isTitleFinalized: false
        )

        return VaultPayload(
            formatVersion: 2,
            notes: [note],
            selectedNoteID: note.id
        )
    }

    var selectedEditorText: String {
        if let selectedNoteID,
           let selectedNote = notes.first(where: { $0.id == selectedNoteID }) {
            return selectedNote.body
        }

        return notes.first?.body ?? ""
    }
}

struct VaultRichContent: Codable, Equatable {
    var rtfdData: Data
    var imageAttachmentIDs: [String]
    var imageDisplayWidths: [String: Double]
    var imageSources: [VaultImageSource]

    private enum CodingKeys: String, CodingKey {
        case rtfdData
        case imageAttachmentIDs
        case imageDisplayWidths
        case imageSources
    }

    init(
        rtfdData: Data,
        imageAttachmentIDs: [String] = [],
        imageDisplayWidths: [String: Double] = [:],
        imageSources: [VaultImageSource] = []
    ) {
        self.rtfdData = rtfdData
        self.imageAttachmentIDs = imageAttachmentIDs
        self.imageDisplayWidths = imageDisplayWidths
        self.imageSources = imageSources
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rtfdData = try container.decode(Data.self, forKey: .rtfdData)
        guard rtfdData.count <= VaultResourcePolicy.maximumRTFDBytesPerNote else {
            throw DecodingError.dataCorruptedError(
                forKey: .rtfdData,
                in: container,
                debugDescription: "Rich text exceeds the per-note limit."
            )
        }
        imageDisplayWidths = try container.decodeIfPresent(
            [String: Double].self,
            forKey: .imageDisplayWidths
        ) ?? [:]
        imageAttachmentIDs = try container.decodeIfPresent(
            [String].self,
            forKey: .imageAttachmentIDs
        ) ?? imageDisplayWidths.keys.sorted()
        guard imageAttachmentIDs.count <= VaultResourcePolicy.maximumAttachmentsPerNote else {
            throw DecodingError.dataCorruptedError(
                forKey: .imageAttachmentIDs,
                in: container,
                debugDescription: "Rich text contains too many attachments."
            )
        }
        imageSources = try container.decodeIfPresent([VaultImageSource].self, forKey: .imageSources) ?? []
        guard imageSources.count <= VaultResourcePolicy.maximumAttachmentsPerNote else {
            throw DecodingError.dataCorruptedError(
                forKey: .imageSources,
                in: container,
                debugDescription: "Rich text contains too many image sources."
            )
        }
    }
}

struct VaultImageSource: Codable, Equatable {
    let id: String
    let data: Data
    let typeIdentifier: String
    let filenameExtension: String

    private enum CodingKeys: String, CodingKey {
        case id
        case data
        case typeIdentifier
        case filenameExtension
    }

    init(id: String, data: Data, typeIdentifier: String, filenameExtension: String) {
        self.id = id
        self.data = data
        self.typeIdentifier = typeIdentifier
        self.filenameExtension = filenameExtension
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        data = try container.decode(Data.self, forKey: .data)
        typeIdentifier = try container.decode(String.self, forKey: .typeIdentifier)
        filenameExtension = try container.decode(String.self, forKey: .filenameExtension)
        guard data.count <= VaultResourcePolicy.maximumImageBytes else {
            throw DecodingError.dataCorruptedError(
                forKey: .data,
                in: container,
                debugDescription: "Image exceeds the per-image limit."
            )
        }
    }
}

struct VaultNote: Codable, Equatable, Identifiable {
    let id: String
    var title: String
    var body: String
    let createdAt: Date
    var updatedAt: Date
    var isTitleFinalized: Bool
    var richContent: VaultRichContent?

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case body
        case createdAt
        case updatedAt
        case isTitleFinalized
        case richContent
    }

    init(
        id: String,
        title: String,
        body: String,
        createdAt: Date,
        updatedAt: Date,
        isTitleFinalized: Bool,
        richContent: VaultRichContent? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isTitleFinalized = isTitleFinalized
        self.richContent = richContent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decode(String.self, forKey: .body)
        guard VaultResourcePolicy.utf8Count(id) <= VaultResourcePolicy.maximumIdentifierBytes,
              VaultResourcePolicy.utf8Count(title) <= VaultResourcePolicy.maximumTitleBytes,
              VaultResourcePolicy.utf8Count(body) <= VaultResourcePolicy.maximumBodyBytesPerNote
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .body,
                in: container,
                debugDescription: "Note text exceeds the resource policy."
            )
        }
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        isTitleFinalized = try container.decodeIfPresent(Bool.self, forKey: .isTitleFinalized)
            ?? (title.localizedCaseInsensitiveCompare("Untitled") != .orderedSame)
        richContent = try container.decodeIfPresent(VaultRichContent.self, forKey: .richContent)
    }
}
