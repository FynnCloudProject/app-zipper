import Vapor

struct ZipperController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.get("health", use: health)

        let api = routes.grouped("api")
        api.post("zip", use: zip)
        api.get("zip", use: health)
    }

    func health(req: Request) async throws -> HealthResponse {
        HealthResponse(status: "healthy", app: "zipper", version: "1.0.0")
    }

    func zip(req: Request) async throws -> ZipResponse {
        let input = try req.content.decode(ZipRequest.self)

        guard !input.resolvedFileIDs.isEmpty else {
            throw Abort(.badRequest, reason: "No files specified")
        }

        let token = input.token
            ?? req.headers.first(name: "X-App-Token")
            ?? req.headers.bearerAuthorization?.token

        guard let token, !token.isEmpty else {
            throw Abort(.unauthorized, reason: "Missing authentication token")
        }

        let baseURL = Environment.get("FYNNCLOUD_API_URL") ?? "http://127.0.0.1:8080"
        let service = ZipperService(
            httpClient: req.application.http.client.shared,
            baseURL: baseURL,
            logger: req.logger
        )

        return try await service.createArchive(request: input, token: token)
    }
}
