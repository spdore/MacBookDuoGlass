import AppKit
import CoreVideo

final class OverlayWindow: NSPanel {
    let renderer: DuoMetalView

    init?(screen: NSScreen) {
        let frame = screen.frame
        guard let renderer = DuoMetalView(duoFrame: CGRect(origin: .zero, size: frame.size)) else {
            return nil
        }
        self.renderer = renderer
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .stationary]
        contentView = renderer
        orderOut(nil)
    }

    func update(screen: NSScreen) {
        if frame != screen.frame {
            setFrame(screen.frame, display: false)
            renderer.frame = CGRect(origin: .zero, size: screen.frame.size)
        }
    }

    func updateFrame(_ pixelBuffer: CVPixelBuffer) {
        renderer.setFrame(pixelBuffer)
    }

    func updateEffect(_ state: EffectState) {
        renderer.setEffectState(state)
    }
}
