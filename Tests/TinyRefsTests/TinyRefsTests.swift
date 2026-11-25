import Foundation
import Testing
import TinyRefs

private struct ImportedReference: Decodable {
    let citationKey: String
    let entryType: String
    let fields: [String: String]
    let structured: StructuredBibliographyFields
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
    #expect(article.structured.authors.map(\.displayName) == ["Henk Barendregt", "Mario Coppo", "Mariangiola Dezani-Ciancaglini"])
    #expect(article.structured.keywords.isEmpty)
    #expect(article.structured.date?.start?.year == 1983)
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
    #expect(linearHaskell.structured.authors.map(\.familyName) == ["Bernardy", "Boespflug", "Newton", "Peyton Jones", "Spiwack"])
    #expect(linearHaskell.structured.keywords == ["typestate", "polymorphism", "linear types", "linear logic", "laziness", "Haskell", "GHC"])
    #expect(linearHaskell.structured.date?.text == "2017-12")
    #expect(linearHaskell.structured.date?.start?.month == 12)
    #expect(linearHaskell.structured.abstract?.contains("system — both") == true)
    #expect(linearHaskell.structured.containerTitle == "Proc. ACM Program. Lang.")
}

@Test func structuresNamesAndProtectedKeywordsWithDateRanges() throws {
    let source = #"""
        @string{topic = "primitive recursion"}
        @book{SystemT,
          title = {G{\"o}del's {System T}},
          author = {G{\"o}del, Kurt and {Logic and Computation Group}},
          editor = {de Bruijn, Nicolaas},
          date = {1958-01/1959?},
          keywords = topic # {, {types, terms}, computability},
          abstract = {Recursion&nbsp;in G{\"o}del's system.},
          localfield = {Keep this value}
        }
        @misc{UntypedDate, date = {20266-00-XX}, abstract = {Price is $5}, keywords = {logic}}
        @misc{Untitled,}
        """#
    let input = Data(source.utf8)
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let entries = try decoder.decode([ImportedReference].self, from: Data(BibLaTeX.importJSON(from: input).utf8))
    #expect(entries.count == 3)
    let systemT = try #require(entries.first)
    #expect(systemT.structured.title == "Gödel's System T")
    #expect(systemT.structured.authors.map(\.displayName) == ["Kurt Gödel", "Logic and Computation Group"])
    #expect(systemT.structured.editors.first?.prefix == "de")
    #expect(systemT.structured.editors.first?.familyName == "Bruijn")
    #expect(systemT.structured.keywords == ["primitive recursion", "types, terms", "computability"])
    #expect(systemT.structured.date?.kind == .range)
    #expect(systemT.structured.date?.start?.month == 1)
    #expect(systemT.structured.date?.end?.year == 1959)
    #expect(systemT.structured.date?.uncertain == true)
    #expect(systemT.structured.abstract == "Recursion in Gödel's system.")
    #expect(systemT.fields["localfield"] == "{Keep this value}")

    let unusual = try #require(entries.first { $0.citationKey == "UntypedDate" })
    #expect(unusual.structured.date?.kind == .unparsed)
    #expect(unusual.structured.date?.text == "20266-00-XX")
    #expect(unusual.structured.keywords == ["logic"])
    #expect(unusual.fields["abstract"] == "{Price is $5}")
    let empty = try #require(entries.last)
    #expect(empty.structured.authors.isEmpty)
    #expect(empty.structured.keywords.isEmpty)

    let metadata = try BibLaTeX.references(from: input)
    #expect(try BibLaTeX.structuredFields(for: metadata) == entries.map(\.structured))
}

@Test func importAcceptsEmptyInput() throws {
    #expect(try BibLaTeX.importJSON(from: Data()) == "[]")
}

@Test func editingBibLaTeXListsKeepsProtectedItemsAndNameParts() throws {
    let author = #"{G{\"o}del, Kurt and {Types and Programming Group} and family={de Bruijn}, given=Nicolaas, id={DB}}"#
    let items = try BibLaTeX.listItems(in: author, field: .author)
    #expect(items == [#"G{\"o}del, Kurt"#, "{Types and Programming Group}", "family={de Bruijn}, given=Nicolaas, id={DB}"])
    let changed = [items[2], "Church, Alonzo", items[1]]
    let edited = try BibLaTeX.listExpression(from: changed, field: .author)
    #expect(try BibLaTeX.listItems(in: edited, field: .author) == changed)

    let keywords = try BibLaTeX.listItems(in: #""type theory" # ", {types, terms}, $F(a,b)$""#, field: .keywords)
    #expect(keywords == ["type theory", "{types, terms}", "$F(a,b)$"])
    #expect(try BibLaTeX.listExpression(from: [], field: .keywords) == "{}")
    #expect(throws: BibLaTeX.BridgeError.self) {
        try BibLaTeX.listExpression(from: ["types, terms"], field: .keywords)
    }
    #expect(throws: BibLaTeX.BridgeError.self) {
        try BibLaTeX.listExpression(from: ["Gödel, Kurt and Church, Alonzo"], field: .author)
    }
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
