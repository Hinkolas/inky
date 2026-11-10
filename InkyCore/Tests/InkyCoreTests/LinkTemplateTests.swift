import Foundation
import Testing
@testable import InkyCore

@Suite struct LinkTemplateTests {
    @Test func plainLinkHasNoArguments() {
        let template = LinkTemplate("https://example.com")
        #expect(template.arguments.isEmpty)
        #expect(template.resolve(.init()) == "https://example.com")
    }

    @Test func argumentIsEncodedIntoTheLink() {
        let template = LinkTemplate("https://example.com/search?q={argument name=\"Query\"}")
        #expect(template.arguments == [Argument(name: "Query")])
        #expect(template.resolve(.init(arguments: ["swift & lua"])) == "https://example.com/search?q=swift%20%26%20lua")
    }

    @Test func argumentsWithTheSameNameShareOneInput() {
        let template = LinkTemplate("https://example.com/{argument name=\"a\"}/{argument name=\"b\"}/{argument name=\"a\"}")
        #expect(template.arguments.map(\.name) == ["a", "b"])
        #expect(template.resolve(.init(arguments: ["1", "2"])) == "https://example.com/1/2/1")
    }

    @Test func unnamedArgumentsAreSeparate() {
        let template = LinkTemplate("https://example.com/{argument}/{argument}")
        #expect(template.arguments.count == 2)
        #expect(template.resolve(.init(arguments: ["x", "y"])) == "https://example.com/x/y")
    }

    @Test func defaultFillsAnEmptyArgument() {
        let template = LinkTemplate("https://example.com/{argument name=\"lang\" default=\"en\"}")
        #expect(template.arguments.first?.isRequired == false)
        #expect(template.resolve(.init(arguments: [""])) == "https://example.com/en")
        #expect(template.resolve(.init(arguments: ["de"])) == "https://example.com/de")
    }

    @Test func modifiersApplyInOrder() {
        let values = LinkTemplate.Values(clipboard: "  Hello World ")
        #expect(LinkTemplate("x:{clipboard | trim | uppercase}").resolve(values) == "x:HELLO%20WORLD")
        #expect(LinkTemplate("x:{clipboard | trim | raw}").resolve(values) == "x:Hello World")
    }

    @Test func filePathsAreNotEncoded() {
        let template = LinkTemplate("~/Projects/{argument name=\"Folder\"}")
        #expect(template.isFilePath)
        #expect(template.resolve(.init(arguments: ["My App"])) == "~/Projects/My App")
    }

    @Test func unknownBracesAreLeftAlone() {
        let template = LinkTemplate("https://example.com/{id}/x?json={\"a\":1}")
        #expect(template.arguments.isEmpty)
        #expect(template.resolve(.init()) == "https://example.com/{id}/x?json={\"a\":1}")
    }

    @Test func formatsDates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.date(from: DateComponents(year: 2026, month: 3, day: 9))!
        let template = LinkTemplate("x:{date format=\"yyyy-MM-dd\"}")
        #expect(template.resolve(.init(date: date)) == "x:2026-03-09")
    }

    @Test func detectsWhichValuesAreNeeded() {
        let template = LinkTemplate("x:{selection}")
        #expect(template.uses(.selection))
        #expect(!template.uses(.clipboard))
    }

    @Test func buildsURLs() throws {
        #expect(try QuicklinkOpener.url(from: "example.com/a").absoluteString == "https://example.com/a")
        #expect(try QuicklinkOpener.url(from: "obsidian://open?vault=x").scheme == "obsidian")
        #expect(try QuicklinkOpener.url(from: "/tmp").isFileURL)
        #expect(throws: InkyError.self) { try QuicklinkOpener.url(from: "  ") }
    }
}
