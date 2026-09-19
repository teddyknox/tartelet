import FileSystemData
import Foundation
import GitHubData
import GitHubDomain
import Keychain
import LoggingData
import LoggingDomain
import NetworkingData
import Observation
import SettingsData
import ShellData
import SSHData
import VirtualMachineData
import VirtualMachineDomain

@MainActor
enum Composers {
    static let settingsStore = AppStorageSettingsStore()

    static let processRegistry = ProcessRegistry()
    static let fleetPolicy = FleetSlotPolicy.fromEnvironment()

    static let fleet = VirtualMachineFleet(
        logger: logger(subsystem: "VirtualMachineFleet"),
        baseVirtualMachine: SSHConnectingVirtualMachine(
            logger: logger(subsystem: "SSHConnectingVirtualMachine"),
            virtualMachine: SettingsVirtualMachine(
                tart: Tart(
                    homeProvider: SettingsTartHomeProvider(
                        settingsStore: settingsStore
                    ),
                    shell: ProcessShell(processRegistry: processRegistry),
                    logger: logger(subsystem: "Tart")
                ),
                settingsStore: settingsStore
            ),
            sshClient: virtualMachineSSHClient,
            bootstrapTimeout: fleetPolicy.bootTimeout
        ),
        runnerRegistry: GitHubClientActionsRunnerRegistry(
            // The slot reports and throttles polling failures. Avoid a second transport log
            // on every poll; bootstrap requests retain the ordinary client's diagnostics.
            client: NetworkingGitHubClient(
                credentialsStore: gitHubCredentialsStore,
                networkingService: URLSessionNetworkingService(
                    logger: logger(subsystem: "RunnerRegistryNetworking"),
                    logsFailures: false
                )
            ),
            configuration: gitHubActionsRunnerConfiguration
        ),
        runnerConfiguration: gitHubActionsRunnerConfiguration,
        identityReader: SSHGuestRunnerIdentityReader(sshClient: virtualMachineSSHClient),
        guestLogReader: SSHVirtualMachineGuestLogReader(
            sshClient: virtualMachineSSHClient
        ),
        policy: fleetPolicy
    )

    static let editor = VirtualMachineEditor(
        logger: logger(subsystem: "VirtualMachineEditor"),
        virtualMachine: SettingsVirtualMachine(
            tart: Tart(
                homeProvider: SettingsTartHomeProvider(
                    settingsStore: settingsStore
                ),
                shell: ProcessShell(processRegistry: processRegistry),
                logger: logger(subsystem: "Tart")
            ),
            settingsStore: settingsStore
        )
    )

    static let gitHubCredentialsStore = KeychainGitHubCredentialsStore(
        keychain: keychain(
            logger: logger(subsystem: "GitHubCredentialsStore")
        ),
        serviceName: "Tartelet GitHub Account"
    )

    static let virtualMachineSSHCredentialsStore = KeychainVirtualMachineSSHCredentialsStore(
        keychain: keychain(
            logger: logger(subsystem: "KeychainVirtualMachineSSHCredentialsStore")
        ),
        serviceName: "Tartelet Virtual Machine SSH Credentials"
    )

    static let gitHubClient = NetworkingGitHubClient(
        credentialsStore: gitHubCredentialsStore,
        networkingService: URLSessionNetworkingService(
            logger: logger(subsystem: "URLSessionNetworkingService")
        )
    )

    static let gitHubActionsRunnerConfiguration = SettingsGitHubActionsRunnerConfiguration(
        settingsStore: settingsStore
    )

    static let virtualMachineSSHClient = VirtualMachineSSHClient(
        logger: logger(subsystem: "VirtualMachineSSHClient"),
        client: CitadelSSHClient(
            logger: logger(subsystem: "CitadelSSHClient")
        ),
        ipAddressReader: RetryingVirtualMachineIPAddressReader(),
        credentialsStore: virtualMachineSSHCredentialsStore,
        connectionHandler: CompositeVirtualMachineSSHConnectionHandler([
            PostBootScriptSSHConnectionHandler(),
            GitHubActionsRunnerSSHConnectionHandler(
                logger: logger(subsystem: "GitHubActionsRunnerSSHConnectionHandler"),
                client: gitHubClient,
                credentialsStore: gitHubCredentialsStore,
                configuration: gitHubActionsRunnerConfiguration
            )
        ])
    )

    static func logger(subsystem: String) -> Logger {
        FileLogger(
            fileSystem: DiskFileSystem(),
            dateProvider: FoundationDateProvider(),
            subsystem: subsystem,
            // Preserve fleet incident evidence across app upgrades and relaunches.
            daysOfRetention: nil
        )
    }
}

private extension Composers {
    private static func keychain(logger: Logger) -> Keychain {
        let environment = ProcessInfo.processInfo.environment
        let shouldDisableAccessGroup = environment["TARTELET_DISABLE_KEYCHAIN_ACCESS_GROUP"] == "1"
            || UserDefaults.standard.bool(forKey: "disableKeychainAccessGroup")
        let accessGroup = shouldDisableAccessGroup ? nil : "566MC7D8D4.dk.shape.Tartelet"
        return Keychain(logger: logger, accessGroup: accessGroup)
    }
}
