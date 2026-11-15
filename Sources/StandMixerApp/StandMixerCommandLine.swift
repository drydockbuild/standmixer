import AppKit
import StandMixerCore
import Foundation

enum StandMixerCommandLine {
    static func runIfRequested() -> Int32? {
        let arguments = CommandLine.arguments
        guard arguments.dropFirst().first == "--standmixer" else { return nil }
        let semaphore = DispatchSemaphore(value: 0)
        var response: StandMixerCommandResponse?
        let service = IntegrationService(executableURL: Bundle.main.executableURL)
        Task.detached {
            if arguments.dropFirst(2).first == "run-claude" {
                let code = await StandMixerClaudeWorker.run(arguments: Array(arguments.dropFirst(3)), service: service)
                response = .init("", exitCode: code)
            } else {
                response = await StandMixerCommandHost.run(arguments: Array(arguments.dropFirst(2)), service: service)
            }
            semaphore.signal()
        }
        semaphore.wait()
        guard let response else { return 1 }
        if !response.text.isEmpty { print(response.text) }
        if response.openSettings {
            let bundle = Bundle.main.bundleURL
            guard bundle.pathExtension == "app" else {
                fputs("Run the installed StandMixer.app to open settings.\n", stderr)
                return 1
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = [bundle.path]
            do { try process.run(); process.waitUntilExit(); return process.terminationStatus }
            catch { fputs("Could not open StandMixer: \(error.localizedDescription)\n", stderr); return 1 }
        }
        return response.exitCode
    }
}
