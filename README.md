![Hero artwork](artwork.jpg)

## 👋 Welcome to Tartelet - a macOS app that launches self-hosted GitHub Actions runners in virtual machines using [Tart](https://github.com/cirruslabs/tart).

Tartelet makes it a breeze to manage up to two GitHub Actions runners in ephemeral virtual machines on a single host machine. The benefits are that runners can run in parallel and each job runs in an isolated environment that is recreated after each GitHub Actions job has finished.

- [🚀 Getting Started](https://github.com/shapehq/tartelet#-getting-started)
- [👨‍🔧 How does it work?](https://github.com/shapehq/tartelet#-how-does-it-work)
- [🏎 How is the performance?](https://github.com/shapehq/tartelet#-how-is-the-performance)
- [👩‍💻 How can I contribute?](https://github.com/shapehq/tartelet#-how-can-i-contribute)
- [🤨 Why is it named Tartelet?](https://github.com/shapehq/tartelet#-why-is-it-named-tartelet)
- [🙏 Acknowledgements](https://github.com/shapehq/tartelet#-acknowledgements)

## 🚀 Getting Started

Please refer to the following articles in [the wiki](https://github.com/shapehq/tartelet/wiki) to get started with Tartelet.

- [Installing Tartelet](https://github.com/shapehq/tartelet/wiki/Installing-Tartelet)
- [Configuring Tartelet](https://github.com/shapehq/tartelet/wiki/Configuring-Tartelet)
- [Starting the Virtual Machines](https://github.com/shapehq/tartelet/wiki/Starting-the-Virtual-Machines)

## 👨‍🔧 How does it work?

![Screenshot of Tartelet running two virtual machines](screenshot.jpg)

Tartelet uses Tart for managing the virtual machines and Tart which in turn uses Apple's [Apple's Virtualization framework](https://developer.apple.com/documentation/virtualization). The lifecycle of a GitHub Actions runner managed by Tartelet is as follows:

1. Tartelet uses Tart to clone a virtual machine.
2. The virtual machine is booted.
3. After the machine is booted, a setup script is being run. The script downloads the newest version of [GitHub's runner application](https://docs.github.com/en/actions/hosting-your-own-runners/adding-self-hosted-runners) and registers the runner on the GitHub organization.
4. The runner listens for a job and executes it.
5. After executing the job, the runner automatically removes itself from the GitHub organization.
6. The virtual machine is shutdown.
7. Tartelet uses Tart to delete the virtual machine.

After the last step the process starts over.

## 🐕 Fleet watchdog

The lifecycle above assumes every virtual machine eventually powers itself off. In practice a guest can wedge: a job cancelled from GitHub can leave `xcodebuild` and the simulator running so `sudo shutdown -h now` never completes, or a fresh clone can boot without ever registering its runner. Without help from the host that slot is dead until someone kills processes by hand. This fork therefore watches every slot from the host and recycles it when it misses a deadline.

Each slot moves through an explicit state machine: `idle → cloning → booting → bootstrapped → registered → busy → draining → exited`. The host learns about `bootstrapped` from its own SSH bootstrap and about `registered`, `busy` and `draining` by polling GitHub's runner list (`GET /orgs/{org}/actions/runners` or `GET /repos/{owner}/{repo}/actions/runners`) with the app installation token, matching the exact runner name of the slot. Deadlines are enforced on the host:

| State | Deadline | Default | Environment variable |
| --- | --- | --- | --- |
| `booting` | the SSH bootstrap must complete | 5 min | `TARTELET_BOOT_TIMEOUT` |
| `bootstrapped` | the runner must appear online in GitHub's list | 5 min | `TARTELET_REGISTRATION_TIMEOUT` |
| `draining` | `tart run` must return after unregistering, going offline, or becoming idle after being busy | 3 min | `TARTELET_SHUTDOWN_TIMEOUT` |
| running clone, including idle or busy | hard cap measured from the start of cloning | 3 h | `TARTELET_MAX_LIFETIME` |

Two more knobs tune the cadence: `TARTELET_RUNNER_POLL_INTERVAL` (default 30 s) sets how often the runner list is polled, and `TARTELET_RETRY_DELAY` (default 10 s) is the pause after a failed cycle or an unsuccessful pre-clone identity request. All values are positive whole seconds; invalid environment values are ignored. Each variable falls back to a `UserDefaults` key with the same meaning (`bootTimeout`, `registrationTimeout`, `shutdownTimeout`, `maxLifetime`, `runnerPollInterval`, `retryDelay`) and then to the default. A failed API request does not supply evidence for the registration deadline. That deadline requires a successful request started at or after the registration timeout; a slow earlier request does not qualify. Boot, draining and lifetime deadlines continue during API outages. Before cloning, the slot requires a successful runner-list baseline so it can retire the old runner ID, including after an app restart. An API outage therefore postpones new cycles. Retired IDs remain ignored across failed replacements, and a new ID starts fresh busy/idle history. Runner-list pagination uses 100 runners per page in both scopes; a failure or a remaining next page after 50 pages makes the whole observation fail. Installation tokens are cached for 45 minutes and discarded on request failure.

**The 3-hour cap is a clone-age limit, not a job timeout.** It includes cloning, boot and idle time, and recycles an idle registered runner too. A job that starts at clone age 2 h 59 min can be interrupted roughly a minute later. Set the cap for the entire intended clone lifetime; it is enforced at watchdog polls while the VM is running. A previously online runner going offline enters `draining` even if no busy poll was observed. It can return to `registered` if it comes back idle and has never been observed busy; after being busy, repeated idle polls do not reset the draining deadline.

When a deadline trips the slot enters `recovering` and, in order:

1. fetches the tail of `~/start-runner.log` and a process snapshot from the guest over SSH (best effort, bounded) and writes them to the host log, so the guest-side cause is visible;
2. runs `tart stop <name>` with a short timeout, then interrupts and, if necessary, kills its own `tart run` process, then reaps an orphaned `tart run` or a Virtualization helper associated with this owned clone;
3. after run and recovery finish, verifies ownership and that no processes still hold the disk/config, runs `tart delete`, and removes the verified clone directory if it still exists (including missing `config.json`). A running-VM error, unknown disk holder, failed inspection, or unreaped process leaves the files intact;
4. clones again.

Cloning also cleans a **marked, owned** leftover slot, reaping its orphaned processes before removing the disk pathname. New clones are created under a unique `.tartelet-clone-<UUID>` staging name, marked with their source, slot, home and directory identity, then published without replacing an existing directory. A per-slot file lock prevents two Tartelet cycles from using the same name. Cleanup refuses base images, unmarked collisions, mismatched ownership, symlinks and shared disk/config inodes. It signals only the exact system Virtualization VM helper executable holding the owned files, or the configured Tart executable running this exact name in this exact `TART_HOME`. A settings change cannot redirect a running cycle's cleanup.

**Upgrade note:** clones left by an older version have no ownership marker. Stop and move or remove those known legacy clones manually before starting this fleet; Tartelet will report their paths and leave them intact. A crash during staging may leave an unpublished `.tartelet-clone-*` directory; it never starts as a VM or replaces a slot. A command that survives the SIGKILL wait keeps its slot lock until actual exit. It also records a `.tartelet-locks/*.quarantine` file: if the app exits first, a new launch refuses that slot until an operator verifies the recorded process has exited and removes the quarantine file. An unreaped clone remains under its unique staging name for inspection.

SSH bootstrap (including IP discovery, authentication, scripts and close) is bounded even if the SSH library ignores cancellation. Diagnostic reads have a 30-second outer bound, and connection close has a 5-second bound. Host commands use process handles and bounded SIGINT/SIGKILL waits: clone allows 10 minutes, stop 45 seconds, IP and each process lookup 15 seconds, and delete/ordinary commands 60 seconds, followed by up to 2 seconds after SIGINT and 5 seconds after SIGKILL. `tart run` cancellation allows 15 seconds after SIGINT and 10 after SIGKILL. Output is drained incrementally with a 1 MiB tail per stream; inherited open pipes are closed 3 seconds after the parent exits. These bounds do not require a task to remain uncancelled.

Stop Immediately keeps the fleet unavailable for restart until cleanup finishes. Ordinary Quit waits for that cleanup before taking the final process-registry snapshot. Forced termination of the app cannot await cleanup; the next launch recovers marked leftovers. Every state transition and deadline trip is logged with the slot and elapsed time. Unchanged runner observations are quiet; stale IDs are logged once per cycle, API failures at most once per five minutes per slot, and recovery from an API outage once. The menu bar lists each slot's current state.

Inside the guest, the runner script's `EXIT` trap now kills the runner's process tree and any simulator or `xcodebuild` a cancelled job left behind before requesting `sudo shutdown -h now`, and falls back to `sudo halt -q` if the shutdown has not completed within 90 seconds.

## 🏎 How is the performance?

The performance depends on the hardware that the app is running on. When testing on a Mac mini M1 from 2020 with 16 GB memory, we found that our jobs run 3 - 4 times faster than on GitHub's runners.

We found that our jobs run about 12% slower when running two virtual machines in parallel compared to running a single virtual machine. We find this performance cost negligible as running two virtual machines significantly increases our throughput at a low monetary cost.

This means that Tartelet can run two virtual machines at once. This the maximum number of virtual machines that Apple’s Virtualization framework allows us to run at once.

After a job has finished, the virtual machine that ran the job is shut down and destroyed, and a new virtual machine is created and booted. This process takes about 25 - 30 seconds. However, that overhead is insignificant in most cases as Tartelet creates a new virtual machine after each job has finished. This means that a new virtual machine and its GitHub Actions runner are ready to process the next job. Unless there are more jobs queued on GitHub than the number of available virtual machines, the overhead of creating and booting a virtual machine becomes negligible.

These numbers were last updated in January/February 2023.

## 👩‍💻 How can I contribute?

Pull requests with bugfixes and new features are much appreciated. We are happy to review PRs and merge them once they are ready, as long as they contain changes that fit within the vision of Tartelet.

Clone the repository to get started working on the project.

```bash
git clone git@github.com:shapehq/tartelet.git
```

### Generating a Project File with XcodeGen

After cloning the repository you will notice that the project does not contain a .xcodeproj file. This should be generated using [XcodeGen](https://github.com/yonaskolb/XcodeGen). Install XcodeGen using [Homebrew](https://brew.sh) by running the following command in your terminal.

```bash
brew install xcodegen
```

After installing XcodeGen the project file can be generated by running the following command.

```bash
xcodegen generate
```

### Generating Resource Constants with SwiftGen

We use [SwiftGen](https://github.com/SwiftGen/SwiftGen) to generate constants for images, colors, and localizations. Install SwiftGen using [Homebrew](https://brew.sh) by running the following command in your terminal.

```bash
brew install swiftgen
```

Constants for images, colors, and localizations are then generated by running the following command in your terminal.

```bash
swiftgen
```

The `swiftgen.yml` file at the root of the repository describes how constants are generated.

### Configuring the project to run on your machine

To run the project locally, it is necessary to edit the `Tartelet.entitlements` file to specify a keychain access group that you control. Then you will need to edit the `Composers.swift` file to ensure the keychain is initialized with the keychain access group specified in the entitlements file. If you do not do this, the app will not be able to persist settings to the keychain.

In other words, you will need to search for `$(AppIdentifierPrefix)dk.shape.Tartelet` and `566MC7D8D4.dk.shape.Tartelet` in the project and replace the occurrences with references to your keychain access group.

### Linting the Codebase with SwiftLint

We use [SwiftLint](https://github.com/realm/SwiftLint) to ensure uniformity in the code. Install SwiftLint using [Homebrew](https://brew.sh) by running the following command in your terminal.

```bash
brew install swiftlint
```

## 🤨 Why is it named Tartelet?

The app is named Tartelet because it builds upon [Tart](https://tart.run), a source-available CLI for managing macOS virtual machines. Tartelet makes it easy to run multiple virtual machines using Tart. The Danish word for "easy" is "let". "Tart" + "e" + "let" = "Tartelet" and [a "tartelet" is a traditional Danish food.](https://www.valdemarsro.dk/tarteletter-hoens-asparges/)

<img src="Tartelet/Assets.xcassets/AppIcon.appiconset/Artboard_512x512.png?raw=true" width="192" />

## 🙏 Acknowledgements

- [Tart](https://github.com/cirruslabs/tart) does all the heavy-lifting of creating, cloning, and running virtual machines.
- Tartelet is heavily inspired by [Cilicon](https://github.com/traderepublic/Cilicon).

---

Tartelet is built with ❤️ by [Shape](https://shape.dk) in Denmark. Oh, and [we are hiring](https://careers.shape.dk) 🤗
