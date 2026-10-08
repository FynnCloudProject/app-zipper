import Foundation
import Vapor

struct FileItemDTO: Content {
    let id: UUID?
    let name: String?
    let parentID: UUID?
}

struct ZipRequest: Content {
    let files: [FileItemDTO]?
    let fileIds: [UUID]?
    let archiveName: String?
    let compressionLevel: Int?
    let parentID: UUID?
    let token: String?

    var resolvedFileIDs: [UUID] {
        if let files, !files.isEmpty {
            return files.compactMap(\.id)
        }
        return fileIds ?? []
    }
}

struct ZipResponse: Content {
    let success: Bool
    let archiveName: String
    let archiveSize: Int64
    let fileCount: Int
    let createdFileID: UUID?
    let message: String
}

struct RemoteFileMetadata: Content {
    let id: UUID?
    let filename: String
    let size: Int64
    let isDirectory: Bool?
    let parent: ParentRef?

    struct ParentRef: Content {
        let id: UUID
    }
}

struct RemoteFolderListing: Content {
    let files: [RemoteItem]

    struct RemoteItem: Content {
        let id: UUID?
        let filename: String
        let size: Int64
        let isDirectory: Bool
    }
}

struct HealthResponse: Content {
    let status: String
    let app: String
    let version: String
}
