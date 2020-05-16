import Vapor
import Fluent


struct IngestorCommand: Command {
    let defaultLimit = 1

    struct Signature: CommandSignature {
        @Option(name: "limit", short: "l")
        var limit: Int?
    }

    var help: String { "Run package ingestion (fetching repository metadata)" }

    func run(using context: CommandContext, signature: Signature) throws {
        let limit = signature.limit ?? defaultLimit
        context.console.info("Ingesting (limit: \(limit)) ...")
        let request = ingest(application: context.application,
                             database: context.application.db,
                             limit: limit)
        context.console.info("Processing ...", newLine: true)
        try request.wait()
    }

}


func ingest(application: Application, database: Database, limit: Int) -> EventLoopFuture<Void> {
    let packages = Package.fetchCandidates(application.db, for: .ingestion, limit: limit)
    let metadata = packages.flatMap { fetchMetadata(client: application.client, packages: $0) }
    let updates = metadata.flatMap { updateRespositories(on: application.db, metadata: $0) }
    return updates.flatMap { updateStatus(application: application, results: $0, stage: .ingestion) }
}


typealias PackageMetadata = (Package, Github.Metadata)


func fetchMetadata(client: Client, packages: [Package]) -> EventLoopFuture<[Result<(Package, Github.Metadata), Error>]> {
    let ops = packages.map { pkg in Current.fetchMetadata(client, pkg).map { (pkg, $0) } }
    return EventLoopFuture.whenAllComplete(ops, on: client.eventLoop)
}


func updateRespositories(on database: Database, metadata: [Result<(Package, Github.Metadata), Error>]) -> EventLoopFuture<[Result<Package, Error>]> {
    let ops = metadata.map { result -> EventLoopFuture<Package> in
        switch result {
            case let .success((pkg, md)):
                return insertOrUpdateRepository(on: database, for: pkg, metadata: md)
                    .map { pkg }
            case let .failure(error):
                return database.eventLoop.future(error: error)
        }
    }
    return EventLoopFuture.whenAllComplete(ops, on: database.eventLoop)
}


func updateTables(client: Client, database: Database, result: Result<PackageMetadata, Error>) -> EventLoopFuture<Void> {
    do {
        let (pkg, md) = try result.get()
        return insertOrUpdateRepository(on: database, for: pkg, metadata: md)
            .flatMap {
                pkg.status = .ok
                pkg.processingStage = .ingestion
                return pkg.save(on: database)
            }
    } catch {
        return recordError(client: client, database: database, error: error, stage: .ingestion)
    }
}


func insertOrUpdateRepository(on database: Database, for package: Package, metadata: Github.Metadata) -> EventLoopFuture<Void> {
    guard let pkgId = try? package.requireID() else {
        return database.eventLoop.makeFailedFuture(AppError.genericError(nil, "package id not found"))
    }

    return Repository.query(on: database)
        .filter(\.$package.$id == pkgId)
        .first()
        .flatMap { repo -> EventLoopFuture<Void> in
            if let repo = repo {
                repo.defaultBranch = metadata.defaultBranch
                repo.summary = metadata.description
                repo.forks = metadata.forksCount
                repo.license = .init(from: metadata.license)
                repo.stars = metadata.stargazersCount
                // TODO: find and assign parent repo
                return repo.save(on: database)
            } else {
                do {
                    return try Repository(package: package, metadata: metadata)
                        .save(on: database)
                } catch {
                    return database.eventLoop.future(error:
                        AppError.genericError(package.id,
                                              "Failed to create Repository for \(package.url)")
                    )
                }
            }
    }
}
