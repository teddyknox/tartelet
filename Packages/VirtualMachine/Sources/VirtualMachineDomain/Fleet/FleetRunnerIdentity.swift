/// The guest's post-configure agentId is authoritative, including when --replace reuses an id.
/// The owning slot serializes access under its lock.
struct FleetRunnerIdentity {
    struct Observation {
        var status: GitHubActionsRunnerStatus?
        var isFresh = false
        var newlyIgnoredID: Int?
    }

    private(set) var current: Int?
    private var observed = false
    private var logged: Set<Int> = []

    mutating func beginCycle() {
        current = nil
        observed = false
        logged = []
    }

    mutating func report(id: Int) {
        current = id
    }

    mutating func observe(_ status: GitHubActionsRunnerStatus) -> Observation {
        guard let id = status.id else {
            return Observation(status: status)
        }
        guard id == current else {
            return Observation(
                status: observed ? nil : .unregistered,
                newlyIgnoredID: logged.insert(id).inserted ? id : nil
            )
        }
        let fresh = !observed
        observed = true
        return Observation(status: status, isFresh: fresh)
    }
}
