/*
 * Copyright (c) 2020 De Staat der Nederlanden, Ministerie van Volksgezondheid, Welzijn en Sport.
 *  Licensed under the EUROPEAN UNION PUBLIC LICENCE v. 1.2
 *
 *  SPDX-License-Identifier: EUPL-1.2
 */

import ENFoundation
import Lottie
import RxSwift
import SnapKit
import UIKit

/// @mockable
protocol StatusRouting: Routing {}

final class StatusViewController: ViewController, StatusViewControllable, CardListening, Logging {
    // MARK: - StatusViewControllable

    private let interfaceOrientationStream: InterfaceOrientationStreaming
    private let exposureStateStream: ExposureStateStreaming
    private let dataController: ExposureDataControlling
    private let pushNotificationStream: PushNotificationStreaming
    private let applicationController: ApplicationControlling

    private weak var listener: StatusListener?
    private weak var topAnchor: NSLayoutYAxisAnchor?

    private var disposeBag = DisposeBag()

    private let cardBuilder: CardBuildable
    private lazy var cardRouter: Routing & CardTypeSettable = {
        cardBuilder.build(listener: self, types: [.bluetoothOff])
    }()

    private var pauseTimer: Timer?
    private let notifiedShouldShowCardDaysThreshold = 14

    init(exposureStateStream: ExposureStateStreaming,
         interfaceOrientationStream: InterfaceOrientationStreaming,
         cardBuilder: CardBuildable,
         listener: StatusListener,
         theme: Theme,
         topAnchor: NSLayoutYAxisAnchor?,
         dataController: ExposureDataControlling,
         pushNotificationStream: PushNotificationStreaming,
         applicationController: ApplicationControlling) {
        self.exposureStateStream = exposureStateStream
        self.interfaceOrientationStream = interfaceOrientationStream
        self.dataController = dataController
        self.pushNotificationStream = pushNotificationStream
        self.listener = listener
        self.topAnchor = topAnchor
        self.applicationController = applicationController

        self.cardBuilder = cardBuilder

        super.init(theme: theme)
    }

    // MARK: - View Lifecycle

    override func loadView() {
        view = statusView
        view.frame = UIScreen.main.bounds
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        statusView.listener = listener

        showCard(false)
        addChild(cardRouter.viewControllable.uiviewController)
        cardRouter.viewControllable.uiviewController.didMove(toParent: self)

        refreshCurrentState()

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(updateExposureStateView),
                                               name: UIApplication.didBecomeActiveNotification,
                                               object: nil)
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)

        // Ties the top anchor of the view to the top anchor of the main view (outside of the scroll view)
        // to make the view stretch while rubber banding
        if let topAnchor = topAnchor {
            statusView.stretchGuide.topAnchor.constraint(equalTo: topAnchor)
                .withPriority(.defaultHigh - 100)
                .isActive = true
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        updateExposureStateView()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        // Listen for dark mode change to load dark or light animation
        refreshCurrentState()
    }

    // MARK: - Private

    @objc private func updateExposureStateView() {
        exposureStateStream.exposureState
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] _ in
                self?.refreshCurrentState()
            }).disposed(by: disposeBag)

        interfaceOrientationStream.isLandscape.subscribe { [weak self] _ in
            self?.refreshCurrentState()
        }.disposed(by: disposeBag)

        pushNotificationStream.foregroundNotificationStream.subscribe(onNext: { [weak self] notification in
            if notification.requestIdentifier == PushNotificationIdentifier.pauseEnded.rawValue {
                self?.logDebug("Refreshing state due to pauseEnded notification")
                self?.refreshCurrentState()
            }
        }).disposed(by: disposeBag)

        refreshCurrentState()
    }

    private func refreshCurrentState() {
        guard applicationController.isActive() else { return }
        let currentState = exposureStateStream.currentExposureState

        guard let isLandscape = interfaceOrientationStream.currentOrientationIsLandscape else {
            return
        }
        update(exposureState: currentState, isLandscape: isLandscape)
    }

    private func updatePauseTimer() {
        if dataController.isAppPaused {
            if pauseTimer == nil {
                // This timer fires every minute to update the status on the screen. This is needed because in a paused state
                // the status will show a minute-by-minute countdown until the time when the pause state should end
                pauseTimer = Timer.scheduledTimer(withTimeInterval: .minutes(1), repeats: true, block: { [weak self] _ in
                    self?.refreshCurrentState()
                })
            }
        } else {
            pauseTimer?.invalidate()
            pauseTimer = nil
        }
    }

    private func update(exposureState status: ExposureState, isLandscape: Bool) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.updatePauseTimer()
        }

        let statusViewModel: StatusViewModel
        let announcementCardTypes = getAnnouncementCardTypes()
        var cardTypes = [CardType]()

        var notifiedState = status.notifiedState

        // Override notified state if the notification date was more than `notifiedShouldShowCardDaysThreshold` days ago
        if case let .notified(date) = notifiedState,
            currentDate().days(sinceDate: date) ?? 0 > notifiedShouldShowCardDaysThreshold {

            notifiedState = .notNotified

            cardTypes.append(.notifiedMoreThanThresholdDaysAgo(date: date,
                                                               explainRiskHandler: explainRisk,
                                                               removeNotificationHandler: removeNotification))
        }

        switch (status.activeState, notifiedState) {
        case (.active, .notNotified):
            statusViewModel = .activeWithNotNotified(theme: theme, showScene: !isLandscape && announcementCardTypes.isEmpty)
        case let (.inactive(.paused(pauseEndDate)), .notNotified):
            statusViewModel = .pausedWithNotNotified(theme: theme, pauseEndDate: pauseEndDate)
        case let (.active, .notified(date)):
            statusViewModel = StatusViewModel.activeWithNotified(date: date)
        case let (.inactive(reason), .notified(date)):
            statusViewModel = StatusViewModel.inactiveWithNotified(date: date)
            cardTypes.append(reason.cardType(listener: listener))
        case let (.inactive(reason), .notNotified) where reason == .noRecentNotificationUpdates:
            statusViewModel = .inactiveTryAgainWithNotNotified

        case let (.inactive(reason), .notNotified) where reason == .noRecentNotificationUpdatesInternetOff:
            statusViewModel = .internetInactiveWithNotNotified(theme: theme)

        case let (.inactive(reason), .notNotified) where reason == .bluetoothOff:
            statusViewModel = .bluetoothInactiveWithNotNotified(theme: theme)

        case (.inactive, .notNotified):
            statusViewModel = .inactiveWithNotNotified

        case let (.authorizationDenied, .notified(date)):
            statusViewModel = .inactiveWithNotified(date: date)
            cardTypes.append(.exposureOff)

        case (.authorizationDenied, .notNotified):
            statusViewModel = .inactiveWithNotNotified

        case let (.restricted, .notified(date)):
            statusViewModel = .inactiveWithNotified(date: date)
            cardTypes.append(.exposureOff)

        case (.restricted, .notNotified):
            statusViewModel = .inactiveWithNotNotified

        case let (.notAuthorized, .notified(date)):
            statusViewModel = .inactiveWithNotified(date: date)
            cardTypes.append(.exposureOff)

        case (.notAuthorized, .notNotified):
            statusViewModel = .inactiveWithNotNotified
        }

        mainThreadIfNeeded { [weak self] in

            guard let strongSelf = self else {
                return
            }

            strongSelf.statusView.update(with: statusViewModel)

            // Add any non-status related card types and update the CardViewController via the router
            cardTypes.append(contentsOf: announcementCardTypes)
            strongSelf.cardRouter.types = cardTypes

            strongSelf.showCard(!cardTypes.isEmpty)
        }
    }

    private func getAnnouncementCardTypes() -> [CardType] {
        // Add any upcoming announcement cards here
        return []
    }

    private func showCard(_ display: Bool) {
        cardRouter.viewControllable.uiviewController.view.isHidden = !display
    }

    func dismissedAnnouncement() {
        refreshCurrentState()
    }

    @objc private func explainRisk() {
        listener?.handleButtonAction(.explainRisk)
    }

    @objc private func removeNotification() {
        listener?.handleButtonAction(.removeNotification(.warning))
    }

    private lazy var statusView: StatusView = StatusView(theme: self.theme,
                                                         cardView: cardRouter.viewControllable.uiviewController.view)
}

private final class StatusView: View {
    weak var listener: StatusListener?

    fileprivate let stretchGuide = UILayoutGuide() // grows larger while stretching, grows all visible elements
    private let contentStretchGuide = UILayoutGuide() // grows larger while stretching, used to center the content
    private let bottomCardStretchGuide = UILayoutGuide()

    private let contentContainer = UIStackView()
    private let textContainer = UIStackView()
    private let buttonContainer = UIStackView()
    private let bottomCardContainer = UIStackView()
    private let cardView: UIView

    private var iconViewSizeConstraints: Constraint?
    private lazy var iconView: EmitterStatusIconView = {
        EmitterStatusIconView(theme: self.theme)
    }()

    private let titleLabel = Label()
    private let descriptionLabel = Label()

    private let gradientLayer = CAGradientLayer()
    private lazy var cloudsView = CloudView(theme: theme)
    private lazy var starsView = UIImageView(image: .statusStars)
    private lazy var sceneImageView = StatusAnimationView(theme: theme)
    private lazy var sceneImageViewContainer = UIView()

    private var containerToSceneVerticalConstraint: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?
    private var sceneImageHeightConstraint: NSLayoutConstraint?

    private var sceneImageAspectRatio: CGFloat {
        sceneImageView.animation.map { $0.size.height / $0.size.width } ?? 1
    }

    init(theme: Theme, cardView: UIView) {
        self.cardView = cardView

        super.init(theme: theme)
    }

    // MARK: - Overrides

    override func build() {
        super.build()

        /// Initially hide the status. It will become visible after the first update
        showStatus(false)

        starsView.contentMode = .scaleAspectFill
        contentContainer.axis = .vertical
        contentContainer.spacing = 32
        contentContainer.alignment = .center

        textContainer.axis = .vertical
        textContainer.spacing = 16

        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.font = theme.fonts.title2
        titleLabel.numberOfLines = 0
        titleLabel.textAlignment = .center
        titleLabel.accessibilityTraits = .header
        titleLabel.textColor = theme.colors.textPrimary

        descriptionLabel.adjustsFontForContentSizeCategory = true
        descriptionLabel.font = theme.fonts.body
        descriptionLabel.numberOfLines = 0
        descriptionLabel.textAlignment = .center
        descriptionLabel.textColor = theme.colors.textSecondary

        buttonContainer.axis = .vertical
        buttonContainer.spacing = 16

        layer.addSublayer(gradientLayer)
        textContainer.addArrangedSubview(titleLabel)
        textContainer.addArrangedSubview(descriptionLabel)
        contentContainer.addArrangedSubview(iconView)
        contentContainer.addArrangedSubview(textContainer)
        contentContainer.addArrangedSubview(buttonContainer)

        sceneImageViewContainer.addSubview(sceneImageView)

        bottomCardContainer.addArrangedSubview(cardView)

        addSubview(cloudsView)
        addSubview(starsView)
        addSubview(sceneImageViewContainer)
        addSubview(contentContainer)
        addSubview(bottomCardContainer)
        addLayoutGuide(contentStretchGuide)
        addLayoutGuide(stretchGuide)
        addLayoutGuide(bottomCardStretchGuide)
    }

    override func setupConstraints() {
        super.setupConstraints()

        cloudsView.translatesAutoresizingMaskIntoConstraints = false
        starsView.translatesAutoresizingMaskIntoConstraints = false
        sceneImageView.translatesAutoresizingMaskIntoConstraints = false
        sceneImageViewContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        bottomCardContainer.translatesAutoresizingMaskIntoConstraints = false

        heightConstraint = heightAnchor.constraint(equalToConstant: 0).withPriority(.defaultHigh + 100)

        sceneImageHeightConstraint = sceneImageView.heightAnchor.constraint(equalToConstant: UIScreen.main.bounds.width * sceneImageAspectRatio)
        sceneImageHeightConstraint?.isActive = true

        starsView.snp.makeConstraints { maker in
            maker.bottom.equalTo(iconView.snp.centerY)
            maker.leading.trailing.equalTo(stretchGuide).inset(20)
        }
        cloudsView.snp.makeConstraints { maker in
            maker.centerY.equalTo(iconView.snp.centerY)
            maker.leading.trailing.equalTo(stretchGuide)
        }
        sceneImageViewContainer.snp.makeConstraints { maker in
            maker.top.equalTo(contentStretchGuide.snp.bottom).inset(48)
            maker.leading.trailing.equalTo(stretchGuide)
            maker.centerX.equalTo(stretchGuide)
        }
        sceneImageView.snp.makeConstraints { maker in
            maker.leading.trailing.top.bottom.equalToSuperview()
        }
        stretchGuide.snp.makeConstraints { maker in
            maker.leading.trailing.equalTo(contentStretchGuide).inset(-16)

            maker.top.equalTo(contentStretchGuide).inset(-86)
            maker.bottom.greaterThanOrEqualTo(contentStretchGuide.snp.bottom)
            maker.leading.trailing.bottom.equalToSuperview()
            maker.top.equalToSuperview().priority(.low)
        }
        contentStretchGuide.snp.makeConstraints { maker in
            maker.leading.trailing.centerY.equalTo(contentContainer)
            maker.height.greaterThanOrEqualTo(contentContainer.snp.height)
            maker.bottom.equalTo(stretchGuide.snp.bottom).priority(.high)
        }
        iconView.snp.makeConstraints { maker in
            iconViewSizeConstraints = maker.width.height.equalTo(48).constraint
        }

        bottomCardStretchGuide.snp.makeConstraints { maker in
            maker.top.equalTo(stretchGuide.snp.top)
            maker.leading.equalTo(stretchGuide).offset(16)
            maker.trailing.equalTo(stretchGuide).offset(-16)
            maker.bottom.equalTo(stretchGuide.snp.bottom)
        }

        bottomCardContainer.snp.makeConstraints { maker in
            maker.top.equalTo(sceneImageViewContainer.snp.bottom)
            maker.leading.trailing.equalTo(bottomCardStretchGuide)
            maker.bottom.equalTo(stretchGuide)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.frame = stretchGuide.layoutFrame
        CATransaction.commit()

        evaluateImageSize()
        evaluateHeight()
    }

    // MARK: - Internal

    func update(with viewModel: StatusViewModel) {

        iconViewSizeConstraints?.layoutConstraints.forEach { constraint in
            // if the emitter animation is not shown, we use a slightly larger main icon
            constraint.constant = viewModel.showEmitter ? 48 : 56
        }
        iconView.update(with: viewModel.icon, showEmitter: viewModel.showEmitter)
        iconView.setNeedsLayout()

        titleLabel.attributedText = viewModel.title
        descriptionLabel.attributedText = viewModel.description

        buttonContainer.subviews.forEach { $0.removeFromSuperview() }
        for buttonModel in viewModel.buttons {
            let button = Button(title: buttonModel.title, theme: theme)
            button.contentEdgeInsets = UIEdgeInsets(top: 14, left: 24, bottom: 14, right: 24)
            button.titleEdgeInsets = UIEdgeInsets(top: 3, left: 0, bottom: 3, right: 0)
            button.style = buttonModel.style
            button.rounded = true
            button.action = { [weak self] in
                self?.listener?.handleButtonAction(buttonModel.action)
            }
            buttonContainer.addArrangedSubview(button)
        }
        buttonContainer.isHidden = viewModel.buttons.isEmpty

        gradientLayer.colors = [
            theme.colors[keyPath: viewModel.gradientTopColor].cgColor,
            theme.colors[keyPath: viewModel.gradientBottomColor].cgColor
        ]

        sceneImageView.isHidden = !viewModel.showScene
        cloudsView.isHidden = !(viewModel.showSky && !theme.darkModeEnabled)
        starsView.isHidden = !(viewModel.showSky && theme.darkModeEnabled && viewModel.showScene)
        gradientLayer.isHidden = theme.darkModeEnabled && starsView.isHidden

        evaluateHeight()
        evaluateImageSize()

        showStatus(true)
    }

    // MARK: - Private

    /// Calculates the desired height for the current content
    /// This is required for stretching
    private func evaluateHeight() {
        guard bounds.width > 0 else { return }

        heightConstraint?.isActive = false
        let size = systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        heightConstraint?.constant = size.height
        heightConstraint?.isActive = true
    }

    /// Manually adjusts sceneImage height constraint after layout pass
    private func evaluateImageSize() {
        if sceneImageView.isHidden {
            // If the scene is hidden we still give it a size to push other content (such as cards) lower
            sceneImageHeightConstraint?.constant = 75
        } else {
            sceneImageHeightConstraint?.constant = UIScreen.main.bounds.width * sceneImageAspectRatio
        }
    }

    private func showStatus(_ show: Bool) {
        titleLabel.alpha = show ? 1 : 0
        descriptionLabel.alpha = show ? 1 : 0
        iconView.alpha = show ? 1 : 0
    }
}

private extension ExposureStateInactiveState {
    func cardType(listener: StatusListener?) -> CardType {
        switch self {
        case .paused:
            return .paused
        case .bluetoothOff:
            return .bluetoothOff
        case .disabled:
            return .exposureOff
        case .noRecentNotificationUpdates:
            return .noInternet(retryHandler: {
                listener?.handleButtonAction(.tryAgain)
            })
        case .noRecentNotificationUpdatesInternetOff:
            return .noInternetFor24Hours
        case .pushNotifications:
            return .noLocalNotifications
        }
    }
}

private final class StatusAnimationView: View {
    private lazy var animationView = AnimationView()
    fileprivate var animation: Animation? { animationView.animation }

    deinit {
        replayTimer?.invalidate()
        replayTimer = nil
    }

    override func build() {
        super.build()
        backgroundColor = .clear

        loadAnimation()
        playAnimation()

        addSubview(animationView)
    }

    override func setupConstraints() {
        super.setupConstraints()

        animationView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        loadAnimation()
    }

    private func loadAnimation() {
        animationView.animation = LottieAnimation.named(theme.appearanceAdjustedAnimationName("statusactive"))
        animationView.loopMode = .playOnce
    }

    // MARK: - Private

    private var replayTimer: Timer?

    private func scheduleReplayTimer() {
        replayTimer?.invalidate()

        let randomDelay = arc4random_uniform(5) + 10
        replayTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(randomDelay),
                                           repeats: false,
                                           block: { [weak self] _ in
                                               self?.playAnimation()
                                           })
    }

    private func playAnimation() {
        #if DEBUG

            if let animationsEnabled = AnimationTestingOverrides.animationsEnabled, !animationsEnabled {
                return
            }

        #endif

        if animationsEnabled() {
            animationView.play { [weak self] _ in
                self?.scheduleReplayTimer()
            }
        }
    }
}
