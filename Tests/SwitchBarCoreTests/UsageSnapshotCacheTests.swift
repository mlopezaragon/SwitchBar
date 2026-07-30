import Foundation
import Testing
@testable import SwitchBarCore

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("switchbar-cache-\(UUID().uuidString)")
}

@Test
func laCacheSobreviveAUnReinicio() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = UsageSnapshotCache(directoryURL: directory)

    let future = Date().addingTimeInterval(3_600)
    let snapshot = UsageSnapshot(
        fiveHour: UsageWindow(utilization: 55, resetsAt: future),
        sevenDay: UsageWindow(utilization: 25, resetsAt: nil),
        sevenDayOpus: nil,
        fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    try cache.save(["cuenta-a": snapshot])

    let reloaded = UsageSnapshotCache(directoryURL: directory).load()
    let restored = try #require(reloaded["cuenta-a"])
    #expect(restored.fiveHour?.utilization == 55)
    #expect(restored.sevenDay?.utilization == 25)
    #expect(restored.sevenDayOpus == nil)
    #expect(
        restored.fetchedAt.timeIntervalSince1970 == 1_700_000_000
    )
    let interval = try #require(
        restored.fiveHour?.resetsAt?.timeIntervalSince1970
    )
    #expect(abs(interval - future.timeIntervalSince1970) < 1)
}

@Test
func lasVentanasConReinicioPasadoSeDescartanAlCargar() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = UsageSnapshotCache(directoryURL: directory)

    let snapshot = UsageSnapshot(
        fiveHour: UsageWindow(
            utilization: 97,
            resetsAt: Date().addingTimeInterval(-60)
        ),
        sevenDay: UsageWindow(
            utilization: 40,
            resetsAt: Date().addingTimeInterval(86_400)
        ),
        sevenDayOpus: nil,
        fetchedAt: Date()
    )
    try cache.save(["cuenta-a": snapshot])

    let restored = try #require(cache.load()["cuenta-a"])
    #expect(restored.fiveHour == nil)
    #expect(restored.sevenDay?.utilization == 40)
}

@Test
func unaCacheCorruptaOInexistenteDevuelveVacio() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = UsageSnapshotCache(directoryURL: directory)
    #expect(cache.load().isEmpty)

    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    try Data("no es json".utf8).write(
        to: directory.appendingPathComponent("usage-cache.json")
    )
    #expect(cache.load().isEmpty)
}
