import Vapor

public struct ZipperController: RouteCollection, Sendable {
    public init() {}

    public func boot(routes: any RoutesBuilder) throws {
        routes.get("health", use: health)

        let api = routes.grouped("api")
        api.post("zip", use: zip)
        api.get("zip", use: health)
    }

    @Sendable
    public func health(req: Request) async throws -> HealthResponse {
        HealthResponse(status: "healthy", app: "zipper", version: "1.0.0")
    }

    @Sendable
    public func zip(req: Request) async throws -> ZipResponse {
        let request = try req.content.decode(ZipRequest.self)

        guard !request.resolvedFileIDs.isEmpty else {
            throw Abort(.badRequest, reason: "No files specified")
        }

        let token = request.token
            ?? req.headers.first(name: "X-App-Token")
            ?? req.headers.bearerAuthorization?.token

        guard let authToken = token, !authToken.isEmpty else {
            throw Abort(.unauthorized, reason: "Missing authentication token")
        }

        let baseURL = Environment.get("FYNNCLOUD_API_URL") ?? "http://127.0.0.1:8080"
        let zipper = ZipperService(
            httpClient: req.application.http.client.shared,
            baseURL: baseURL,
            logger: req.logger
        )

        return try await zipper.createArchive(request: request, token: authToken)
    }
}
