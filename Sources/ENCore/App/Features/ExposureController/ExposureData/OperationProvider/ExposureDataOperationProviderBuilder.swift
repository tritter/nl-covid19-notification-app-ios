/*
 * Copyright (c) 2020 De Staat der Nederlanden, Ministerie van Volksgezondheid, Welzijn en Sport.
 *  Licensed under the EUROPEAN UNION PUBLIC LICENCE v. 1.2
 *
 *  SPDX-License-Identifier: EUPL-1.2
 */

/// @mockable(history: processPendingLabConfirmationUploadRequestsOperation = true)
protocol ExposureDataOperationProvider {
    func processExposureKeySetsOperation(exposureManager: ExposureManaging,
                                         exposureDataController: ExposureDataController,
                                         configuration: ExposureConfiguration) -> ProcessExposureKeySetsDataOperationProtocol

    func processPendingLabConfirmationUploadRequestsOperation(padding: Padding) -> ProcessPendingLabConfirmationUploadRequestsDataOperationProtocol
    func expiredLabConfirmationNotificationOperation() -> ExpiredLabConfirmationNotificationDataOperationProtocol
    func requestAppConfigurationOperation(identifier: String) -> RequestAppConfigurationDataOperationProtocol
    func requestExposureConfigurationOperation(identifier: String) -> RequestExposureConfigurationDataOperationProtocol
    func requestExposureKeySetsOperation(identifiers: [String]) -> RequestExposureKeySetsDataOperationProtocol

    var requestManifestOperation: RequestAppManifestDataOperationProtocol { get }
    var updateTreatmentPerspectiveDataOperation: UpdateTreatmentPerspectiveDataOperationProtocol { get }
    func requestLabConfirmationKeyOperation(padding: Padding) -> RequestLabConfirmationKeyDataOperationProtocol

    func uploadDiagnosisKeysOperation(diagnosisKeys: [DiagnosisKey],
                                      labConfirmationKey: LabConfirmationKey,
                                      padding: Padding) -> UploadDiagnosisKeysDataOperationProtocol
}

protocol ExposureDataOperationProviderBuildable {
    func build() -> ExposureDataOperationProvider
}

protocol ExposureDataOperationProviderDependency {
    var networkController: NetworkControlling { get }
    var storageController: StorageControlling { get }
    var applicationSignatureController: ApplicationSignatureControlling { get }
}

private final class ExposureDataOperationProviderDependencyProvider: DependencyProvider<ExposureDataOperationProviderDependency> {
    var localPathProvider: LocalPathProviding {
        return LocalPathProvider(fileManager: FileManager.default)
    }

    var userNotificationController: UserNotificationControlling {
        return UserNotificationController(storageController: dependency.storageController)
    }

    var application: ApplicationControlling {
        return ApplicationController()
    }

    var fileManager: FileManaging {
        return FileManager.default
    }

    var environmentController: EnvironmentControlling {
        return EnvironmentController()
    }

    var riskCalculationController: RiskCalculationControlling {
        RiskCalculationController()
    }

    var keySetDownloadProcessor: KeySetDownloadProcessing {
        return KeySetDownloadProcessor(storageController: dependency.storageController,
                                       localPathProvider: localPathProvider,
                                       fileManager: fileManager)
    }
}

final class ExposureDataOperationProviderBuilder: Builder<ExposureDataOperationProviderDependency>, ExposureDataOperationProviderBuildable {
    func build() -> ExposureDataOperationProvider {
        let dependencyProvider = ExposureDataOperationProviderDependencyProvider(dependency: dependency)

        return ExposureDataOperationProviderImpl(networkController: dependencyProvider.dependency.networkController,
                                                 storageController: dependencyProvider.dependency.storageController,
                                                 applicationSignatureController: dependencyProvider.dependency.applicationSignatureController,
                                                 localPathProvider: dependencyProvider.localPathProvider,
                                                 userNotificationController: dependencyProvider.userNotificationController,
                                                 application: dependencyProvider.application,
                                                 fileManager: dependencyProvider.fileManager,
                                                 environmentController: dependencyProvider.environmentController,
                                                 riskCalculationController: dependencyProvider.riskCalculationController,
                                                 keySetDownloadProcessor: dependencyProvider.keySetDownloadProcessor)
    }
}
