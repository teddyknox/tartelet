/// Identity history is independent of registration/busy state. The owning slot serializes access
/// under its lock. Old IDs survive failed replacements, but never hide a newly observed ID.
struct FleetRunnerIdentity {
    struct Observation {
        var status: GitHubActionsRunnerStatus?
        var isFresh = false
        var newlyIgnoredID: Int?
    }

    private var retired: Set<Int> = []
    private var current: Int?
    private var logged: Set<Int> = []

    mutating func beginCycle(baselineID: Int?) {
        if let current { retired.insert(current) }
        if let baselineID { retired.insert(baselineID) }
        current = nil
        logged = []
    }

    mutating func observe(_ status: GitHubActionsRunnerStatus) -> Observation {
        guard let id = status.id else {
            return Observation(status: status)
        }
        if retired.contains(id) {
            return Observation(
                status: current == nil ? .unregistered : nil,
                newlyIgnoredID: logged.insert(id).inserted ? id : nil
            )
        }
        if current != id {
            if let current { retired.insert(current) }
            current = id
            return Observation(status: status, isFresh: true)
        }
        return Observation(status: status)
    }
}
