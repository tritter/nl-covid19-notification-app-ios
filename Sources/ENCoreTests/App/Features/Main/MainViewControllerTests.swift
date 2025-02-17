/*
 * Copyright (c) 2020 De Staat der Nederlanden, Ministerie van Volksgezondheid, Welzijn en Sport.
 *  Licensed under the EUROPEAN UNION PUBLIC LICENCE v. 1.2
 *
 *  SPDX-License-Identifier: EUPL-1.2
 */

@testable import ENCore
import Foundation
import SnapshotTesting
import XCTest

final class MainViewControllerTests: TestCase {
    private var viewController: MainViewController!
    private let router = MainRoutingMock()
    private let statusBuilder = StatusBuildableMock()
    private let moreInformationBuilder = MoreInformationBuildableMock()
    private let exposureController = ExposureControllingMock()
    private let exposureStateStream = ExposureStateStreamingMock()
    private var mockPauseController = PauseControllingMock()
    private var mockUserNotificationController = UserNotificationControllingMock()
    private let alertControllerBuilder = AlertControllerBuildableMock()

    override func setUp() {
        super.setUp()

        recordSnapshots = false || forceRecordAllSnapshots

        viewController = MainViewController(theme: theme,
                                            exposureController: exposureController,
                                            exposureStateStream: exposureStateStream,
                                            userNotificationController: mockUserNotificationController,
                                            pauseController: mockPauseController,
                                            alertControllerBuilder: alertControllerBuilder)
        viewController.router = router
    }

    // MARK: - MoreInformationListener

    func test_moreInformationRequestsAbout_callsRouter() {
        XCTAssertEqual(router.routeToAboutAppCallCount, 0)

        viewController.moreInformationRequestsAbout()

        XCTAssertEqual(router.routeToAboutAppCallCount, 1)
    }

    func test_moreInformationRequestsSettings_callsRouter() {
        XCTAssertEqual(router.routeToSettingsCallCount, 0)

        viewController.moreInformationRequestsSettings()

        XCTAssertEqual(router.routeToSettingsCallCount, 1)
    }

    func test_moreInformationRequestsSharing_callsRouter() {
        XCTAssertEqual(router.routeToSharingCallCount, 0)

        viewController.moreInformationRequestsSharing()

        XCTAssertEqual(router.routeToSharingCallCount, 1)
    }

    func test_moreInformationRequestsReceivedNotification_callsRouter() {
        XCTAssertEqual(router.routeToReceivedNotificationCallCount, 0)

        viewController.moreInformationRequestsReceivedNotification()

        XCTAssertEqual(router.routeToReceivedNotificationCallCount, 1)
    }

    func test_moreInformationRequestsKeySharing_callsRouter() {
        XCTAssertEqual(router.routeToKeySharingCallCount, 0)

        viewController.moreInformationRequestsKeySharing()

        XCTAssertEqual(router.routeToKeySharingCallCount, 1)
    }

    func test_moreInformationRequestsRequestTest_callsRouter() {
        XCTAssertEqual(router.routeToRequestTestCallCount, 0)

        viewController.moreInformationRequestsRequestTest()

        XCTAssertEqual(router.routeToRequestTestCallCount, 1)
    }

    func test_webviewRequestsDismissal_callsRouter() {
        XCTAssertEqual(router.detachWebviewCallCount, 0)

        viewController.webviewRequestsDismissal(shouldHideViewController: true)

        XCTAssertEqual(router.detachWebviewCallCount, 1)
    }

    func test_aboutRequestsDismissal_callsRouter() {
        XCTAssertEqual(router.detachAboutAppCallCount, 0)

        viewController.aboutRequestsDismissal(shouldHideViewController: true)

        XCTAssertEqual(router.detachAboutAppCallCount, 1)
    }

    func test_settingsWantsDismissal_callsRouter() {
        XCTAssertEqual(router.detachSettingsCallCount, 0)

        viewController.settingsWantsDismissal(shouldDismissViewController: true)

        XCTAssertEqual(router.detachSettingsCallCount, 1)
    }

    func test_shareSheetDidComplete_callsRouter() {
        XCTAssertEqual(router.detachSharingCallCount, 0)

        viewController.shareSheetDidComplete(shouldHideViewController: true)

        XCTAssertEqual(router.detachSharingCallCount, 1)
    }

    func test_displayShareSheet_callsRouter() {
        viewController.displayShareSheet(usingViewController: viewController) { completed in
            XCTAssertTrue(completed)
        }
    }

    func test_receivedNotificationWantsDismissal_callsRouter() {
        XCTAssertEqual(router.detachReceivedNotificationCallCount, 0)

        viewController.receivedNotificationWantsDismissal(shouldDismissViewController: true)

        XCTAssertEqual(router.detachReceivedNotificationCallCount, 1)
    }

    func test_requestTestWantsDismissal_callsRouter() {
        XCTAssertEqual(router.detachRequestTestCallCount, 0)

        viewController.requestTestWantsDismissal(shouldDismissViewController: true)

        XCTAssertEqual(router.detachRequestTestCallCount, 1)
    }

    func test_keySharingWantsDismissal_callsRouter() {
        XCTAssertEqual(router.detachKeySharingCallCount, 0)

        viewController.keySharingWantsDismissal(shouldDismissViewController: true)

        XCTAssertEqual(router.detachKeySharingCallCount, 1)
    }

    func test_messageWantsDismissal_callsRouter() {
        XCTAssertEqual(router.detachMessageCallCount, 0)

        viewController.messageWantsDismissal(shouldDismissViewController: true)

        XCTAssertEqual(router.detachMessageCallCount, 1)
    }

    func test_viewDidLoad_callsRouterInRightOrder() {
        XCTAssertEqual(router.attachStatusCallCount, 0)
        XCTAssertEqual(router.attachMoreInformationCallCount, 0)

        var callCountIndex = 0
        var attachStatusCallCountIndex = 0
        var attachMoreInformationCallCountIndex = 0

        router.attachStatusHandler = { _ in
            callCountIndex += 1
            attachStatusCallCountIndex = callCountIndex
        }

        router.attachMoreInformationHandler = {
            callCountIndex += 1
            attachMoreInformationCallCountIndex = callCountIndex
        }

        _ = viewController.view

        XCTAssertEqual(router.attachStatusCallCount, 1)
        XCTAssertEqual(router.attachMoreInformationCallCount, 1)
        XCTAssertEqual(attachStatusCallCountIndex, 1)
        XCTAssertEqual(attachMoreInformationCallCountIndex, 2)
    }

    func test_handleButtonAction_updateAppSettings_shouldAlsoRequestPushNotificationPermission() {
        // Arrange
        let completionExpectation = expectation(description: "completionExpectation")
        exposureStateStream.currentExposureState = .init(notifiedState: .notNotified, activeState: .notAuthorized)
        exposureController.requestExposureNotificationPermissionHandler = { completion in
            completion?(nil)
            completionExpectation.fulfill()
        }

        // Act
        viewController.handleButtonAction(.updateAppSettings)

        // Assert
        waitForExpectations()
        XCTAssertEqual(mockUserNotificationController.getAuthorizationStatusCallCount, 1)
    }

    func test_handleButtonAction_updateAppSettings_shouldNotRequestPushNotificationPermission_ifFailed() {
        // Arrange
        let completionExpectation = expectation(description: "completionExpectation")
        exposureStateStream.currentExposureState = .init(notifiedState: .notNotified, activeState: .notAuthorized)
        exposureController.requestExposureNotificationPermissionHandler = { completion in
            completion?(.disabled)
            completionExpectation.fulfill()
        }

        // Act
        viewController.handleButtonAction(.updateAppSettings)

        // Assert
        waitForExpectations()
        XCTAssertEqual(mockUserNotificationController.getAuthorizationStatusCallCount, 0)
    }

    func test_handleButtonAction_explainRisk() {
        XCTAssertEqual(router.routeToMessageCallCount, 0)
        viewController.handleButtonAction(.explainRisk)
        XCTAssertEqual(router.routeToMessageCallCount, 1)
    }

    func test_handleButtonAction_removeNotification_confirmShouldCallExposureController() {
        var createdAlertController: UIAlertController?
        var actionHandlers = [(UIAlertAction) -> ()]()

        alertControllerBuilder.buildAlertControllerHandler = { title, message, prefferedStyle in
            let alertController = UIAlertController(title: title, message: message, preferredStyle: prefferedStyle)
            createdAlertController = alertController
            return alertController
        }

        alertControllerBuilder.buildAlertActionHandler = { title, style, handler in
            actionHandlers.append(handler!)
            return UIAlertAction(title: title, style: style, handler: handler)
        }

        XCTAssertEqual(alertControllerBuilder.buildAlertControllerCallCount, 0)
        XCTAssertEqual(exposureController.confirmExposureNotificationCallCount, 0)

        viewController.handleButtonAction(.removeNotification("SomeTitle"))

        // Execute the last action in the alert, this should call exposureController.confirmExposureNotification()
        actionHandlers.last?(UIAlertAction())

        XCTAssertEqual(alertControllerBuilder.buildAlertControllerCallCount, 1)
        XCTAssertEqual(exposureController.confirmExposureNotificationCallCount, 1)
        XCTAssertEqual(createdAlertController?.title, "SomeTitle")
        XCTAssertEqual(createdAlertController?.message, "Are you sure you want to delete this notification? You won\'t be able to find the date in the app anymore. So remember it well.")
        XCTAssertEqual(createdAlertController?.preferredStyle, .alert)
    }

    func test_enableSettingShouldDismiss_callsRouter() {
        var shouldDismissViewController: Bool!
        router.detachEnableSettingHandler = { shouldDismissViewController = $0 }

        XCTAssertEqual(router.detachEnableSettingCallCount, 0)

        viewController.enableSettingRequestsDismiss(shouldDismissViewController: true)

        XCTAssertEqual(router.detachEnableSettingCallCount, 1)
        XCTAssertTrue(shouldDismissViewController)
    }

    func test_enableSettingDidCompleteAction_callsRouter() {
        var shouldDismissViewController: Bool!
        router.detachEnableSettingHandler = { shouldDismissViewController = $0 }

        XCTAssertEqual(router.detachEnableSettingCallCount, 0)

        viewController.enableSettingDidTriggerAction()

        XCTAssertEqual(router.detachEnableSettingCallCount, 1)
        XCTAssertTrue(shouldDismissViewController)
    }
}
