import XCTest
@testable import Resim

final class LocalizationTests: XCTestCase {
    func testRegionalLanguagePreferencesResolveToSupportedTranslations() {
        let languages = Bundle.main.localizations
        XCTAssertTrue(languages.contains("en"))
        XCTAssertTrue(languages.contains("es"))
        XCTAssertEqual(Bundle.main.developmentLocalization, "en")
        for region in ["es-AR", "es-ES", "es-MX"] {
            XCTAssertEqual(Bundle.preferredLocalizations(from: languages, forPreferences: [region, "en"]).first, "es")
        }
        for region in ["en-US", "en-GB"] {
            XCTAssertEqual(Bundle.preferredLocalizations(from: languages, forPreferences: [region, "es"]).first, "en")
        }
        XCTAssertEqual(Bundle.preferredLocalizations(from: languages, forPreferences: ["fr-FR", "es-AR", "en"]).first, "es")
    }

    func testCompiledCatalogsHaveMatchingCoverageAndFormatArguments() throws {
        let english = try table("en", extension: "strings")
        let spanish = try table("es", extension: "strings")
        XCTAssertGreaterThan(english.count, 100)
        XCTAssertEqual(Set(english.keys), Set(spanish.keys))
        let pattern = try NSRegularExpression(pattern: #"%(?:\d+\$)?(?:lld|@)"#)
        func arguments(_ value: String) -> [String] {
            pattern.matches(in: value, range: NSRange(value.startIndex..., in: value))
                .map { String(value[Range($0.range, in: value)!]) }
        }
        for (key, value) in english {
            let translation = try XCTUnwrap(spanish[key] as? String, key)
            XCTAssertFalse(translation.isEmpty, key)
            XCTAssertEqual(arguments(try XCTUnwrap(value as? String)), arguments(translation), key)
        }
        let englishPlurals = try table("en", extension: "stringsdict")
        let spanishPlurals = try table("es", extension: "stringsdict")
        XCTAssertEqual(Set(englishPlurals.keys), Set(spanishPlurals.keys))
        XCTAssertEqual(englishPlurals.count, 4)
    }

    func testTranslatedInterfaceDiagnosticsAndPlurals() throws {
        for (language, add, error, singular, plural) in [
            ("en", "Add Images…", "The file is empty.", "1 image", "2 images"),
            ("es", "Agregar imágenes…", "El archivo está vacío.", "1 imagen", "2 imágenes")
        ] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            XCTAssertEqual(bundle.localizedString(forKey: "Add Images…", value: nil, table: nil), add)
            XCTAssertEqual(bundle.localizedString(forKey: "The file is empty.", value: nil, table: nil), error)
            let format = bundle.localizedString(forKey: "%lld images", value: nil, table: nil)
            XCTAssertEqual(String.localizedStringWithFormat(format, Int64(1)), singular)
            XCTAssertEqual(String.localizedStringWithFormat(format, Int64(2)), plural)
            let copyright = bundle.localizedString(forKey: "NSHumanReadableCopyright", value: nil, table: "InfoPlist")
            XCTAssertTrue(copyright.contains(language == "es" ? "Incluye software" : "Includes third-party"))
        }
    }

    private func table(_ language: String, extension ext: String) throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "Localizable", withExtension: ext, subdirectory: nil, localization: language))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
    }
}
