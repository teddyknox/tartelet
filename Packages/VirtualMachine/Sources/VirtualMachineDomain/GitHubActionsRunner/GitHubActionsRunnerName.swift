public enum GitHubActionsRunnerName {
    /// The name under which the runner inside the virtual machine registers with GitHub.
    ///
    /// Without a configured runner name the virtual machine's name is used as-is. With one, the
    /// index suffix of fleet clones such as `base-2` is appended, e.g. `my runner 2`, so that each
    /// slot keeps a stable, distinct name across cycles. This is what the host watchdog matches on.
    public static func make(virtualMachineName: String, configuredRunnerName: String) -> String {
        // If no custom runner name is configured, use the VM name as-is
        if configuredRunnerName.isEmpty {
            return virtualMachineName
        }

        // Extract the index suffix from VM names like "baseVM-1", "baseVM-2"
        if let lastDashIndex = virtualMachineName.lastIndex(of: "-") {
            let indexString = String(virtualMachineName[virtualMachineName.index(after: lastDashIndex)...])
            if !indexString.isEmpty, Int(indexString) != nil {
                return "\(configuredRunnerName) \(indexString)"
            }
        }
        // Fallback to just the runner name if we can't extract an index
        return configuredRunnerName
    }
}
