import AsyncHTTPClient
import Foundation
import Logging
import Vapor

struct ZipperService {
    let client: FynnCloudClient
    let logger: Logger

    init(httpClient: HTTPClient, baseURL: String, logger: Logger) {
        self.client = FynnCloudClient(client: httpClient, baseURL: baseURL, logger: logger)
        self.logger = logger
    }

    private struct DownloadTask {
        let fileID: UUID
        let destination: URL
    }

    func createArchive(request: ZipRequest, token: String) async throws -> ZipResponse {
        let targetIDs = request.resolvedFileIDs
        guard !targetIDs.isEmpty else {
            throw Abort(.badRequest, reason: "No files specified for compression")
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("zipper-\(UUID().uuidString)")
        let stagingDir = tempDir.appendingPathComponent("content")
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let (metadata, parentID) = try await fetchMetadata(for: targetIDs, fallbackParent: request.parentID, token: token)
        let downloads = try await stageTree(targetIDs: targetIDs, metadata: metadata, stagingDir: stagingDir, token: token)
        try await download(tasks: downloads, token: token)

        let archiveName = resolveArchiveName(request.archiveName, targetIDs: targetIDs, metadata: metadata)
        let archiveURL = tempDir.appendingPathComponent(archiveName)
        let compression = max(0, min(9, request.compressionLevel ?? 6))
        let archiveSize = try compress(from: stagingDir, to: archiveURL, level: compression)

        let (finalName, createdID) = try await client.uploadArchive(
            name: archiveName,
            fileURL: archiveURL,
            size: archiveSize,
            parentID: parentID,
            token: token
        )

        let formatted = ByteCountFormatter.string(fromByteCount: archiveSize, countStyle: .binary)
        logger.info("Created '\(finalName)' (\(formatted))")

        return ZipResponse(
            success: true,
            archiveName: finalName,
            archiveSize: archiveSize,
            fileCount: max(downloads.count, targetIDs.count),
            createdFileID: createdID,
            message: "Successfully created '\(finalName)' (\(formatted))"
        )
    }

    private func fetchMetadata(
        for targetIDs: [UUID],
        fallbackParent: UUID?,
        token: String
    ) async throws -> ([UUID: RemoteFileMetadata], UUID?) {
        var metadata: [UUID: RemoteFileMetadata] = [:]
        var parentID = fallbackParent

        try await withThrowingTaskGroup(of: (UUID, RemoteFileMetadata).self) { group in
            for id in targetIDs {
                group.addTask {
                    let meta = try await self.client.fetchMetadata(fileID: id, token: token)
                    return (id, meta)
                }
            }
            for try await (id, meta) in group {
                metadata[id] = meta
                if parentID == nil, let p = meta.parent?.id {
                    parentID = p
                }
            }
        }

        return (metadata, parentID)
    }

    private func stageTree(
        targetIDs: [UUID],
        metadata: [UUID: RemoteFileMetadata],
        stagingDir: URL,
        token: String
    ) async throws -> [DownloadTask] {
        var downloads: [DownloadTask] = []
        var existingNames = Set<String>()
        var folderQueue: [(folderID: UUID, localDir: URL)] = []

        for id in targetIDs {
            guard let meta = metadata[id] else { continue }
            let name = uniqueFilename(meta.filename, isDirectory: meta.isDirectory == true, existing: &existingNames)
            let dest = stagingDir.appendingPathComponent(name)

            if meta.isDirectory == true {
                try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                folderQueue.append((folderID: id, localDir: dest))
            } else {
                downloads.append(DownloadTask(fileID: id, destination: dest))
            }
        }

        while !folderQueue.isEmpty {
            let (folderID, localDir) = folderQueue.removeFirst()
            let children = try await client.listFolder(folderID: folderID, token: token)
            var folderNames = Set<String>()

            for child in children {
                guard let childID = child.id else { continue }
                let name = uniqueFilename(child.filename, isDirectory: child.isDirectory, existing: &folderNames)
                let dest = localDir.appendingPathComponent(name)

                if child.isDirectory {
                    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                    folderQueue.append((folderID: childID, localDir: dest))
                } else {
                    downloads.append(DownloadTask(fileID: childID, destination: dest))
                }
            }
        }

        return downloads
    }

    private func download(tasks: [DownloadTask], token: String) async throws {
        guard !tasks.isEmpty else { return }

        let concurrency = min(8, tasks.count)
        var iterator = tasks.makeIterator()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<concurrency {
                if let task = iterator.next() {
                    group.addTask {
                        try await self.client.streamDownload(fileID: task.fileID, to: task.destination, token: token)
                    }
                }
            }

            while let _ = try await group.next() {
                if let next = iterator.next() {
                    group.addTask {
                        try await self.client.streamDownload(fileID: next.fileID, to: next.destination, token: token)
                    }
                }
            }
        }
    }

    private func compress(from sourceDir: URL, to archiveURL: URL, level: Int) throws -> Int64 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-\(level)", "-q", "-r", archiveURL.path, "."]
        process.currentDirectoryURL = sourceDir

        let pipe = Pipe()
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errData = pipe.fileHandleForReading.readDataToEndOfFile()
            let err = String(data: errData, encoding: .utf8) ?? "code \(process.terminationStatus)"
            logger.error("zip process failed: \(err)")
            throw Abort(.internalServerError, reason: "Compression failed: \(err)")
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: archiveURL.path)
        return (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func resolveArchiveName(
        _ requested: String?,
        targetIDs: [UUID],
        metadata: [UUID: RemoteFileMetadata]
    ) -> String {
        var name = (requested ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            if targetIDs.count == 1, let firstID = targetIDs.first, let meta = metadata[firstID] {
                let isDir = meta.isDirectory == true
                let stem = isDir ? meta.filename : (meta.filename as NSString).deletingPathExtension
                name = "\(stem).zip"
            } else {
                name = "Archive.zip"
            }
        }
        if !name.lowercased().hasSuffix(".zip") {
            name += ".zip"
        }
        return name.replacingOccurrences(of: "/", with: "_")
    }

    private func uniqueFilename(_ name: String, isDirectory: Bool, existing: inout Set<String>) -> String {
        let clean = name.replacingOccurrences(of: "/", with: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        let base = clean.isEmpty ? (isDirectory ? "Folder" : "File") : clean
        var candidate = base
        var counter = 1

        while existing.contains(candidate.lowercased()) {
            if isDirectory {
                candidate = "\(base) (\(counter))"
            } else {
                let ext = (base as NSString).pathExtension
                let stem = (base as NSString).deletingPathExtension
                candidate = ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
            }
            counter += 1
        }

        existing.insert(candidate.lowercased())
        return candidate
    }
}
