import Foundation

/// Deadlines the host enforces on every fleet slot, plus the cadence of the watchdog.
///
/// All values are read from `TARTELET_*` environment variables (seconds) with a `UserDefaults`
/// fallback, in the same style as the fork's other unattended configuration.
public struct FleetSlotPolicy: Equatable, Sendable {
    /// Time from `tart run` starting until the SSH bootstrap has completed.
    public var bootTimeout: Duration
    /// Time from the bootstrap completing until GitHub lists the runner online.
    public var registrationTimeout: Duration
    /// Time in draining: after unregistering, going offline, or becoming idle after being busy.
    public var shutdownTimeout: Duration
    /// Elapsed time since cloning began. Recycles only registered, freshly observed idle
    /// runners; busy guests are never subject to the lifetime cap.
    public var maximumLifetime: Duration
    /// How often the runner list is polled and deadlines are evaluated.
    public var pollInterval: Duration
    /// Pause after a failed cycle or identity-baseline request before trying again.
    public var retryDelay: Duration

    public init(
        bootTimeout: Duration,
        registrationTimeout: Duration,
        shutdownTimeout: Duration,
        maximumLifetime: Duration,
        pollInterval: Duration,
        retryDelay: Duration
    ) {
        self.bootTimeout = bootTimeout
        self.registrationTimeout = registrationTimeout
        self.shutdownTimeout = shutdownTimeout
        self.maximumLifetime = maximumLifetime
        self.pollInterval = pollInterval
        self.retryDelay = retryDelay
    }

    public static let `default` = Self(
        bootTimeout: .seconds(5 * 60),
        registrationTimeout: .seconds(5 * 60),
        shutdownTimeout: .seconds(3 * 60),
        maximumLifetime: .seconds(3 * 60 * 60),
        pollInterval: .seconds(30),
        retryDelay: .seconds(10)
    )

    public enum Setting: CaseIterable {
        case bootTimeout
        case registrationTimeout
        case shutdownTimeout
        case maximumLifetime
        case pollInterval
        case retryDelay

        public var environmentVariable: String {
            switch self {
            case .bootTimeout:
                "TARTELET_BOOT_TIMEOUT"
            case .registrationTimeout:
                "TARTELET_REGISTRATION_TIMEOUT"
            case .shutdownTimeout:
                "TARTELET_SHUTDOWN_TIMEOUT"
            case .maximumLifetime:
                "TARTELET_MAX_LIFETIME"
            case .pollInterval:
                "TARTELET_RUNNER_POLL_INTERVAL"
            case .retryDelay:
                "TARTELET_RETRY_DELAY"
            }
        }

        public var userDefaultsKey: String {
            switch self {
            case .bootTimeout:
                "bootTimeout"
            case .registrationTimeout:
                "registrationTimeout"
            case .shutdownTimeout:
                "shutdownTimeout"
            case .maximumLifetime:
                "maxLifetime"
            case .pollInterval:
                "runnerPollInterval"
            case .retryDelay:
                "retryDelay"
            }
        }
    }

    /// Builds a policy from `TARTELET_*` environment variables, falling back to `UserDefaults` and
    /// then to ``default``. Values are whole seconds; anything that is not a positive integer is ignored.
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = .standard
    ) -> Self {
        var policy = Self.default
        for setting in Setting.allCases {
            let environmentValue = environment[setting.environmentVariable].flatMap(Int.init).flatMap(positive)
            let settingsValue = positive(userDefaults.integer(forKey: setting.userDefaultsKey))
            guard let value = environmentValue ?? settingsValue else {
                continue
            }
            policy[setting] = .seconds(value)
        }
        return policy
    }

    private static func positive(_ value: Int) -> Int? {
        value > 0 ? value : nil
    }

    public subscript(setting: Setting) -> Duration {
        get {
            switch setting {
            case .bootTimeout:
                bootTimeout
            case .registrationTimeout:
                registrationTimeout
            case .shutdownTimeout:
                shutdownTimeout
            case .maximumLifetime:
                maximumLifetime
            case .pollInterval:
                pollInterval
            case .retryDelay:
                retryDelay
            }
        }
        set {
            switch setting {
            case .bootTimeout:
                bootTimeout = newValue
            case .registrationTimeout:
                registrationTimeout = newValue
            case .shutdownTimeout:
                shutdownTimeout = newValue
            case .maximumLifetime:
                maximumLifetime = newValue
            case .pollInterval:
                pollInterval = newValue
            case .retryDelay:
                retryDelay = newValue
            }
        }
    }
}
