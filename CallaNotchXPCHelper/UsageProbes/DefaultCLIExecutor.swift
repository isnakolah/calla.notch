import Foundation

/// Default CLIExecutor that uses BinaryLocator and InteractiveRunner.
struct DefaultCLIExecutor: CLIExecutor {
    /// Environment variable keys to exclude from the subprocess environment.
    private let environmentExclusions: [String]
    private let environmentOverrides: [String: String]

    init(environmentExclusions: [String] = [], environmentOverrides: [String: String] = [:]) {
        self.environmentExclusions = environmentExclusions
        self.environmentOverrides = environmentOverrides
    }

    func locate(_ binary: String) -> String? {
        BinaryLocator.which(binary)
    }

    func execute(
        binary: String,
        args: [String],
        input: String?,
        timeout: TimeInterval,
        workingDirectory: URL?,
        autoResponses: [String: String],
        completionMarkers: [String]
    ) throws -> CLIResult {
        let runner = InteractiveRunner()
        let options = InteractiveRunner.Options(
            timeout: timeout,
            workingDirectory: workingDirectory,
            arguments: args,
            autoResponses: autoResponses,
            environmentExclusions: environmentExclusions,
            environmentOverrides: environmentOverrides,
            completionMarkers: completionMarkers
        )

        let result = try runner.run(binary: binary, input: input ?? "", options: options)
        return CLIResult(output: result.output, exitCode: result.exitCode)
    }
}
