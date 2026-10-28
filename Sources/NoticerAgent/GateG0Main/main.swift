import Foundation
import NoticerAgent

@main
struct NoticerGateG0Main {
    static func main() async {
        let code = await GateG0.run(
            arguments: CommandLine.arguments,
            environment: ProcessInfo.processInfo.environment
        )
        exit(code)
    }
}
