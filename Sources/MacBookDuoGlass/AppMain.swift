import AppKit
import Darwin

@main
struct MacBookDuoGlassMain {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            exit(SelfTest.run())
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--render-preview") {
            exit(PreviewRender.run(arguments: Array(CommandLine.arguments[(flag + 1)...])))
        }
        let application = NSApplication.shared
        let delegate = AppCoordinator()
        application.delegate = delegate
        application.run()
    }
}
