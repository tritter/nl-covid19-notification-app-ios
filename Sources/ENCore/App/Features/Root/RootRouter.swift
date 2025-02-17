/*
 * Copyright (c) 2020 De Staat der Nederlanden, Ministerie van Volksgezondheid, Welzijn en Sport.
 *  Licensed under the EUROPEAN UNION PUBLIC LICENCE v. 1.2
 *
 *  SPDX-License-Identifier: EUPL-1.2
 */

#if canImport(BackgroundTasks)
    import BackgroundTasks
#endif

import ENFoundation
import RxSwift
import UIKit

/// Describes internal `RootViewController` functionality. Contains functions
/// that can be called from `RootRouter`. Should not be exposed
/// from `RootBuilder`. `RootBuilder` returns an `AppEntryPoint` instance instead
/// which is implemented by `RootRouter`.
///
/// @mockable(history: present = true; dismiss = true; presentInNavigationController = true)
protocol RootViewControllable: ViewControllable, OnboardingListener, DeveloperMenuListener, MessageListener, CallGGDListener, EndOfLifeListener, WebviewListener, ShareSheetListener {
    var router: RootRouting? { get set }

    func presentInNavigationController(viewController: ViewControllable, animated: Bool, presentFullScreen: Bool)
    func present(viewController: ViewControllable, animated: Bool, completion: (() -> ())?)
    func dismiss(viewController: ViewControllable, animated: Bool, completion: (() -> ())?)

    func embed(viewController: ViewControllable)
}

final class RootRouter: Router<RootViewControllable>, RootRouting, AppEntryPoint, Logging {
    func detachSharing(shouldHideViewController: Bool) {
        guard let shareViewController = shareViewController else {
            return
        }
        self.shareViewController = nil

        if shouldHideViewController {
            viewController.dismiss(viewController: shareViewController, animated: true, completion: nil)
        }
    }

    // MARK: - Initialisation

    init(viewController: RootViewControllable,
         launchScreenBuilder: LaunchScreenBuildable,
         onboardingBuilder: OnboardingBuildable,
         mainBuilder: MainBuildable,
         endOfLifeBuilder: EndOfLifeBuildable,
         messageBuilder: MessageBuildable,
         callGGDBuilder: CallGGDBuildable,
         exposureController: ExposureControlling,
         exposureStateStream: ExposureStateStreaming,
         mutableNetworkStatusStream: MutableNetworkStatusStreaming,
         developerMenuBuilder: DeveloperMenuBuildable,
         mutablePushNotificationStream: MutablePushNotificationStreaming,
         networkController: NetworkControlling,
         backgroundController: BackgroundControlling,
         updateAppBuilder: UpdateAppBuildable,
         updateOperatingSystemBuilder: UpdateOperatingSystemBuildable,
         webviewBuilder: WebviewBuildable,
         userNotificationController: UserNotificationControlling,
         currentAppVersion: String,
         environmentController: EnvironmentControlling,
         pauseController: PauseControlling,
         shareBuilder: ShareSheetBuildable) {
        self.launchScreenBuilder = launchScreenBuilder
        self.onboardingBuilder = onboardingBuilder
        self.mainBuilder = mainBuilder
        self.endOfLifeBuilder = endOfLifeBuilder
        self.messageBuilder = messageBuilder
        self.callGGDBuilder = callGGDBuilder
        self.developerMenuBuilder = developerMenuBuilder
        self.webviewBuilder = webviewBuilder

        self.exposureController = exposureController
        self.exposureStateStream = exposureStateStream

        self.mutablePushNotificationStream = mutablePushNotificationStream

        self.networkController = networkController
        self.backgroundController = backgroundController

        self.updateAppBuilder = updateAppBuilder
        self.currentAppVersion = currentAppVersion

        self.userNotificationController = userNotificationController
        self.mutableNetworkStatusStream = mutableNetworkStatusStream

        self.updateOperatingSystemBuilder = updateOperatingSystemBuilder

        self.environmentController = environmentController
        self.pauseController = pauseController

        self.shareBuilder = shareBuilder

        super.init(viewController: viewController)

        viewController.router = self
    }

    // MARK: - AppEntryPoint

    var uiviewController: UIViewController {
        return viewController.uiviewController
    }

    let mutablePushNotificationStream: MutablePushNotificationStreaming

    /// Executes the first routing actions when the app starts. Based on the state of the app, the device and backend configuration there can be a few possible outcomes:
    /// - The app shows the `onboarding` screens if they haven't been completed before
    /// - The app shows an `operating system upgrade` indication screen because the iOS version is not supported
    /// - The app shows a `deactivated` screen, indicating that CoronaMelder has been shut down and the app can no longer be user
    /// - The app shows an `app update` screen, indicating that the backend configuration file returns a minimum app version and the user should update the app
    func start() {
        logDebug("RootRouter - start() called")

        guard mainRouter == nil, onboardingRouter == nil else {
            logTrace()
            logDebug("RootRouter - already started")
            return
        }

        if !environmentController.supportsExposureNotification || !environmentController.appSupportsiOSversion {
            routeToUpdateOperatingSystem()
            logDebug("RootRouter - doesn't support EN")
            return
        }

        // Copy of launch screen is shown to give the app time to determine the proper
        // screen to route to. If the network is slow this can take a few seconds.
        routeToLaunchScreen { [weak self] in

            self?.logDebug("Finished routing to launch screen")

            guard let strongSelf = self else { return }

            strongSelf.backgroundController.registerActivityHandle()

            strongSelf.routeToDeactivatedOrUpdateScreenIfNeeded { [weak self] didRoute in

                guard let strongSelf = self else { return }

                if strongSelf.exposureController.didCompleteOnboarding {
                    strongSelf.backgroundController.scheduleTasks()
                    strongSelf.backgroundController.scheduleRemoteNotification()
                }

                guard !didRoute else {
                    return
                }

                strongSelf.detachLaunchScreenIfNeeded(animated: false) { [weak self] in

                    self?.logTrace()

                    guard let strongSelf = self else { return }

                    if strongSelf.exposureController.didCompleteOnboarding {
                        self?.logTrace()
                        strongSelf.routeToMain()
                        strongSelf.subscribeToPushNotificationStream()
                    } else {
                        self?.logTrace()
                        strongSelf.routeToOnboarding()
                    }
                }

                #if USE_DEVELOPER_MENU || DEBUG
                    strongSelf.attachDeveloperMenu()
                #endif
            }
        }
    }

    func didBecomeActive() {
        exposureController.refreshStatus(completion: nil)

        if mainRouter != nil || onboardingRouter != nil {
            // App was started already. Check if we need to route to update / deactivated screen
            routeToDeactivatedOrUpdateScreenIfNeeded()
        }

        // Perform storage-related tasks in background to prevent blocking the main thread on slower devices
        DispatchQueue.global(qos: .userInitiated).async {
            if !self.pauseController.isAppPaused {
                self.updateTreatmentPerspective()
            }

            self.exposureController.updateLastLaunch()

            self.exposureController.clearUnseenExposureNotificationDate()
        }

        userNotificationController.removeNotificationsFromNotificationsCenter()

        // On iOS 12 the app is not informed of entering the foreground on startup, call didEnterForeground manually
        if environmentController.isiOS12 {
            didEnterForeground()
        }
    }

    func didEnterForeground() {
        mutableNetworkStatusStream.startObservingNetworkReachability()

        guard mainRouter != nil || onboardingRouter != nil else {
            // not started yet
            return
        }

        exposureController.refreshStatus(completion: nil)

        DispatchQueue.global(qos: .userInitiated).async {
            if !self.pauseController.isAppPaused {
                self.exposureController
                    .updateWhenRequired()
                    .subscribe()
                    .disposed(by: self.disposeBag)
            }
        }
    }

    func didEnterBackground() {
        mutableNetworkStatusStream.stopObservingNetworkReachability()
    }

    @available(iOS 13, *)
    func handle(backgroundTask: BackgroundTask) {
        backgroundController.handle(task: backgroundTask)
    }

    // MARK: - RootRouting

    func routeToLaunchScreen(completion: @escaping () -> ()) {
        guard launchScreenController == nil else {
            // already presented
            return
        }

        let launchScreenViewController = launchScreenBuilder.build()
        launchScreenController = launchScreenViewController

        viewController.present(viewController: launchScreenViewController,
                               animated: false,
                               completion: completion)
    }

    func routeToOnboarding() {
        logTrace()
        guard onboardingRouter == nil else {
            // already presented
            return
        }

        logTrace()
        let onboardingRouter = onboardingBuilder.build(withListener: viewController)
        self.onboardingRouter = onboardingRouter

        viewController.present(viewController: onboardingRouter.viewControllable,
                               animated: false,
                               completion: nil)
    }

    func scheduleTasks() {
        backgroundController.scheduleTasks()
    }

    func detachOnboardingAndRouteToMain(animated: Bool) {
        routeToMain()
        subscribeToPushNotificationStream()
        detachOnboarding(animated: animated)
    }

    func routeToMessage() {
        guard messageViewController == nil else {
            return
        }
        let messageViewController = messageBuilder.build(withListener: viewController)
        self.messageViewController = messageViewController

        viewController.presentInNavigationController(viewController: messageViewController, animated: true, presentFullScreen: false)
    }

    func detachMessage(shouldDismissViewController: Bool) {
        guard let messageViewController = messageViewController else {
            return
        }
        self.messageViewController = nil

        if shouldDismissViewController {
            viewController.dismiss(viewController: messageViewController, animated: true, completion: nil)
        }
    }

    func detachCallGGD(shouldDismissViewController: Bool) {
        guard let callGGDViewController = callGGDViewController else {
            return
        }
        self.callGGDViewController = nil

        if shouldDismissViewController {
            viewController.dismiss(viewController: callGGDViewController, animated: true, completion: nil)
        }
    }

    func routeToUpdateApp(appStoreURL: String?, minimumVersionMessage: String?) {
        guard updateAppViewController == nil else {
            return
        }
        let updateAppViewController = updateAppBuilder.build(appStoreURL: appStoreURL,
                                                             minimumVersionMessage: minimumVersionMessage)
        self.updateAppViewController = updateAppViewController

        viewController.present(viewController: updateAppViewController, animated: true, completion: nil)
    }

    func routeToUpdateOperatingSystem() {
        guard updateOperatingSystemViewController == nil else {
            return
        }
        let updateOSViewController = updateOperatingSystemBuilder.build()

        updateOperatingSystemViewController = updateOSViewController

        viewController.present(viewController: updateOSViewController, animated: true, completion: nil)
    }

    func routeToWebview(url: URL) {
        guard webviewViewController == nil else { return }

        let webviewViewController = webviewBuilder.build(withListener: viewController, url: url)
        self.webviewViewController = webviewViewController

        viewController.presentInNavigationController(viewController: webviewViewController, animated: true, presentFullScreen: false)
    }

    func detachWebview(shouldDismissViewController: Bool) {
        guard let webviewViewController = webviewViewController else {
            return
        }
        self.webviewViewController = nil

        if shouldDismissViewController {
            viewController.dismiss(viewController: webviewViewController, animated: true, completion: nil)
        }
    }

    func routeToSharing(shouldAnimate: Bool = false) {
        guard shareViewController == nil else {
            return
        }

        let shareViewController = shareBuilder.build(withListener: viewController, items: [])
        self.shareViewController = shareViewController

        viewController.presentInNavigationController(viewController: shareViewController, animated: shouldAnimate, presentFullScreen: false)
    }

    // MARK: - Private

    private func routeToMain() {
        guard mainRouter == nil else {
            // already attached
            return
        }

        let mainRouter = mainBuilder.build()
        self.mainRouter = mainRouter

        viewController.embed(viewController: mainRouter.viewControllable)
    }

    private func routeToEndOfLife() {
        guard endOfLifeViewController == nil else {
            return
        }

        /// Set the correct window hierachy
        detachOnboarding(animated: false)
        routeToMain()

        let endOfLifeViewController = endOfLifeBuilder.build(withListener: viewController)
        self.endOfLifeViewController = endOfLifeViewController
        viewController.presentInNavigationController(viewController: endOfLifeViewController, animated: false, presentFullScreen: true)
    }

    private func routeToCallGGD() {
        guard callGGDViewController == nil else {
            return
        }
        let callGGDViewController = callGGDBuilder.build(withListener: viewController)
        self.callGGDViewController = callGGDViewController

        viewController.presentInNavigationController(viewController: callGGDViewController, animated: true, presentFullScreen: false)
    }

    private func detachLaunchScreenIfNeeded(animated: Bool, completion: (() -> ())?) {
        guard let launchScreenController = launchScreenController else {
            completion?()
            return
        }

        self.launchScreenController = nil

        viewController.dismiss(viewController: launchScreenController,
                               animated: animated,
                               completion: completion)
    }

    private func detachOnboarding(animated: Bool) {
        guard let onboardingRouter = onboardingRouter else {
            return
        }

        self.onboardingRouter = nil

        viewController.dismiss(viewController: onboardingRouter.viewControllable,
                               animated: animated,
                               completion: nil)
    }

    private func attachDeveloperMenu() {
        guard developerMenuViewController == nil else { return }

        let developerMenuViewController = developerMenuBuilder.build(listener: viewController)
        self.developerMenuViewController = developerMenuViewController
    }

    private func routeToDeactivatedOrUpdateScreenIfNeeded(completion: ((_ didRoute: Bool) -> ())? = nil) {
        Observable
            .combineLatest(exposureController.isAppDeactivated().asObservable(), exposureController.appShouldUpdateCheck().asObservable())
            .observe(on: MainScheduler.instance)
            .subscribe { [weak self] isDeactivated, updateInformation in
                if isDeactivated {
                    self?.detachLaunchScreenIfNeeded(animated: false) {
                        self?.routeToEndOfLife()
                        self?.exposureController.deactivate()
                        self?.backgroundController.removeAllTasks()
                        completion?(true)
                    }

                    return
                }

                if updateInformation.shouldUpdate, let versionInformation = updateInformation.versionInformation {
                    let minimumVersionMessage = versionInformation.minimumVersionMessage.isEmpty ? nil : versionInformation.minimumVersionMessage

                    self?.detachLaunchScreenIfNeeded(animated: false) {
                        self?.routeToUpdateApp(appStoreURL: versionInformation.appStoreURL, minimumVersionMessage: minimumVersionMessage)
                        completion?(true)
                    }
                    return
                }

                guard let strongSelf = self else {
                    self?.logError("Root Router released before routing")
                    completion?(false)
                    return
                }

                strongSelf.exposureController
                    .activate()
                    .subscribe(on: ConcurrentDispatchQueueScheduler(qos: .userInitiated))
                    .observe(on: ConcurrentDispatchQueueScheduler(qos: .userInitiated))
                    .subscribe(onCompleted: {
                        strongSelf.exposureController.postExposureManagerActivation()
                        strongSelf.backgroundController.performDecoySequenceIfNeeded()
                    })
                    .disposed(by: strongSelf.disposeBag)

                completion?(false)

            } onError: { [weak self] error in

                let exposureDataError = error.asExposureDataError

                if exposureDataError == .networkUnreachable ||
                    exposureDataError == .serverError ||
                    exposureDataError == .internalError ||
                    exposureDataError == .responseCached {
                    guard let strongSelf = self else {
                        self?.logError("Root Router released before routing")
                        completion?(false)
                        return
                    }

                    self?.exposureController.activate()
                        .subscribe(onCompleted: {
                            strongSelf.exposureController.postExposureManagerActivation()
                        })
                        .disposed(by: strongSelf.disposeBag)
                }

                completion?(false)
            }
            .disposed(by: disposeBag)
    }

    private func updateTreatmentPerspective() {
        exposureController
            .updateTreatmentPerspective()
            .subscribe { _ in }
            .disposed(by: disposeBag)
    }

    private func subscribeToPushNotificationStream() {
        mutablePushNotificationStream
            .pushNotificationStream
            .subscribe(onNext: { [weak self] pushNotificationIdentifier in
                guard let strongSelf = self else {
                    return
                }

                self?.logDebug("Push Notification Identifier: \(pushNotificationIdentifier.rawValue)")

                switch pushNotificationIdentifier {
                case .exposure:
                    strongSelf.routeToMessage()
                case .inactive:
                    () // Do nothing
                case .uploadFailed:
                    strongSelf.routeToCallGGD()
                case .enStatusDisabled:
                    () // Do nothing
                case .appUpdateRequired:
                    () // Do nothing
                case .pauseEnded:
                    () // Do nothing
                case .remoteScheduled:

                    self?.logDebug("Should route to: \(String(describing: self?.exposureController.getScheduledNotificaton()?.getTargetScreen()))")

                    if self?.exposureController.getScheduledNotificaton()?.getTargetScreen() == .share {
                        strongSelf.routeToSharing()
                        self?.logDebug("Routing to: share")
                        return
                    }
                    () // Do nothing
                }
            })
            .disposed(by: disposeBag)
    }

    private let currentAppVersion: String

    private let networkController: NetworkControlling
    private let backgroundController: BackgroundControlling

    private let exposureController: ExposureControlling
    private let exposureStateStream: ExposureStateStreaming

    private var launchScreenBuilder: LaunchScreenBuildable
    private var launchScreenController: ViewControllable?

    private let onboardingBuilder: OnboardingBuildable
    private var onboardingRouter: Routing?

    private let mainBuilder: MainBuildable
    private var mainRouter: Routing?

    private let endOfLifeBuilder: EndOfLifeBuildable
    private var endOfLifeViewController: ViewControllable?

    private let messageBuilder: MessageBuildable
    private var messageViewController: ViewControllable?

    private let callGGDBuilder: CallGGDBuildable
    private var callGGDViewController: ViewControllable?

    private var disposeBag = DisposeBag()

    private let developerMenuBuilder: DeveloperMenuBuildable
    private var developerMenuViewController: ViewControllable?

    private let updateAppBuilder: UpdateAppBuildable
    private var updateAppViewController: ViewControllable?

    private let updateOperatingSystemBuilder: UpdateOperatingSystemBuildable
    private var updateOperatingSystemViewController: ViewControllable?

    private let webviewBuilder: WebviewBuildable
    private var webviewViewController: ViewControllable?

    private let userNotificationController: UserNotificationControlling

    private let mutableNetworkStatusStream: MutableNetworkStatusStreaming

    private let environmentController: EnvironmentControlling
    private let pauseController: PauseControlling

    private let shareBuilder: ShareSheetBuildable
    private var shareViewController: ViewControllable?
}

private extension ExposureActiveState {
    var isAuthorized: Bool {
        switch self {
        case .active, .inactive, .authorizationDenied:
            return true
        case .notAuthorized, .restricted:
            return false
        }
    }
}
