public protocol SSHConnection {
    /// Runs the command, logging its output.
    func executeCommand(_ command: String) async throws
    /// Runs the command and returns its standard output instead of logging it.
    func executeCommandReturningOutput(_ command: String) async throws -> String
    func close() async throws
}
