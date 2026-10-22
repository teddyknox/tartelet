import Foundation
@testable import VirtualMachineDomain
import XCTest

final class FleetSlotPolicyTests: XCTestCase {
    private let userDefaults = UserDefaults(suiteName: "FleetSlotPolicyTests") ?? .standard

    override func setUp() {
        super.setUp()
        userDefaults.removePersistentDomain(forName: "FleetSlotPolicyTests")
    }

    func testLifetimeOnlyAppliesToRegisteredWithFreshIdleObservation() {
        let now = FleetInstant(date: Date(), uptime: 50_000)
        let states: [FleetSlotState] = [
            .idle, .cloning, .booting, .bootstrapped, .registered, .busy, .draining, .recovering, .exited
        ]
        for state in states {
            let context = FleetSlotRules.DeadlineContext(
                state: state, stateEnteredAt: now, cycleStartedAt: now.earlier(by: 20_000),
                bootstrappedAt: now, lastObservation: (.online(id: 1, isBusy: false), now),
                runnerName: "runner", policy: .default, now: now
            )
            XCTAssertEqual(FleetSlotRules.deadline(in: context)?.trip, state == .registered ? .lifetimeExceeded : nil)
        }
        let stale = FleetSlotRules.DeadlineContext(
            state: .registered, stateEnteredAt: now, cycleStartedAt: now.earlier(by: 20_000),
            bootstrappedAt: now, lastObservation: (.online(id: 1, isBusy: false), now.earlier(by: 30)),
            runnerName: "runner", policy: .default, now: now
        )
        XCTAssertNil(FleetSlotRules.deadline(in: stale), "an API outage cannot authorize an idle recycle")
        // A clone that has existed for 20 000 s of wall time but only 10 000 s of awake time is
        // under the cap: the host's sleep is not the guest's age.
        let slept = FleetSlotRules.DeadlineContext(
            state: .registered, stateEnteredAt: now,
            cycleStartedAt: FleetInstant(date: now.date.addingTimeInterval(-20_000), uptime: now.uptime - 10_000),
            bootstrappedAt: now, lastObservation: (.online(id: 1, isBusy: false), now),
            runnerName: "runner", policy: .default, now: now
        )
        XCTAssertNil(FleetSlotRules.deadline(in: slept), "host sleep does not age a clone")
    }

    func testDefaults() {
        let policy = FleetSlotPolicy.fromEnvironment([:], userDefaults: userDefaults)

        XCTAssertEqual(policy, .default)
        XCTAssertEqual(policy.bootTimeout, .seconds(300))
        XCTAssertEqual(policy.registrationTimeout, .seconds(300))
        XCTAssertEqual(policy.shutdownTimeout, .seconds(180))
        XCTAssertEqual(policy.maximumLifetime, .seconds(10_800))
        XCTAssertEqual(policy.pollInterval, .seconds(30))
        XCTAssertEqual(policy.retryDelay, .seconds(10))
    }

    func testEnvironmentVariablesOverrideDefaults() {
        let policy = FleetSlotPolicy.fromEnvironment(
            [
                "TARTELET_BOOT_TIMEOUT": "120",
                "TARTELET_REGISTRATION_TIMEOUT": "240",
                "TARTELET_SHUTDOWN_TIMEOUT": "90",
                "TARTELET_MAX_LIFETIME": "7200",
                "TARTELET_RUNNER_POLL_INTERVAL": "15",
                "TARTELET_RETRY_DELAY": "5"
            ],
            userDefaults: userDefaults
        )

        XCTAssertEqual(policy.bootTimeout, .seconds(120))
        XCTAssertEqual(policy.registrationTimeout, .seconds(240))
        XCTAssertEqual(policy.shutdownTimeout, .seconds(90))
        XCTAssertEqual(policy.maximumLifetime, .seconds(7_200))
        XCTAssertEqual(policy.pollInterval, .seconds(15))
        XCTAssertEqual(policy.retryDelay, .seconds(5))
    }

    func testUserDefaultsAreUsedWhenEnvironmentIsUnset() {
        userDefaults.set(600, forKey: "shutdownTimeout")

        let policy = FleetSlotPolicy.fromEnvironment(
            ["TARTELET_BOOT_TIMEOUT": "60"],
            userDefaults: userDefaults
        )

        XCTAssertEqual(policy.bootTimeout, .seconds(60))
        XCTAssertEqual(policy.shutdownTimeout, .seconds(600))
        XCTAssertEqual(policy.registrationTimeout, FleetSlotPolicy.default.registrationTimeout)
    }

    func testInvalidValuesAreIgnored() {
        let policy = FleetSlotPolicy.fromEnvironment(
            [
                "TARTELET_BOOT_TIMEOUT": "soon",
                "TARTELET_SHUTDOWN_TIMEOUT": "0",
                "TARTELET_MAX_LIFETIME": "-5"
            ],
            userDefaults: userDefaults
        )

        XCTAssertEqual(policy, .default)
    }

    func testInvalidEnvironmentFallsBackToValidUserDefault() {
        userDefaults.set(600, forKey: "shutdownTimeout")
        for value in ["0", "-5", "invalid"] {
            let policy = FleetSlotPolicy.fromEnvironment(
                ["TARTELET_SHUTDOWN_TIMEOUT": value], userDefaults: userDefaults
            )
            XCTAssertEqual(policy.shutdownTimeout, .seconds(600))
        }
    }
}

private extension FleetInstant {
    /// The same clock `seconds` earlier, awake the whole time.
    func earlier(by seconds: TimeInterval) -> FleetInstant {
        FleetInstant(date: date.addingTimeInterval(-seconds), uptime: uptime - seconds)
    }
}
