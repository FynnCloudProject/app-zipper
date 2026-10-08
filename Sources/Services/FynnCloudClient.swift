import AsyncHTTPClient
import Foundation
import Logging
import NIOCore
import Vapor

public struct FynnCloudClient: Sendable {
    private let client: HTTPClient
    private let baseURL: String
    private let logger: Logger

    public init(client: HTTPClient, baseURL: String, logger: Logger) {
        self.client = client
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.logger = logger
    }

    public func fetchMetadata(fileID: UUID, token: String) async throws -> RemoteFileMetadata {
        var req = HTTPClientRequest(url: "\(baseURL)/api/files/\(fileID.uuidString)")
        req.method = .GET
        req.headers.bearerAuthorization = BearerAuthorization(token: token)

        let res = try await client.execute(req, timeout: .seconds(30))
        guard res.status == .ok else {
            throw Abort(res.status, reason: "Unable to retrieve metadata for file \(fileID)")
        }

        let buffer = try await res.body.collect(upTo: 1024 * 1024)
        return try JSONDecoder().decode(RemoteFileMetadata.self, from: buffer)
    }

    public func listFolder(folderID: UUID, token: String) async throws -> [RemoteFolderListing.RemoteItem] {
        var req = HTTPClientRequest(url: "\(baseURL)/api/files?parentID=\(folderID.uuidString)")
        req.method = .GET
        req.headers.bearerAuthorization = BearerAuthorization(token: token)

        let res = try await client.execute(req, timeout: .seconds(30))
        guard res.status == .ok else {
            throw Abort(res.status, reason: "Unable to read folder \(folderID)")
        }

        let buffer = try await res.body.collect(upTo: 10 * 1024 * 1024)
        let listing = try JSONDecoder().decode(RemoteFolderListing.self, from: buffer)
        return listing.files
    }

    public func streamDownload(fileID: UUID, to destination: URL, token: String) async throws {
        var req = HTTPClientRequest(url: "\(baseURL)/api/files/\(fileID.uuidString)/download")
        req.method = .GET
        req.headers.bearerAuthorization = BearerAuthorization(token: token)

        let res = try await client.execute(req, timeout: .minutes(10))
        guard res.status == .ok else {
            throw Abort(res.status, reason: "Failed to download file \(fileID)")
        }

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        for try await chunk in res.body {
            handle.write(Data(buffer: chunk))
        }
    }

    public func uploadArchive(
        name: String,
        fileURL: URL,
        size: Int64,
        parentID: UUID?,
        token: String
    ) async throws -> (finalName: String, fileID: UUID?) {
        let zipData = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        var candidateName = name

        for attempt in 1...20 {
            var query = [
                "filename=\(candidateName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? candidateName)",
                "overwrite=false",
                "size=\(size)",
                "contentType=application/zip"
            ]
            if let parentID {
                query.append("parentID=\(parentID.uuidString)")
            }

            var req = HTTPClientRequest(url: "\(baseURL)/api/files/upload?\(query.joined(separator: "&"))")
            req.method = .POST
            req.headers.bearerAuthorization = BearerAuthorization(token: token)
            req.headers.replaceOrAdd(name: .contentType, value: "application/zip")
            req.headers.replaceOrAdd(name: .contentLength, value: String(size))
            req.body = .bytes(zipData)

            let res = try await client.execute(req, timeout: .minutes(5))

            if res.status == .ok || res.status == .created {
                var createdID: UUID?
                if let body = try? await res.body.collect(upTo: 64 * 1024) {
                    struct UploadResult: Decodable { let id: UUID? }
                    createdID = try? JSONDecoder().decode(UploadResult.self, from: body).id
                }
                return (candidateName, createdID)
            }

            if res.status == .conflict {
                let stem = (name as NSString).deletingPathExtension
                candidateName = "\(stem) (\(attempt)).zip"
                continue
            }

            throw Abort(res.status, reason: "Failed to upload archive to destination")
        }

        throw Abort(.conflict, reason: "Could not find an available filename for archive")
    }
}
