import Testing
@testable import EnsembleCore

@Suite struct WhatsNewTests {
    private let three = "sparkles | Faster start | Ensemble opens in half the time.\nhand.raised | Steadier pinch | A pinch no longer drops mid-sentence.\ngearshape | Simpler settings | Fewer switches to find."

    @Test func threeLinesParseIntoIconHeadingAndSubheading() {
        let items = WhatsNew.parse(three)
        #expect(items?.count == 3)
        #expect(items?.first == WhatsNew.Item(icon: "sparkles", heading: "Faster start", subheading: "Ensemble opens in half the time."))
    }

    @Test func fiveLinesAreTheMostAndBlankLinesAndCarriageReturnsAreIgnored() {
        let five = three + "\r\n\r\nbolt | Quicker send | Sending takes one beat.\r\nstar | Tidy menu | The menu is shorter.\r\n"
        #expect(WhatsNew.parse(five)?.count == 5)
    }

    @Test func aMissingSummaryIsNil() {
        #expect(WhatsNew.parse(nil) == nil)
        #expect(WhatsNew.parse("") == nil)
        #expect(WhatsNew.parse("  \n \n") == nil)
    }

    @Test func fewerThanThreeOrMoreThanFiveItemsIsNil() {
        #expect(WhatsNew.parse("a | b | c\nd | e | f") == nil)
        #expect(WhatsNew.parse(three + "\na | b | c\nd | e | f\ng | h | i") == nil)
    }

    @Test func oneMalformedLineMakesTheWholeSummaryNil() {
        #expect(WhatsNew.parse(three + "\nonly two | fields") == nil)
        #expect(WhatsNew.parse(three + "\na | b | c | d") == nil)
        #expect(WhatsNew.parse(three + "\n | empty icon | text") == nil)
        #expect(WhatsNew.parse(three + "\nicon | | text") == nil)
        #expect(WhatsNew.parse(three + "\nicon | heading | ") == nil)
        #expect(WhatsNew.parse(three + "\nnot an icon | heading | text") == nil)
        #expect(WhatsNew.parse(three + "\nicon-name | heading | text") == nil)
    }
}
