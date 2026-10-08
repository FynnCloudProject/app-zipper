import Foundation
import Vapor

public struct FileItemDTO: Content, Sendable {
    public let id: UUID?
    public let name: String?
    public let parentID: UUID?

    public init(id: UUID? = nil, name: String? = nil, parentID: UUID? = nil) {
        self.id = id
        self.name = name
        self.parentID = parentID
    }
}

public struct ZipRequest: Content, Sendable {
    public let files: [FileItemDTO]?
    public let fileIds: [UUID]?
    public let archiveName: String?
    public let compressionLevel: Int?
    public let parentID: UUID?
    public let token: String?

    public var resolvedFileIDs: [UUID] {
        if let files, !files.isEmpty {
            return files.compactMap(\.id)
        }
        return fileIds ?? []
    }
}

public struct ZipResponse: Content, Sendable {
    public let success: Bool
    public let archiveName: String
    public let archiveSize: Int64
    public let fileCount: Int
    public let createdFileID: UUID?
    public let message: String
}

public struct RemoteFileMetadata: Content, Sendable {
    public let id: UUID?
    public let filename: String
    public let size: Int64
    public let isDirectory: Bool?
    public let parent: ParentRef?

    public struct ParentRef: Content, Sendable {
        public let id: UUID
    }
}

public struct RemoteFolderListing: Content, Sendable {
    public let files: [RemoteItem]

    public struct RemoteItem: Content, Sendable {
        public let id: UUID?
        public let filename: String
        public let size: Int64
        public let isDirectory: Bool
    }
}

public struct HealthResponse: Content, Sendable {
    public let status: String
    public let app: String
    public let version: String
}
