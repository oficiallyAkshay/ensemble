/// What the nose dot shows. While a pinch-drag is scrolling the dot becomes the scroll symbol, and it turns back
/// the moment the pinch releases, so a fling that is still coasting no longer counts.
public enum DotGlyph {
    /// `scrollActive` is the scroll controller's own state (a drag is in progress); the pinch must also still be held,
    /// because the controller keeps the drag for up to 0.6 s after the last movement.
    public static func showsScroll(scrollActive: Bool, pinchHeld: Bool) -> Bool {
        scrollActive && pinchHeld
    }
}
