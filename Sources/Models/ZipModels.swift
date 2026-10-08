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

struct FileIndexItemDTO: Content {
    let id: UUID?
    let filename: String
    let contentType: String
    let size: Int64
    let isDirectory: Bool
    let lastModified: Date?
    let createdAt: Date?
    let uploadedAt: Date?
    let parent: ParentID?

    struct ParentID: Content {
        let id: UUID
    }
}

struct FileIndexDTO: Content {
    let files: [FileIndexItemDTO]
    let parentID: UUID?
    let totalCount: Int
    let hasMore: Bool
}

struct HealthResponse: Content {
    let status: String
    let app: String
    let version: String
}
