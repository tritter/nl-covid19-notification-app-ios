/*
 * Copyright (c) 2020 De Staat der Nederlanden, Ministerie van Volksgezondheid, Welzijn en Sport.
 *  Licensed under the EUROPEAN UNION PUBLIC LICENCE v. 1.2
 *
 *  SPDX-License-Identifier: EUPL-1.2
 */

import UIKit

/// @mockable(history:set=true)
protocol ShareKeyViaPhoneViewControllable: ViewControllable, ThankYouListener, HelpDetailListener {
    var router: ShareKeyViaPhoneRouting? { get set }

    func push(viewController: ViewControllable)
    func set(cardViewController: ViewControllable?)

    func presentInNavigationController(viewController: ViewControllable)
    func dismiss(viewController: ViewControllable)
}

final class ShareKeyViaPhoneRouter: Router<ShareKeyViaPhoneViewControllable>, ShareKeyViaPhoneRouting {

    // MARK: - Initialisation

    init(listener: ShareKeyViaPhoneListener,
         viewController: ShareKeyViaPhoneViewControllable,
         thankYouBuilder: ThankYouBuildable,
         cardBuilder: CardBuildable,
         helpDetailBuilder: HelpDetailBuildable) {
        self.listener = listener
        self.thankYouBuilder = thankYouBuilder
        self.cardBuilder = cardBuilder
        self.helpDetailBuilder = helpDetailBuilder

        super.init(viewController: viewController)

        viewController.router = self
    }

    // MARK: - ShareKeyViaPhoneRouting

    func shareKeyViaPhoneWantsDismissal(shouldDismissViewController: Bool) {
        listener?.shareKeyViaPhoneWantsDismissal(shouldDismissViewController: shouldDismissViewController)
    }
    
    func didUploadCodes(withKey key: ExposureConfirmationKey) {
        guard thankYouViewController == nil else {
            return
        }

        let thankYouViewController = thankYouBuilder.build(withListener: viewController,
                                                           exposureConfirmationKey: key)
        self.thankYouViewController = thankYouViewController

        viewController.push(viewController: thankYouViewController)
    }

    func showInactiveCard(state: ExposureActiveState) {
        let cardTypes: [CardType] = state == .notAuthorized ? [.notAuthorized] : [.exposureOff]
        let cardRouter = cardBuilder.build(listener: nil, types: cardTypes)
        self.cardRouter = cardRouter

        viewController.set(cardViewController: cardRouter.viewControllable)
    }

    func removeInactiveCard() {
        guard cardRouter != nil else {
            return
        }

        viewController.set(cardViewController: nil)
        cardRouter = nil
    }

    func showFAQ() {
        guard helpDetailViewController == nil else {
            return
        }

        let question = HelpQuestion(question: .helpFaqUploadKeysTitle, answer: .helpFaqUploadKeysDescription)
        let controller = helpDetailBuilder.build(withListener: viewController, shouldShowEnableAppButton: false, entry: HelpOverviewEntry.question(question))
        viewController.presentInNavigationController(viewController: controller)

        helpDetailViewController = controller
    }

    func hideFAQ(shouldDismissViewController: Bool) {
        guard let controller = helpDetailViewController else {
            return
        }

        helpDetailViewController = nil

        if shouldDismissViewController {
            viewController.dismiss(viewController: controller)
        }
    }

    // MARK: - Private

    private weak var listener: ShareKeyViaPhoneListener?

    private let thankYouBuilder: ThankYouBuildable
    private var thankYouViewController: ViewControllable?

    private let cardBuilder: CardBuildable
    private var cardRouter: (Routing & CardTypeSettable)?

    private let helpDetailBuilder: HelpDetailBuildable
    private var helpDetailViewController: ViewControllable?
}
