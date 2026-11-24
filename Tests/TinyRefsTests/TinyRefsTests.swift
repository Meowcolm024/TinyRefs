import Foundation
import Testing
import TinyRefs

private struct ImportedReference: Decodable {
    let citationKey: String
    let entryType: String
    let fields: [String: String]
}

private func importFixture(_ filename: String) throws -> [ImportedReference] {
    let fixture = try #require(
        Bundle.module.url(forResource: filename, withExtension: nil, subdirectory: "Fixtures"),
        "Missing bibliography fixture \(filename)"
    )
    let json = try BibLaTeX.importJSON(from: Data(contentsOf: fixture))
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode([ImportedReference].self, from: Data(json.utf8))
}

@Test func importBarendregtBibliography() throws {
    let entries = try importFixture("Barendregt1993.bib")
    #expect(entries.count == 1)
    let article = try #require(entries.first)
    #expect(article.citationKey == "Barendregt1983")
    #expect(article.entryType == "article")
    #expect(article.fields["year"] == "{1983}")
    #expect(article.fields["doi"] == "{10.2307/2273659}")
    #expect(article.fields["pages"] == "{931–940}")
}

@Test func importHaskellBibliography() throws {
    let entries = try importFixture("Haskell.bib")
    #expect(entries.map(\.citationKey) == ["Jones1992", "Vytiniotis2011", "Bernardy2017"])
    #expect(entries.allSatisfy { $0.entryType == "article" })

    let linearHaskell = try #require(entries.first { $0.citationKey == "Bernardy2017" })
    #expect(linearHaskell.fields["month"] == "{December}")
    #expect(linearHaskell.fields["issue_date"] == "{January 2018}")
    #expect(linearHaskell.fields["articleno"] == "{5}")
    let abstract = try #require(linearHaskell.fields["abstract"])
    #expect(abstract.contains("\n"))
    #expect(abstract.contains("&nbsp;—&nbsp;"))
}

@Test func importAcceptsEmptyInput() throws {
    #expect(try BibLaTeX.importJSON(from: Data()) == "[]")
}

@Test func importReportsMalformedEntries() {
    do {
        _ = try BibLaTeX.importJSON(from: Data("@article{LinearHaskell, title = {Linear Haskell}".utf8))
        Issue.record("Expected a parse error")
    } catch BibLaTeX.ImportError.parse(let message) {
        #expect(message.contains("at byte"))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test func importReportsInvalidUTF8() {
    do {
        _ = try BibLaTeX.importJSON(from: Data([0xFF]))
        Issue.record("Expected an invalid input error")
    } catch BibLaTeX.ImportError.invalidInput(let message) {
        #expect(message.contains("byte 0"))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}
