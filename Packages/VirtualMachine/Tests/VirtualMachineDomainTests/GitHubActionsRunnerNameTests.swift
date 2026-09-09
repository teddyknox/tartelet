import VirtualMachineDomain
import XCTest

final class GitHubActionsRunnerNameTests: XCTestCase {
    func testVirtualMachineNameIsUsedWithoutConfiguredName() {
        XCTAssertEqual(
            GitHubActionsRunnerName.make(virtualMachineName: "daybreak-ios-base-1", configuredRunnerName: ""),
            "daybreak-ios-base-1"
        )
    }

    func testSlotIndexIsAppendedToConfiguredName() {
        XCTAssertEqual(
            GitHubActionsRunnerName.make(
                virtualMachineName: "daybreak-ios-base-2",
                configuredRunnerName: "daybreak-ios-tartelet-personal"
            ),
            "daybreak-ios-tartelet-personal 2"
        )
    }

    func testConfiguredNameIsUsedWhenThereIsNoIndex() {
        XCTAssertEqual(
            GitHubActionsRunnerName.make(virtualMachineName: "daybreak-ios-base", configuredRunnerName: "custom"),
            "custom"
        )
    }
}
