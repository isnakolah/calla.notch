import Foundation

enum QuizHostRunnerFailure: Error { case command(String) }

enum QuizHostRunner {
    static func run(executable: URL, arguments: [String], input: Data? = nil,
                    timeout: TimeInterval = 30, allowFailure: Bool = false) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let stdout = Pipe(); let stdin = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            process.standardInput = stdin
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler {
                if process.isRunning { process.terminate() }
            }
            do {
                try process.run()
                timer.resume()
                if let input { stdin.fileHandleForWriting.write(input) }
                try? stdin.fileHandleForWriting.close()
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timer.cancel()
                guard allowFailure || process.terminationStatus == 0 else {
                    throw QuizHostRunnerFailure.command("status \(process.terminationStatus)")
                }
                guard !data.isEmpty else { throw QuizHostRunnerFailure.command("empty reply") }
                return data
            } catch {
                if process.isRunning { process.terminate() }
                timer.cancel()
                throw error
            }
        }.value
    }
}
