import Foundation
import GitHubDomain
import LoggingDomain
import SSHDomain

private enum GitHubActionsRunnerSSHConnectionHandlerError: LocalizedError {
    case organizationNameUnavailable
    case invalidRunnerURL

    var errorDescription: String? {
        switch self {
        case .organizationNameUnavailable:
            return "The organization name is unavailable"
        case .invalidRunnerURL:
            return "The runner URL is invalid. Ensure the organization name is correct"
        }
    }
}

public struct GitHubActionsRunnerSSHConnectionHandler: VirtualMachineSSHConnectionHandler {
    private let logger: Logger
    private let client: GitHubClient
    private let credentialsStore: GitHubCredentialsStore
    private let configuration: GitHubActionsRunnerConfiguration

    public init(
        logger: Logger,
        client: GitHubClient,
        credentialsStore: GitHubCredentialsStore,
        configuration: GitHubActionsRunnerConfiguration
    ) {
        self.logger = logger
        self.client = client
        self.credentialsStore = credentialsStore
        self.configuration = configuration
    }

    // swiftlint:disable:next function_body_length
    public func didConnect(to virtualMachine: VirtualMachine, through connection: SSHConnection) async throws {
        let runnerURL = try await getRunnerURL()
        let appAccessToken = try await client.getAppAccessToken(runnerScope: configuration.runnerScope)
        let runnerToken = try await client.getRunnerRegistrationToken(
            with: appAccessToken,
            runnerScope: configuration.runnerScope
        )
        let runnerDownloadURL = try await client.getRunnerDownloadURL(
            with: appAccessToken,
            runnerScope: configuration.runnerScope
        )
        let startRunnerScriptFilePath = "~/start-runner.sh"
        try await connection.executeCommand("touch \(startRunnerScriptFilePath)")
        try await connection.executeCommand("""
cat > \(startRunnerScriptFilePath) << EOF
#!/bin/zsh
ACTIONS_RUNNER_ARCHIVE=./actions-runner.tar.gz
ACTIONS_RUNNER_DIRECTORY=~/actions-runner

# Ensure the virtual machine is restarted when a job is done, even when a
# cancelled job leaves processes behind that would block a clean shutdown.
set -e pipefail
function log_exit {
  echo "[start-runner] \\$(date '+%H:%M:%S') \\$1"
}
function kill_tree {
  local child
  for child in \\$(pgrep -P "\\$1"); do
    kill_tree "\\$child"
  done
  if [ "\\$1" != "\\$\\$" ]; then
    kill -9 "\\$1" 2>/dev/null || true
  fi
}
function onexit {
  set +e
  log_exit "runner exited; cleaning up before shutdown"
  # Kill whatever the runner left behind: its own process tree first, then
  # anything a cancelled job may have orphaned (xcodebuild, simulators).
  kill_tree \\$\\$
  pkill -9 -f "Runner.Listener|Runner.Worker|xcodebuild|Simulator.app|launchd_sim|CoreSimulatorService" 2>/dev/null
  log_exit "requesting shutdown"
  sudo shutdown -h now >/dev/null 2>&1 &
  # A shutdown blocked by an app that refuses to quit leaves the guest running
  # forever; halt without ceremony if it has not completed in time.
  sleep 90
  log_exit "shutdown did not complete within 90s; halting"
  sudo halt -q
}
trap onexit EXIT

# Wait until we can connect to GitHub.
until curl -Is https://github.com &>/dev/null; do :; done

# Download the runner if the runner directory and
# archive does not already exist.
if [ ! -d \\$ACTIONS_RUNNER_DIRECTORY ]; then
  if [ ! -f \\$ACTIONS_RUNNER_ARCHIVE ]; then
    curl -o \\$ACTIONS_RUNNER_ARCHIVE -L "\(runnerDownloadURL)"
    # Unarchive the runner.
    mkdir -p \\$ACTIONS_RUNNER_DIRECTORY
    tar xzf \\$ACTIONS_RUNNER_ARCHIVE --directory \\$ACTIONS_RUNNER_DIRECTORY
  fi
fi

# Holds environment passed to runner.
RUNNER_ENV=""

# Configure pre-run script.
PRE_RUN_SCRIPT_PATH="\\$HOME/.tartelet/pre-run.sh"
if [ -f "\\$PRE_RUN_SCRIPT_PATH" ]; then
  RUNNER_ENV="\\${RUNNER_ENV}ACTIONS_RUNNER_HOOK_JOB_STARTED=\\${PRE_RUN_SCRIPT_PATH}\n"
fi

# Configure post-run script.
POST_RUN_SCRIPT_PATH="\\$HOME/.tartelet/post-run.sh"
if [ -f "\\$POST_RUN_SCRIPT_PATH" ]; then
  RUNNER_ENV="\\${RUNNER_ENV}ACTIONS_RUNNER_HOOK_JOB_COMPLETED=\\${POST_RUN_SCRIPT_PATH}\n"
fi

# Create .env file in runner's diectory.
if [ "\\$RUNNER_ENV" != "" ]; then
  echo \\$RUNNER_ENV >> \\$ACTIONS_RUNNER_DIRECTORY/.env
fi

# Configure and run the runner.
cd \\$ACTIONS_RUNNER_DIRECTORY
./config.sh\\\\
  --url "\(runnerURL)"\\\\
  --unattended\\\\
  --ephemeral\\\\
  --replace\\\\
  --labels "\(configuration.runnerLabels)"\\\\
  --name "\(runnerName(for: virtualMachine))"\\\\
  --runnergroup "\(configuration.runnerGroup)"\\\\
  --work "_work"\\\\
  --token "\(runnerToken.rawValue)"\\\\
  \(configuration.runnerDisableUpdates ? "--disableupdate" : "")\\\\
  \(configuration.runnerDisableDefaultLabels ? "--no-default-labels" : "")
./run.sh
EOF
""")
        try await connection.executeCommand("chmod +x \(startRunnerScriptFilePath)")
        try await connection.executeCommand("""
nohup \(startRunnerScriptFilePath) > ~/start-runner.log 2>&1 < /dev/null &
""")
    }
    private func runnerName(for virtualMachine: VirtualMachine) -> String {
        GitHubActionsRunnerName.make(
            virtualMachineName: virtualMachine.name,
            configuredRunnerName: configuration.runnerName
        )
    }
}

private extension GitHubActionsRunnerSSHConnectionHandler {
    private func getRunnerURL() async throws -> URL {
        switch configuration.runnerScope {
        case .organization:
            let organizationName = try await getOrganizationName()
            guard let runnerURL = URL(string: "https://github.com/" + organizationName) else {
                logger.info("Invalid runner URL for organization with name \(organizationName)")
                throw GitHubActionsRunnerSSHConnectionHandlerError.invalidRunnerURL
            }
            return runnerURL
        case .repo:
            guard
                let ownerName = credentialsStore.ownerName,
                let repositoryName = credentialsStore.repositoryName,
                let runnerURL = URL(string: "https://github.com/\(ownerName)/\(repositoryName)")
            else {
                logger.info("Invalid runner URL for repository")
                throw GitHubActionsRunnerSSHConnectionHandlerError.invalidRunnerURL
            }
            return runnerURL
        }
    }

    private func getOrganizationName() async throws -> String {
        guard let organizationName = credentialsStore.organizationName else {
            logger.info("The GitHub organization name is not available")
            throw GitHubActionsRunnerSSHConnectionHandlerError.organizationNameUnavailable
        }
        return organizationName
    }
}
