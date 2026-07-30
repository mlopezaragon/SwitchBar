import Foundation
import Testing
@testable import ClaudeSwitchCore

private let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

private let supportedLanguages = [
    "es", "en", "fr", "de", "pt-BR", "it",
    "ja", "ko", "zh-Hans", "zh-Hant"
]

private func localizationCatalog(
    _ language: String
) throws -> [String: String] {
    let url = projectRoot
        .appendingPathComponent("Sources/ClaudeSwitchCore/Resources")
        .appendingPathComponent("\(language).lproj/Localizable.strings")
    let data = try Data(contentsOf: url)
    return try #require(
        PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: String]
    )
}

private func swiftSourceFiles(in directory: URL) -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: nil
    ) else { return [] }
    return enumerator.compactMap { $0 as? URL }
        .filter { $0.pathExtension == "swift" }
}

@Test func todosLosCatalogosEstanCompletos() throws {
    let reference = try localizationCatalog("en")
    #expect(!reference.isEmpty)

    for language in supportedLanguages {
        let catalog = try localizationCatalog(language)
        #expect(
            Set(catalog.keys) == Set(reference.keys),
            "El catálogo \(language) no tiene las mismas claves"
        )
        #expect(
            catalog.values.allSatisfy { !$0.isEmpty },
            "El catálogo \(language) contiene traducciones vacías"
        )
    }
}

@Test func todasLasClavesUsadasExistenEnTodosLosIdiomas() throws {
    let reference = try localizationCatalog("en")
    let sources = [
        projectRoot.appendingPathComponent("Sources/ClaudeSwitch"),
        projectRoot.appendingPathComponent("Sources/ClaudeSwitchCore")
    ].flatMap(swiftSourceFiles)
    let expression = try NSRegularExpression(
        pattern: #"L10n\.tr\(\s*"([^"]+)""#
    )
    var usedKeys = Set<String>()

    for file in sources {
        let source = try String(contentsOf: file, encoding: .utf8)
        let range = NSRange(source.startIndex..., in: source)
        for match in expression.matches(in: source, range: range) {
            guard let keyRange = Range(match.range(at: 1), in: source) else {
                continue
            }
            usedKeys.insert(String(source[keyRange]))
        }
    }

    #expect(!usedKeys.isEmpty)
    #expect(usedKeys.subtracting(reference.keys).isEmpty)
    #expect(Set(reference.keys).subtracting(usedKeys).isEmpty)
    for language in supportedLanguages {
        let catalog = try localizationCatalog(language)
        #expect(
            usedKeys.subtracting(catalog.keys).isEmpty,
            "Faltan claves usadas en \(language)"
        )
    }
}

@Test func formatosVariablesSonValidosEnTodosLosIdiomas() throws {
    for language in supportedLanguages {
        let catalog = try localizationCatalog(language)
        let locale = Locale(identifier: language)
        let threshold = try #require(
            catalog["auto_switch.threshold.format"]
        )
        let cooldown = try #require(catalog["usage.cooldown.active"])

        #expect(
            String(
                format: threshold,
                locale: locale,
                arguments: [95, "sample"]
            ).contains("95")
        )
        #expect(
            String(
                format: cooldown,
                locale: locale,
                arguments: [10]
            ).contains("10")
        )
    }
}

@Test func marcadoresDeFormatoCoincidenEntreIdiomas() throws {
    let reference = try localizationCatalog("en")
    let expression = try NSRegularExpression(
        pattern: #"%(?:\d+\$)?(?:@|d)"#
    )

    func markers(in value: String) -> [String] {
        let range = NSRange(value.startIndex..., in: value)
        return expression.matches(in: value, range: range).compactMap {
            Range($0.range, in: value).map { String(value[$0]) }
        }.sorted()
    }

    for language in supportedLanguages {
        let catalog = try localizationCatalog(language)
        for key in reference.keys {
            let expected = markers(in: try #require(reference[key]))
            let actual = markers(in: try #require(catalog[key]))
            #expect(
                actual == expected,
                "Los parámetros de \(key) no coinciden en \(language)"
            )
        }
    }
}

@Test func elBundleDeSwiftPMIncluyeLasTraducciones() {
    #expect(L10n.tr("account.add") != "account.add")
}
