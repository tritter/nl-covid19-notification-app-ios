/*
 * Copyright (c) 2020 De Staat der Nederlanden, Ministerie van Volksgezondheid, Welzijn en Sport.
 *  Licensed under the EUROPEAN UNION PUBLIC LICENCE v. 1.2
 *
 *  SPDX-License-Identifier: EUPL-1.2
 */

import ENFoundation
import Foundation
import RxSwift
import UIKit

/// This class is the main entry point for the Exposure Notification framework. It allows us to enable or disable the framework
/// as well as perform calls against it to check the status and do the actual exposure checks.
///
/// Note: During development this class grew too big. It has a lot of functionality in it that is NOT related to exposure checking but was put in here
/// because we couldn't find a better place at the time. This should be refactored and the functionality and data access should be moved to their related features.
final class ExposureController: ExposureControlling, Logging {

    init(mutableStateStream: MutableExposureStateStreaming,
         exposureManager: ExposureManaging,
         dataController: ExposureDataControlling,
         networkStatusStream: NetworkStatusStreaming,
         userNotificationController: UserNotificationControlling,
         currentAppVersion: String,
         cellularDataStream: CellularDataStreaming) {
        self.mutableStateStream = mutableStateStream
        self.exposureManager = exposureManager
        self.dataController = dataController
        self.networkStatusStream = networkStatusStream
        self.userNotificationController = userNotificationController
        self.currentAppVersion = currentAppVersion
        self.cellularDataStream = cellularDataStream
    }

    // MARK: - ExposureControlling

    var lastExposureDate: Date? {
        return dataController.lastExposure?.date
    }

    var isFirstRun: Bool {
        return dataController.isFirstRun
    }

    var didCompleteOnboarding: Bool {
        get {
            return dataController.didCompleteOnboarding
        }
        set {
            dataController.didCompleteOnboarding = newValue
        }
    }

    var seenAnnouncements: [Announcement] {
        get {
            return dataController.seenAnnouncements
        }
        set {
            dataController.seenAnnouncements = newValue
        }
    }

    @discardableResult
    func activate() -> Completable {
        logDebug("Request EN framework activation")

        if let existingCompletable = activationCompletable {
            logDebug("Already activating")
            return existingCompletable
        }

        let completable = Completable.create { (observer) -> Disposable in

            guard self.isActivated == false else {
                self.logDebug("Already activated")
                // already activated, return success
                observer(.completed)
                return Disposables.create()
            }

            // Don't activate EN if we're in a paused state
            guard !self.dataController.isAppPaused else {
                observer(.completed)
                return Disposables.create()
            }

            self.updatePushNotificationState {
                self.logDebug("EN framework activating")
                self.exposureManager.activate { error in

                    self.logDebug("result from EN Activation: \(error)")

                    self.isActivated = true

                    self.logDebug("EN framework activated `authorizationStatus`: \(self.exposureManager.authorizationStatus.rawValue) `isExposureNotificationEnabled`: \(self.exposureManager.isExposureNotificationEnabled())")

                    if self.exposureManager.authorizationStatus == .authorized, !self.exposureManager.isExposureNotificationEnabled(), self.didCompleteOnboarding {
                        self.logDebug("Calling `setExposureNotificationEnabled`")
                        self.exposureManager.setExposureNotificationEnabled(true) { result in
                            if case let .failure(error) = result {
                                self.logDebug("`setExposureNotificationEnabled` error: \(error.localizedDescription)")
                            } else {
                                self.logDebug("Returned from `setExposureNotificationEnabled` (success)")
                            }

                            observer(.completed)
                        }
                    } else {
                        observer(.completed)
                    }
                }
            }

            return Disposables.create()
        }

        let resettingCompletable = completable
            .do(onError: { [weak self] _ in
                self?.activationCompletable = nil
            }, onCompleted: { [weak self] in
                self?.activationCompletable = nil
            })

        activationCompletable = resettingCompletable

        return resettingCompletable
    }

    func deactivate() {
        exposureManager.deactivate()
    }

    func pause(untilDate date: Date) {
        exposureManager.setExposureNotificationEnabled(false) { [weak self] result in
            self?.dataController.pauseEndDate = date
            self?.updateStatusStream()
        }
    }

    func unpause() {

        exposureManager.setExposureNotificationEnabled(true) { [weak self] result in

            guard let strongSelf = self else {
                return
            }

            strongSelf.dataController.pauseEndDate = nil

            if strongSelf.isActivated == false {
                strongSelf.activate()
                    .subscribe(onCompleted: {
                        strongSelf.updateStatusStream()
                    })
                    .disposed(by: strongSelf.disposeBag)

            } else {
                // Update the status (will remove the paused state from the UI)
                strongSelf.updateStatusStream()

                strongSelf.updateWhenRequired()
                    .subscribe()
                    .disposed(by: strongSelf.disposeBag)
            }
        }
    }

    func getAppVersionInformation(_ completion: @escaping (ExposureDataAppVersionInformation?) -> ()) {
        return dataController
            .getAppVersionInformation()
            .subscribe(onSuccess: { exposureDataAppVersionInformation in
                completion(exposureDataAppVersionInformation)
            }, onFailure: { _ in
                completion(nil)
            })
            .disposed(by: disposeBag)
    }

    func isAppDeactivated() -> Single<Bool> {
        return dataController.isAppDeactivated()
    }

    func getDecoyProbability() -> Single<Float> {
        return dataController.getDecoyProbability()
    }

    func getPadding() -> Single<Padding> {
        return dataController
            .getPadding()
    }

    func getStoredAppConfigFeatureFlags() -> [ApplicationConfiguration.FeatureFlag]? {
        dataController.getStoredAppConfigFeatureFlags()
    }

    func getScheduledNotificaton() -> ApplicationConfiguration.ScheduledNotification? {
        dataController.getScheduledNotificaton()
    }

    func getStoredShareKeyURL() -> String? {
        dataController.getStoredShareKeyURL()
    }

    func refreshStatus(completion: (() -> ())?) {
        updatePushNotificationState { [weak self] in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.updateStatusStream()
                completion?()
            }
        }
    }

    func updateWhenRequired() -> Completable {

        logDebug("Update when required started")

        if let updateStream = updateStream {
            // already updating
            logDebug("Already updating")
            return updateStream
        }

        let updateStream = mutableStateStream
            .exposureState
            .take(1)
            .flatMap { (state: ExposureState) -> Completable in
                // update when active, or when inactive due to no recent updates
                guard [.active, .inactive(.noRecentNotificationUpdates), .inactive(.noRecentNotificationUpdatesInternetOff), .inactive(.pushNotifications), .inactive(.bluetoothOff)].contains(state.activeState) else {
                    self.logDebug("Not updating as inactive (status: \(state.activeState))")
                    return .empty()
                }

                self.logDebug("Going to fetch and process exposure keysets")
                return .create { observer -> Disposable in
                    self.fetchAndProcessExposureKeySets().subscribe { _ in
                        return observer(.completed)
                    }
                }
            }
            .do(onError: { [weak self] _ in
                self?.updateStream = nil
            }, onCompleted: { [weak self] in
                self?.updateStream = nil
            })
            .share()
            .asCompletable()

        self.updateStream = updateStream
        return updateStream
    }

    func processExpiredUploadRequests() -> Completable {
        return dataController
            .processExpiredUploadRequests()
    }

    func processPendingUploadRequests() -> Completable {
        return dataController
            .processPendingUploadRequests()
    }

    func requestExposureNotificationPermission(_ completion: ((ExposureManagerError?) -> ())?) {
        logDebug("`requestExposureNotificationPermission` started")

        exposureManager.setExposureNotificationEnabled(true) { result in
            self.logDebug("`requestExposureNotificationPermission` returned result \(result)")

            // wait for 0.2s, there seems to be a glitch in the framework
            // where after successful activation it returns '.disabled' for a
            // split second
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.2) {
                if case let .failure(error) = result {
                    completion?(error)
                } else {
                    completion?(nil)
                }

                self.updateStatusStream()
            }
        }
    }

    func fetchAndProcessExposureKeySets() -> Completable {
        logDebug("fetchAndProcessExposureKeySets started")
        if let existingCompletable = keysetFetchProcessCompletable {
            logDebug("Already fetching")
            return existingCompletable
        }

        let completable = dataController
            .fetchAndProcessExposureKeySets(exposureManager: exposureManager)
            .do(onError: { [weak self] error in
                self?.logDebug("fetchAndProcessExposureKeySets Completed with failure: \(error.localizedDescription)")
                self?.updateStatusStream()
                self?.keysetFetchProcessCompletable = nil
            }, onCompleted: { [weak self] in
                self?.logDebug("fetchAndProcessExposureKeySets Completed successfuly")
                self?.updateStatusStream()
                self?.keysetFetchProcessCompletable = nil
            })

        keysetFetchProcessCompletable = completable

        return completable
    }

    func confirmExposureNotification() {
        dataController
            .removeLastExposure()
            .andThen(dataController.removeFirstNotificationReceivedDate())
            .subscribe(onCompleted: { [weak self] in
                self?.updateStatusStream()
            }, onError: { [weak self] _ in
                self?.updateStatusStream()
            })
            .disposed(by: disposeBag)
    }

    func requestLabConfirmationKey(completion: @escaping (Result<ExposureConfirmationKey, ExposureDataError>) -> ()) {
        dataController
            .requestLabConfirmationKey()
            .subscribe(on: MainScheduler.instance)
            .subscribe(onSuccess: { labConfirmationKey in
                completion(.success(labConfirmationKey))
            }, onFailure: { error in
                let convertedError = (error as? ExposureDataError) ?? ExposureDataError.internalError
                completion(.failure(convertedError))
            }).disposed(by: self.disposeBag)
    }

    func requestUploadKeys(forLabConfirmationKey labConfirmationKey: ExposureConfirmationKey,
                           completion: @escaping (ExposureControllerUploadKeysResult) -> ()) {

        guard let labConfirmationKey = labConfirmationKey as? LabConfirmationKey else {
            completion(.invalidConfirmationKey)
            return
        }

        requestDiagnosisKeys()
            .subscribe(onSuccess: { keys in
                self.upload(diagnosisKeys: keys,
                            labConfirmationKey: labConfirmationKey,
                            completion: completion)
            }, onFailure: { error in

                let exposureManagerError = error.asExposureManagerError
                switch exposureManagerError {
                case .notAuthorized:
                    completion(.notAuthorized)
                default:
                    completion(.inactive)
                }
            })
            .disposed(by: disposeBag)
    }

    func updateLastLaunch() {
        dataController.setLastAppLaunchDate(Date())
    }

    func clearUnseenExposureNotificationDate() {
        dataController.clearLastUnseenExposureNotificationDate()
    }

    func updateExposureFirstNotificationReceivedDate(_ date: Date) {
        dataController.updateExposureFirstNotificationReceivedDate(date)
    }

    func updateAndProcessPendingUploads() -> Completable {
        logDebug("Update and Process, authorisationStatus: \(exposureManager.authorizationStatus.rawValue)")

        guard exposureManager.authorizationStatus == .authorized else {
            return .error(ExposureDataError.notAuthorized)
        }

        logDebug("Current exposure notification status: \(String(describing: mutableStateStream.currentExposureState.activeState)), activated before: \(isActivated)")

        let sequence: [Completable] = [
            self.processExpiredUploadRequests(),
            self.processPendingUploadRequests()
        ]

        logDebug("Executing update sequence")

        // Combine all processes together, the sequence will be exectued in the order they are in the `sequence` array
        return Observable.from(sequence.compactMap { $0 })
            // execute one at the same time
            .merge(maxConcurrent: 1)
            // collect them
            .toArray()
            .asCompletable()
            .do(onError: { [weak self] error in
                self?.logError("Error completing sequence \(error.localizedDescription)")
            }, onCompleted: { [weak self] in
                // notify the user if required
                self?.logDebug("--- Finished `updateAndProcessPendingUploads` ---")
                self?.notifyUser24HoursNoCheckIfRequired()
            })
    }

    func exposureNotificationStatusCheck() -> Completable {
        return .create { (observer) -> Disposable in
            self.logDebug("Exposure Notification Status Check Started")

            let now = Date()
            let status = self.exposureManager.getExposureNotificationStatus()

            guard status != .active else {
                self.dataController.setLastENStatusCheckDate(now)
                self.logDebug("`exposureNotificationStatusCheck` skipped as it is `active`")
                observer(.completed)
                return Disposables.create()
            }

            guard let lastENStatusCheckDate = self.dataController.lastENStatusCheckDate else {
                self.dataController.setLastENStatusCheckDate(now)
                self.logDebug("No `lastENStatusCheck`, skipping")
                observer(.completed)
                return Disposables.create()
            }

            let timeInterval = TimeInterval(60 * 60 * 24) // 24 hours

            guard lastENStatusCheckDate.addingTimeInterval(timeInterval) < Date() else {
                self.logDebug("`exposureNotificationStatusCheck` skipped as it hasn't been 24h")
                observer(.completed)
                return Disposables.create()
            }

            self.logDebug("EN Status Check not active within 24h: \(status)")
            self.dataController.setLastENStatusCheckDate(now)

            self.userNotificationController.displayNotActiveNotification { _ in
                observer(.completed)
            }

            return Disposables.create()
        }
    }

    func appShouldUpdateCheck() -> Single<AppUpdateInformation> {
        return .create { observer in

            self.logDebug("appShouldUpdateCheck Started")

            self.shouldAppUpdate { updateInformation in
                observer(.success(updateInformation))
            }

            return Disposables.create()
        }
    }

    func sendNotificationIfAppShouldUpdate() -> Completable {
        return .create { (observer) -> Disposable in

            self.logDebug("sendNotificationIfAppShouldUpdate Started")

            self.shouldAppUpdate { updateInformation in

                guard updateInformation.shouldUpdate, let appVersionInformation = updateInformation.versionInformation else {
                    observer(.completed)
                    return
                }

                let message = appVersionInformation.minimumVersionMessage.isEmpty ? String.updateAppContent : appVersionInformation.minimumVersionMessage

                self.userNotificationController.displayAppUpdateRequiredNotification(withUpdateMessage: message) { _ in
                    observer(.completed)
                }
            }

            return Disposables.create()
        }
    }

    func updateTreatmentPerspective() -> Completable {
        dataController.updateTreatmentPerspective()
    }

    func lastOpenedNotificationCheck() -> Completable {
        return .create { (observer) -> Disposable in

            guard let lastAppLaunch = self.dataController.lastAppLaunchDate else {
                self.logDebug("`lastOpenedNotificationCheck` skipped as there is no `lastAppLaunchDate`")
                observer(.completed)
                return Disposables.create()
            }
            guard let lastExposure = self.dataController.lastExposure else {
                self.logDebug("`lastOpenedNotificationCheck` skipped as there is no `lastExposureDate`")
                observer(.completed)
                return Disposables.create()
            }

            guard let lastUnseenExposureNotificationDate = self.dataController.lastUnseenExposureNotificationDate else {
                self.logDebug("`lastOpenedNotificationCheck` skipped as there is no `lastUnseenExposureNotificationDate`")
                observer(.completed)
                return Disposables.create()
            }

            guard lastAppLaunch < lastUnseenExposureNotificationDate else {
                self.logDebug("`lastOpenedNotificationCheck` skipped as the app has been opened after the notification")
                observer(.completed)
                return Disposables.create()
            }

            let notificationThreshold = TimeInterval(60 * 60 * 3) // 3 hours

            guard lastUnseenExposureNotificationDate.addingTimeInterval(notificationThreshold) < Date() else {
                self.logDebug("`lastOpenedNotificationCheck` skipped as it hasn't been 3h after initial notification")
                observer(.completed)
                return Disposables.create()
            }

            guard lastAppLaunch.addingTimeInterval(notificationThreshold) < Date() else {
                self.logDebug("`lastOpenedNotificationCheck` skipped as it hasn't been 3h")
                observer(.completed)
                return Disposables.create()
            }

            self.logDebug("User has not opened the app in 3 hours.")

            let days = Date().days(sinceDate: lastExposure.date) ?? 0

            self.userNotificationController.displayExposureReminderNotification(daysSinceLastExposure: days) { _ in
                observer(.completed)
            }

            return Disposables.create()
        }
    }

    func notifyUser24HoursNoCheckIfRequired() {

        func notifyUser() {
            self.userNotificationController.display24HoursNoActivityNotification { [weak self] _ in
                self?.dataController.updateLastLocalNotificationExposureDate(currentDate())
            }
        }

        let timeInterval = TimeInterval(60 * 60 * 24) // 24 hours
        guard
            let lastSuccessfulProcessingDate = dataController.lastSuccessfulExposureProcessingDate,
            lastSuccessfulProcessingDate.addingTimeInterval(timeInterval) < currentDate()
        else {
            return
        }
        guard let lastLocalNotificationExposureDate = dataController.lastLocalNotificationExposureDate else {
            // We haven't shown a notification to the user before so we should show one now
            return notifyUser()
        }
        guard lastLocalNotificationExposureDate.addingTimeInterval(timeInterval) < currentDate() else {
            return
        }

        notifyUser()
    }

    func lastTEKProcessingDate() -> Observable<Date?> {
        return dataController.lastSuccessfulExposureProcessingDateObservable
    }

    func updateLastExposureProcessingDateSubject() {
        dataController.updateLastExposureProcessingDateSubject()
    }

    // MARK: - Private

    private func shouldAppUpdate(completion: @escaping (AppUpdateInformation) -> ()) {
        getAppVersionInformation { appVersionInformation in

            guard let appVersionInformation = appVersionInformation else {
                self.logError("Error retrieving app version information")
                return completion(AppUpdateInformation(shouldUpdate: false, versionInformation: nil))
            }

            let shouldUpdate = appVersionInformation.minimumVersion.compare(self.currentAppVersion, options: .numeric) == .orderedDescending

            completion(AppUpdateInformation(shouldUpdate: shouldUpdate, versionInformation: appVersionInformation))
        }
    }

    func postExposureManagerActivation() {
        logDebug("`postExposureManagerActivation`")

        mutableStateStream
            .exposureState
            .observe(on: ConcurrentDispatchQueueScheduler(qos: .userInitiated))
            .flatMap { [weak self] (exposureState) -> Single<Bool> in
                let stateActive = [.active, .inactive(.noRecentNotificationUpdates), .inactive(.noRecentNotificationUpdatesInternetOff), .inactive(.bluetoothOff)].contains(exposureState.activeState)
                    && (self?.networkStatusStream.networkReachable == true)
                return .just(stateActive)
            }
            .filter { $0 }
            .take(1)
            .do(onNext: { [weak self] _ in
                self?.updateStatusStream()
            }, onError: { [weak self] _ in
                self?.updateStatusStream()
            })
            .flatMap { [weak self] (_) -> Completable in
                return self?
                    .updateWhenRequired() ?? .empty()
            }
            .subscribe(onNext: { _ in })
            .disposed(by: disposeBag)

        networkStatusStream
            .networkReachableStream
            .observe(on: ConcurrentDispatchQueueScheduler(qos: .userInitiated))
            .do(onNext: { [weak self] _ in
                self?.updateStatusStream()
            }, onError: { [weak self] _ in
                self?.updateStatusStream()
            })
            .filter { $0 } // only update when internet is active
            .map { [weak self] (_) -> Completable in
                return self?
                    .updateWhenRequired() ?? .empty()
            }
            .subscribe(onNext: { _ in })
            .disposed(by: disposeBag)
    }

    private func updateStatusStream() {

        if let pauseEndDate = dataController.pauseEndDate {
            mutableStateStream.update(state: .init(notifiedState: notifiedState, activeState: .inactive(.paused(pauseEndDate))))
            return
        }

        guard isActivated else {
            return logDebug("Not Updating Status Stream as not `isActivated`")
        }

        logDebug("Updating Status Stream")

        let noInternetIntervalForShowingWarning = TimeInterval(60 * 60 * 24) // 24 hours
        let hasBeenTooLongSinceLastUpdate: Bool

        if let lastSuccessfulExposureProcessingDate = dataController.lastSuccessfulExposureProcessingDate {
            hasBeenTooLongSinceLastUpdate = lastSuccessfulExposureProcessingDate.addingTimeInterval(noInternetIntervalForShowingWarning) < Date()
        } else {
            hasBeenTooLongSinceLastUpdate = false
        }

        let activeState: ExposureActiveState
        let exposureManagerStatus = exposureManager.getExposureNotificationStatus()
        let cellularState = (try? cellularDataStream.restrictedState.value()) ?? .restrictedStateUnknown

        switch exposureManagerStatus {
        case .active where hasBeenTooLongSinceLastUpdate:
            if cellularState == .restricted {
                activeState = .inactive(.noRecentNotificationUpdatesInternetOff)
            } else {
                activeState = .inactive(.noRecentNotificationUpdates)
            }
        case .active where !isPushNotificationsEnabled:
            activeState = .inactive(.pushNotifications)
        case .active:
            activeState = .active
        case .inactive(_) where hasBeenTooLongSinceLastUpdate:
            if cellularState == .restricted {
                activeState = .inactive(.noRecentNotificationUpdatesInternetOff)
            } else {
                activeState = .inactive(.noRecentNotificationUpdates)
            }
        case let .inactive(error) where error == .bluetoothOff:
            activeState = .inactive(.bluetoothOff)
        case let .inactive(error) where error == .disabled || error == .restricted:
            activeState = .inactive(.disabled)
        case let .inactive(error) where error == .notAuthorized:
            activeState = .notAuthorized
        case let .inactive(error) where error == .unknown:
            // Unknown can happen when iOS cannot retrieve the status correctly at this moment.
            // This can happen when the user just switched from the bluetooth settings screen.
            // Don't propagate this state as it only leads to confusion, just maintain the current state
            return self.logDebug("No Update Status Stream as not `.inactive(.unknown)` returned")
        case let .inactive(error) where error == .internalTypeMismatch:
            activeState = .inactive(.disabled)
        case .inactive where !isPushNotificationsEnabled:
            activeState = .inactive(.pushNotifications)
        case .inactive:
            activeState = .inactive(.disabled)
        case .notAuthorized:
            activeState = .notAuthorized
        case .authorizationDenied:
            activeState = .authorizationDenied
        case .restricted:
            activeState = .restricted
        }

        mutableStateStream.update(state: .init(notifiedState: notifiedState, activeState: activeState))
    }

    private var notifiedState: ExposureNotificationState {
        guard let exposureReport = dataController.lastExposure else {
            return .notNotified
        }

        return .notified(exposureReport.date)
    }

    private func requestDiagnosisKeys() -> Single<[DiagnosisKey]> {
        return .create { observer in
            self.exposureManager.getDiagnosisKeys { result in
                switch result {

                case let .success(diagnosisKeys):
                    observer(.success(diagnosisKeys))
                case let .failure(error):
                    observer(.failure(error))
                }
            }
            return Disposables.create()
        }
    }

    private func upload(diagnosisKeys keys: [DiagnosisKey],
                        labConfirmationKey: LabConfirmationKey,
                        completion: @escaping (ExposureControllerUploadKeysResult) -> ()) {
        let mapExposureDataError: (ExposureDataError) -> ExposureControllerUploadKeysResult = { error in
            switch error {
            case .internalError, .networkUnreachable, .serverError:
                // No network request is done (yet), these errors can only mean
                // an internal error
                return .internalError
            case .inactive, .signatureValidationFailed:
                return .inactive
            case .notAuthorized:
                return .notAuthorized
            case .responseCached:
                return .responseCached
            }
        }

        self.dataController
            .upload(diagnosisKeys: keys, labConfirmationKey: labConfirmationKey)
            .subscribe(on: MainScheduler.instance)
            .subscribe(onCompleted: {
                completion(.success)
            }, onError: { error in
                let exposureDataError = error.asExposureDataError
                completion(mapExposureDataError(exposureDataError))
            })
            .disposed(by: disposeBag)
    }

    private func updatePushNotificationState(completion: @escaping () -> ()) {
        userNotificationController.getIsAuthorized { isAuthorized in
            self.isPushNotificationsEnabled = isAuthorized
            completion()
        }
    }

    private let mutableStateStream: MutableExposureStateStreaming
    var exposureManager: ExposureManaging
    private let dataController: ExposureDataControlling
    private var disposeBag = DisposeBag()
    private var keysetFetchProcessCompletable: Completable?
    private let networkStatusStream: NetworkStatusStreaming
    private let cellularDataStream: CellularDataStreaming
    private var isActivated = false
    private var isPushNotificationsEnabled = false
    private let userNotificationController: UserNotificationControlling
    private var updateStream: Completable?
    private var activationCompletable: Completable?
    private let currentAppVersion: String
}

extension LabConfirmationKey: ExposureConfirmationKey {
    var key: String {
        return identifier
    }

    var expiration: Date {
        return validUntil
    }
}
