import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1
import Vapor

struct FynnCloudAPIClient: Sendable {
    let client: HTTPClient
    let baseURL: String

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .customISO8601
        return d
    }()

    init(client: HTTPClient, baseURL: String = Environment.get("FYNNCLOUD_API_URL") ?? "http://127.0.0.1:8080") {
        self.client = client
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
    }

    init(app: Application, baseURL: String = Environment.get("FYNNCLOUD_API_URL") ?? "http://127.0.0.1:8080") {
        self.init(client: app.http.client.shared, baseURL: baseURL)
    }

    init(req: Request, baseURL: String = Environment.get("FYNNCLOUD_API_URL") ?? "http://127.0.0.1:8080") {
        self.init(client: req.application.http.client.shared, baseURL: baseURL)
    }

    // MARK: - File Metadata & Navigation

    func getFile(id: UUID, token: String) async throws -> FileIndexItemDTO {
        var req = HTTPClientRequest(url: "\(baseURL)/api/files/\(id.uuidString)")
        req.method = .GET
        req.headers.bearerAuthorization = BearerAuthorization(token: token)

        let res = try await client.execute(req, timeout: .seconds(30))
        guard res.status == .ok else {
            throw Abort(res.status, reason: "Unable to retrieve file \(id)")
        }

        let buffer = try await res.body.collect(upTo: 1024 * 1024)
        return try Self.decoder.decode(FileIndexItemDTO.self, from: buffer)
    }

    func resolvePath(_ segments: [String], token: String) async throws -> FileIndexItemDTO? {
        let path = segments.joined(separator: "/")
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }

        var req = HTTPClientRequest(url: "\(baseURL)/api/files/resolve?path=\(encoded)")
        req.method = .GET
        req.headers.bearerAuthorization = BearerAuthorization(token: token)

        let res = try await client.execute(req, timeout: .seconds(30))
        if res.status == .notFound {
            return nil
        }
        guard res.status == .ok else {
            throw Abort(res.status)
        }

        let buffer = try await res.body.collect(upTo: 1024 * 1024)
        return try Self.decoder.decode(FileIndexItemDTO.self, from: buffer)
    }

    func listChildren(folderID: UUID?, token: String) async throws -> [FileIndexItemDTO] {
        let url = folderID.map { "\(baseURL)/api/files?parentID=\($0.uuidString)" } ?? "\(baseURL)/api/files"
        var req = HTTPClientRequest(url: url)
        req.method = .GET
        req.headers.bearerAuthorization = BearerAuthorization(token: token)

        let res = try await client.execute(req, timeout: .seconds(30))
        guard res.status == .ok else {
            throw Abort(res.status)
        }

        let buffer = try await res.body.collect(upTo: 10 * 1024 * 1024)
        let listing = try Self.decoder.decode(FileIndexDTO.self, from: buffer)
        return listing.files
    }

    // MARK: - Directory & File Operations

    func createDirectory(name: String, parentID: UUID?, token: String) async throws -> FileIndexItemDTO {
        struct Payload: Content {
            let name: String
            let parentID: UUID?
        }

        var req = HTTPClientRequest(url: "\(baseURL)/api/files/create-directory")
        req.method = .POST
        req.headers.bearerAuthorization = BearerAuthorization(token: token)
        req.headers.replaceOrAdd(name: .contentType, value: "application/json")
        req.body = .bytes(try JSONEncoder().encode(Payload(name: name, parentID: parentID)))

        let res = try await client.execute(req, timeout: .seconds(30))
        if res.status == .conflict {
            throw Abort(.methodNotAllowed, reason: "Resource already exists")
        }
        guard res.status == .ok || res.status == .created else {
            throw Abort(res.status)
        }

        let buffer = try await res.body.collect(upTo: 1024 * 1024)
        return try Self.decoder.decode(FileIndexItemDTO.self, from: buffer)
    }

    func rename(fileID: UUID, to newName: String, token: String) async throws -> FileIndexItemDTO {
        struct Payload: Content {
            let name: String
        }

        var req = HTTPClientRequest(url: "\(baseURL)/api/files/\(fileID.uuidString)")
        req.method = .PATCH
        req.headers.bearerAuthorization = BearerAuthorization(token: token)
        req.headers.replaceOrAdd(name: .contentType, value: "application/json")
        req.body = .bytes(try JSONEncoder().encode(Payload(name: newName)))

        let res = try await client.execute(req, timeout: .seconds(30))
        guard res.status == .ok else {
            throw Abort(res.status)
        }

        let buffer = try await res.body.collect(upTo: 1024 * 1024)
        return try Self.decoder.decode(FileIndexItemDTO.self, from: buffer)
    }

    func move(fileID: UUID, toParentID: UUID?, token: String) async throws {
        struct Payload: Content {
            let ids: [UUID]
            let parentID: UUID?
        }

        var req = HTTPClientRequest(url: "\(baseURL)/api/files/move")
        req.method = .POST
        req.headers.bearerAuthorization = BearerAuthorization(token: token)
        req.headers.replaceOrAdd(name: .contentType, value: "application/json")
        req.body = .bytes(try JSONEncoder().encode(Payload(ids: [fileID], parentID: toParentID)))

        let res = try await client.execute(req, timeout: .seconds(30))
        guard res.status == .ok else {
            throw Abort(res.status)
        }
    }

    func copy(fileID: UUID, toParentID: UUID?, newName: String?, token: String) async throws -> FileIndexItemDTO {
        struct Payload: Content {
            let id: UUID
            let parentID: UUID?
            let name: String?
        }

        var req = HTTPClientRequest(url: "\(baseURL)/api/files/copy")
        req.method = .POST
        req.headers.bearerAuthorization = BearerAuthorization(token: token)
        req.headers.replaceOrAdd(name: .contentType, value: "application/json")
        req.body = .bytes(try JSONEncoder().encode(Payload(id: fileID, parentID: toParentID, name: newName)))

        let res = try await client.execute(req, timeout: .seconds(30))
        guard res.status == .ok || res.status == .created else {
            throw Abort(res.status)
        }

        let buffer = try await res.body.collect(upTo: 1024 * 1024)
        return try Self.decoder.decode(FileIndexItemDTO.self, from: buffer)
    }

    func delete(fileID: UUID, token: String) async throws {
        struct Payload: Content {
            let ids: [UUID]
        }

        var req = HTTPClientRequest(url: "\(baseURL)/api/files/trash")
        req.method = .POST
        req.headers.bearerAuthorization = BearerAuthorization(token: token)
        req.headers.replaceOrAdd(name: .contentType, value: "application/json")
        req.body = .bytes(try JSONEncoder().encode(Payload(ids: [fileID])))

        let res = try await client.execute(req, timeout: .seconds(30))
        guard res.status == .ok || res.status == .noContent else {
            throw Abort(res.status)
        }
    }

    // MARK: - Download & Upload Streaming

    func download(fileID: UUID, headers: HTTPHeaders = [:], token: String) async throws -> Response {
        var req = HTTPClientRequest(url: "\(baseURL)/api/files/\(fileID.uuidString)/download")
        req.method = .GET
        req.headers.bearerAuthorization = BearerAuthorization(token: token)

        if let range = headers.first(name: .range) {
            req.headers.replaceOrAdd(name: .range, value: range)
        }
        if let ifNoneMatch = headers.first(name: .ifNoneMatch) {
            req.headers.replaceOrAdd(name: .ifNoneMatch, value: ifNoneMatch)
        }

        let res = try await client.execute(req, timeout: .minutes(60))
        let response = Response(status: res.status, headers: res.headers)
        response.body = .init(managedAsyncStream: { writer in
            for try await chunk in res.body {
                try await writer.write(.buffer(chunk))
            }
        })
        return response
    }

    func download(fileID: UUID, to destination: URL, token: String) async throws {
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

    private struct InitiateMultipartPayload: Encodable {
        let filename: String
        let contentType: String
        let totalSize: Int64
        let parentID: UUID?
    }

    private struct InitiateMultipartResponseDTO: Decodable {
        let sessionID: UUID
        let fileID: UUID
        let uploadID: String
        let maxChunkSize: Int64
        let token: String
    }

    private struct PartResultDTO: Codable {
        let partNumber: Int
        let etag: String
        let size: Int64
    }

    private struct CompleteMultipartPayload: Encodable {
        let parts: [PartResultDTO]
    }

    func uploadArchive(
        name: String,
        fileURL: URL,
        size: Int64,
        parentID: UUID?,
        token: String
    ) async throws -> (finalName: String, fileID: UUID?) {
        var candidateName = name
        var initiatedSession: InitiateMultipartResponseDTO?

        for attempt in 1...20 {
            let payload = InitiateMultipartPayload(
                filename: candidateName,
                contentType: "application/zip",
                totalSize: size,
                parentID: parentID
            )
            var initReq = HTTPClientRequest(url: "\(baseURL)/api/files/multipart/initiate")
            initReq.method = .POST
            initReq.headers.bearerAuthorization = BearerAuthorization(token: token)
            initReq.headers.replaceOrAdd(name: .contentType, value: "application/json")
            initReq.body = .bytes(try JSONEncoder().encode(payload))

            let initRes = try await client.execute(initReq, timeout: .seconds(30))
            if initRes.status == .conflict {
                let stem = (name as NSString).deletingPathExtension
                candidateName = "\(stem) (\(attempt)).zip"
                continue
            }
            guard initRes.status == .ok || initRes.status == .created else {
                throw Abort(initRes.status, reason: "Failed to initiate archive upload")
            }

            let body = try await initRes.body.collect(upTo: 64 * 1024)
            initiatedSession = try Self.decoder.decode(InitiateMultipartResponseDTO.self, from: body)
            break
        }

        guard let session = initiatedSession else {
            throw Abort(.conflict, reason: "Could not find an available filename for archive")
        }

        let chunkSize = Swift.max(Int64(5 * 1024 * 1024), Swift.min(session.maxChunkSize, Int64(16 * 1024 * 1024)))
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? fileHandle.close() }

        var completedParts: [PartResultDTO] = []
        var partNumber = 1
        var remainingTotal = size

        do {
            while remainingTotal > 0 {
                let partSize = Swift.min(chunkSize, remainingTotal)
                var partRemaining = partSize

                let partStream = AsyncStream<ByteBuffer> { continuation in
                    while partRemaining > 0 {
                        let toRead = Int(Swift.min(partRemaining, Int64(64 * 1024)))
                        guard let slice = try? fileHandle.read(upToCount: toRead), !slice.isEmpty else {
                            break
                        }
                        var buffer = ByteBufferAllocator().buffer(capacity: slice.count)
                        buffer.writeBytes(slice)
                        continuation.yield(buffer)
                        partRemaining -= Int64(slice.count)
                    }
                    continuation.finish()
                }

                var partReq = HTTPClientRequest(
                    url: "\(baseURL)/api/files/multipart/\(session.sessionID.uuidString)/part/\(partNumber)"
                )
                partReq.method = .PUT
                partReq.headers.bearerAuthorization = BearerAuthorization(token: session.token)
                partReq.headers.replaceOrAdd(name: .contentType, value: "application/octet-stream")
                partReq.headers.replaceOrAdd(name: .contentLength, value: String(partSize))
                partReq.body = .stream(partStream, length: .known(partSize))

                let partRes = try await client.execute(partReq, timeout: .minutes(5))
                guard partRes.status == .ok || partRes.status == .created else {
                    throw Abort(partRes.status, reason: "Failed to upload archive part \(partNumber)")
                }

                let partBody = try await partRes.body.collect(upTo: 64 * 1024)
                let partDTO = try Self.decoder.decode(PartResultDTO.self, from: partBody)
                completedParts.append(partDTO)
                remainingTotal -= partSize
                partNumber += 1
            }

            var completeReq = HTTPClientRequest(
                url: "\(baseURL)/api/files/multipart/\(session.sessionID.uuidString)/complete"
            )
            completeReq.method = .POST
            completeReq.headers.bearerAuthorization = BearerAuthorization(token: session.token)
            completeReq.headers.replaceOrAdd(name: .contentType, value: "application/json")
            completeReq.body = .bytes(try JSONEncoder().encode(CompleteMultipartPayload(parts: completedParts)))

            let completeRes = try await client.execute(completeReq, timeout: .minutes(2))
            guard completeRes.status == .ok || completeRes.status == .created else {
                throw Abort(completeRes.status, reason: "Failed to complete archive upload")
            }

            var createdID: UUID? = session.fileID
            if let body = try? await completeRes.body.collect(upTo: 64 * 1024) {
                struct UploadResult: Decodable { let id: UUID? }
                if let decodedID = try? Self.decoder.decode(UploadResult.self, from: body).id {
                    createdID = decodedID
                }
            }
            return (candidateName, createdID)
        } catch {
            var abortReq = HTTPClientRequest(
                url: "\(baseURL)/api/files/multipart/\(session.sessionID.uuidString)/abort"
            )
            abortReq.method = .DELETE
            abortReq.headers.bearerAuthorization = BearerAuthorization(token: session.token)
            _ = try? await client.execute(abortReq, timeout: .seconds(15))
            throw error
        }
    }
}
