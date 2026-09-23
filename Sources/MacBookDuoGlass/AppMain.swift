import AppKit
import Darwin

@main
struct MacBookDuoGlassMain {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            exit(SelfTest.run())
        }
        let application = NSApplication.shared
        let delegate = AppCoordinator()
        application.delegate = delegate
        application.run()
    }
}
