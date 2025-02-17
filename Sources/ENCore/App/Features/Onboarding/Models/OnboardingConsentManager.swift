/*
 * Copyright (c) 2020 De Staat der Nederlanden, Ministerie van Volksgezondheid, Welzijn en Sport.
 *  Licensed under the EUROPEAN UNION PUBLIC LICENCE v. 1.2
 *
 *  SPDX-License-Identifier: EUPL-1.2
 */

import ENFoundation
import RxSwift
import UIKit

/// @mockable
protocol OnboardingConsentManaging {
    var onboardingConsentSteps: [OnboardingConsentStep] { get }

    func getStep(_ index: Int) -> OnboardingConsentStep?
    func getNextConsentStep(_ currentStep: OnboardingConsentStep.Index, skippedCurrentStep: Bool, completion: @escaping (OnboardingConsentStep.Index?) -> ())
    func isBluetoothEnabled(_ completion: @escaping (Bool) -> ())
    func askEnableExposureNotifications(_ completion: @escaping ((_ exposureActiveState: ExposureActiveState) -> ()))
    func goToBluetoothSettings(_ completion: @escaping (() -> ()))
    func askNotificationsAuthorization(_ completion: @escaping (() -> ()))
    func getAppStoreUrl(_ completion: @escaping ((String?) -> ()))
    func isNotificationAuthorizationAsked() -> Bool
    func isNotificationAuthorizationRestricted() -> Bool
    func didCompleteConsent()
}

final class OnboardingConsentManager: OnboardingConsentManaging, Logging {

    var onboardingConsentSteps: [OnboardingConsentStep] = []
    private var disposeBag = DisposeBag()
    private let userNotificationController: UserNotificationControlling
    private let applicationController: ApplicationControlling

    init(exposureStateStream: ExposureStateStreaming,
         exposureController: ExposureControlling,
         userNotificationController: UserNotificationControlling,
         applicationController: ApplicationControlling,
         theme: Theme) {

        self.exposureStateStream = exposureStateStream
        self.exposureController = exposureController
        self.userNotificationController = userNotificationController
        self.applicationController = applicationController

        onboardingConsentSteps.append(
            OnboardingConsentStep(
                step: .en,
                theme: theme,
                title: .onboardingPermissionsTitle,
                content: .onboardingPermissionsDescription,
                bulletItems: [.onboardingPermissionsDescriptionList1, .onboardingPermissionsDescriptionList2],
                illustration: theme.animationsSupported ? .animation(named: "permission", repeatFromFrame: 100, defaultFrame: 56) : .image(.illustrationCheckmark),
                primaryButtonTitle: .onboardingPermissionsPrimaryButton,
                secondaryButtonTitle: .onboardingPermissionsSecondaryButton,
                hasNavigationBarSkipButton: true
            )
        )

        onboardingConsentSteps.append(
            OnboardingConsentStep(
                step: .bluetooth,
                theme: theme,
                title: .consentStep2Title,
                content: .consentStep2Content,
                illustration: .image(.pleaseTurnOnBluetooth),
                primaryButtonTitle: .consentStep2PrimaryButton,
                secondaryButtonTitle: nil,
                hasNavigationBarSkipButton: true
            )
        )

        /* Disabled For 57828
         onboardingConsentSteps.append(
             OnboardingConsentStep(
                 step: .notifications,
                 theme: theme,
                 title: .consentStep3Title,
                 content: .consentStep3Content,
                 illustration: .image(image: .pleaseTurnOnNotifications),
                 summarySteps: nil,
                 primaryButtonTitle: .consentStep3PrimaryButton,
                 secondaryButtonTitle: .consentStep3SecondaryButton,
                 hasNavigationBarSkipButton: true
             )
         )
         */

        onboardingConsentSteps.append(
            OnboardingConsentStep(
                step: .share,
                theme: theme,
                title: .consentStep4Title,
                content: .consentStep4Content,
                illustration: theme.animationsSupported ? .animation(named: "share", repeatFromFrame: 31, defaultFrame: 35) : .image(.illustrationConnections),
                primaryButtonTitle: .consentStep4PrimaryButton,
                secondaryButtonTitle: .consentStep4SecondaryButton,
                hasNavigationBarSkipButton: true
            )
        )
    }

    // MARK: - Functions

    func getStep(_ index: Int) -> OnboardingConsentStep? {
        if self.onboardingConsentSteps.count > index { return self.onboardingConsentSteps[index] }
        return nil
    }

    func getNextConsentStep(_ currentStep: OnboardingConsentStep.Index, skippedCurrentStep: Bool, completion: @escaping (OnboardingConsentStep.Index?) -> ()) {
        switch currentStep {
        case .en:
            exposureStateStream
                .exposureState
                .observe(on: MainScheduler.instance)
                .filter { $0.activeState != .notAuthorized || skippedCurrentStep }
                .take(1)
                .subscribe(onNext: { value in
                    switch value.activeState {
                    case .inactive(.bluetoothOff):
                        completion(.bluetooth)
                    default:
                        completion(.share)
                    }
                })
                .disposed(by: disposeBag)

        case .bluetooth:
            completion(.share)
        case .share:
            completion(nil)
        }
    }

    func isNotificationAuthorizationAsked() -> Bool {

        let currentState = exposureStateStream.currentExposureState

        if ![ExposureActiveState.notAuthorized, ExposureActiveState.inactive(.disabled)].contains(currentState.activeState) {
            return true
        }

        return false
    }

    func isNotificationAuthorizationRestricted() -> Bool {
        exposureStateStream.currentExposureState.activeState == .restricted
    }

    func isBluetoothEnabled(_ completion: @escaping (Bool) -> ()) {
        let exposureActiveState = exposureStateStream.currentExposureState.activeState
        completion(exposureActiveState == .inactive(.bluetoothOff) ? false : true)
    }

    func askEnableExposureNotifications(_ completion: @escaping ((_ exposureActiveState: ExposureActiveState) -> ())) {
        logDebug("`askEnableExposureNotifications` started")
        let exposureActiveState = exposureStateStream.currentExposureState.activeState

        if exposureActiveState != .notAuthorized, exposureActiveState != .inactive(.disabled) {
            logDebug("`askEnableExposureNotifications` already authorised")
            // already authorized
            completion(exposureActiveState)
            return
        }

        if let subscription = exposureStateSubscription {
            subscription.dispose()
        }

        exposureStateSubscription = exposureStateStream
            .exposureState
            .observe(on: MainScheduler.instance)
            .filter { $0.activeState != .notAuthorized && $0.activeState != .inactive(.disabled) }
            .take(1)
            .subscribe(onNext: { [weak self] state in
                self?.exposureStateSubscription = nil
                self?.logDebug("`askEnableExposureNotifications` active state changed to \(state.activeState)")

                completion(state.activeState)
            })

        logDebug("`askEnableExposureNotifications` calling `requestExposureNotificationPermission`")
        exposureController.requestExposureNotificationPermission(nil)
    }

    func goToBluetoothSettings(_ completion: @escaping (() -> ())) {

        if let settingsUrl = URL(string: UIApplication.openSettingsURLString) {
            if applicationController.canOpenURL(settingsUrl) {
                applicationController.open(settingsUrl)
            }
        }

        completion()
    }

    func askNotificationsAuthorization(_ completion: @escaping (() -> ())) {

        userNotificationController.requestNotificationPermission {
            completion()
        }
    }

    func getAppStoreUrl(_ completion: @escaping ((String?) -> ())) {
        exposureController.getAppVersionInformation { data in
            completion(data?.appStoreURL)
        }
    }

    func didCompleteConsent() {
        didCompleteConsent(completion: nil)
    }

    func didCompleteConsent(completion: (() -> ())?) {
        logTrace()

        // Change stored flags asynchronously to not block the main thread
        DispatchQueue.global(qos: .userInitiated).async {
            self.exposureController.didCompleteOnboarding = true

            // Mark all announcements that were made during the onboarding process as "seen"
            self.exposureController.seenAnnouncements = []
            completion?()
        }
    }

    private let exposureStateStream: ExposureStateStreaming
    private let exposureController: ExposureControlling

    private var exposureStateSubscription: Disposable?
}
