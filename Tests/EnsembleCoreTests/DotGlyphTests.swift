import Testing
@testable import EnsembleCore

@Suite struct DotGlyphTests {
    @Test func scrollSymbolOnlyWhileScrollingWithPinchHeld() {
        #expect(DotGlyph.showsScroll(scrollActive: true, pinchHeld: true))
        #expect(!DotGlyph.showsScroll(scrollActive: true, pinchHeld: false))
        #expect(!DotGlyph.showsScroll(scrollActive: false, pinchHeld: true))
        #expect(!DotGlyph.showsScroll(scrollActive: false, pinchHeld: false))
    }
}
