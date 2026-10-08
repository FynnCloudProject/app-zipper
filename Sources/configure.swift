import Vapor

public func configure(_ app: Application) async throws {
    let port = Environment.get("PORT").flatMap(Int.init) ?? 8080
    let host = Environment.get("HOST") ?? "0.0.0.0"

    app.http.server.configuration.hostname = host
    app.http.server.configuration.port = port
    app.routes.defaultMaxBodySize = "500mb"

    try routes(app)
    app.logger.info("Zipper listening on http://\(host):\(port)")
}
