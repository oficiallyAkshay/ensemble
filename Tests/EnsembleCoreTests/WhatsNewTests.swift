import Testing
@testable import EnsembleCore

@Suite struct WhatsNewTests {
    private let three = """
    sparkles | Faster start | Ensemble opens in half the time.
    hand.pinch | Steadier pinch | A held pinch no longer drops out.
    mic.fill | Clearer dictation | The microphone icon shows when it is listening.
    """

    @Test func parsesThreeItems() {
        let items = WhatsNew.parse(three)
        #expect(items?.count == 3)
        #expect(items?[1] == WhatsNewItem(icon: "hand.pinch", heading: "Steadier pinch", subheading: "A held pinch no longer drops out."))
    }

    @Test func parsesFiveItemsAndSkipsBlankLinesAndCarriageReturns() {
        let text = (1...5).map { "star | Heading \($0) | Sub \($0)\r\n\r\n" }.joined()
        #expect(WhatsNew.parse(text)?.count == 5)
    }

    @Test func missingSummaryFallsBack() {
        #expect(WhatsNew.parse(nil) == nil)
        #expect(WhatsNew.parse("") == nil)
    }

    @Test func tooFewOrTooManyItemsFallBack() {
        let two = three.split(separator: "\n").prefix(2).joined(separator: "\n")
        #expect(WhatsNew.parse(two) == nil)
        #expect(WhatsNew.parse(three + "\nstar | A | B\nstar | C | D\nstar | E | F") == nil)
    }

    @Test func oneMalformedLineFallsBackWholly() {
        #expect(WhatsNew.parse(three + "\nstar | only a heading") == nil)
        #expect(WhatsNew.parse(three.replacingOccurrences(of: "sparkles", with: "") ) == nil)
        #expect(WhatsNew.parse(three.replacingOccurrences(of: "Faster start", with: " ")) == nil)
        #expect(WhatsNew.parse(three.replacingOccurrences(of: "half the time", with: "half | the time")) == nil)
        #expect(WhatsNew.parse(three.replacingOccurrences(of: "sparkles", with: "spark les")) == nil)
        #expect(WhatsNew.parse(three.replacingOccurrences(of: "sparkles", with: "spärkles")) == nil)
    }
}
