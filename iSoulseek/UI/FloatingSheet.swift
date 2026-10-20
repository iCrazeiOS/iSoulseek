import UIKit

/// A controller that can be shown as a floating card by `FloatingSheetTransitioningDelegate`.
protocol FloatingSheetContent: UIViewController {
    /// The height the card would like at the given width. The presentation clamps it to the
    /// space available above the keyboard and scrolls the content when it does not fit.
    func preferredSheetHeight(forWidth width: CGFloat) -> CGFloat
}

/// Presents a controller as a rounded card floating above the bottom of the screen, with a
/// dimmed backdrop, a drag-to-dismiss handle area and keyboard avoidance.
final class FloatingSheetTransitioningDelegate: NSObject, UIViewControllerTransitioningDelegate {

    func presentationController(forPresented presented: UIViewController, presenting: UIViewController?,
                                source: UIViewController) -> UIPresentationController? {
        FloatingSheetPresentationController(presentedViewController: presented, presenting: presenting)
    }

    func animationController(forPresented presented: UIViewController, presenting: UIViewController,
                             source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        FloatingSheetAnimator(isPresenting: true)
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        FloatingSheetAnimator(isPresenting: false)
    }
}

/// Animates the card up from the bottom edge without touching its size or corner radius.
private final class FloatingSheetAnimator: NSObject, UIViewControllerAnimatedTransitioning {

    private let isPresenting: Bool

    init(isPresenting: Bool) {
        self.isPresenting = isPresenting
    }

    func transitionDuration(using context: UIViewControllerContextTransitioning?) -> TimeInterval {
        UIAccessibility.isReduceMotionEnabled ? 0.2 : 0.42
    }

    func animateTransition(using context: UIViewControllerContextTransitioning) {
        let key: UITransitionContextViewControllerKey = isPresenting ? .to : .from
        guard let controller = context.viewController(forKey: key) else {
            context.completeTransition(false)
            return
        }

        let view = controller.view!
        let container = context.containerView
        let duration = transitionDuration(using: context)

        if isPresenting {
            view.frame = context.finalFrame(for: controller)
            container.addSubview(view)
        }

        let hidden = CGAffineTransform(translationX: 0, y: container.bounds.height)

        if UIAccessibility.isReduceMotionEnabled {
            view.alpha = isPresenting ? 0 : 1
            UIView.animate(withDuration: duration) {
                view.alpha = self.isPresenting ? 1 : 0
            } completion: { _ in
                context.completeTransition(!context.transitionWasCancelled)
            }
            return
        }

        if isPresenting {
            view.transform = hidden
            UIView.animate(withDuration: duration, delay: 0,
                           usingSpringWithDamping: 0.9, initialSpringVelocity: 0.4,
                           options: [.allowUserInteraction, .curveEaseOut]) {
                view.transform = .identity
            } completion: { _ in
                context.completeTransition(!context.transitionWasCancelled)
            }
        } else {
            UIView.animate(withDuration: duration, delay: 0,
                           options: [.allowUserInteraction, .curveEaseIn]) {
                view.transform = view.transform.concatenating(hidden)
            } completion: { _ in
                context.completeTransition(!context.transitionWasCancelled)
            }
        }
    }
}

private final class FloatingSheetPresentationController: UIPresentationController {

    private enum Metrics {
        static let sideMargin: CGFloat = 16
        static let bottomMargin: CGFloat = 16
        static let maximumWidth: CGFloat = 560
        static let dragAreaHeight: CGFloat = 36
        static let dimAlpha: CGFloat = 0.4
    }

    private let dimmingView = UIView()
    private var keyboardOverlap: CGFloat = 0
    private var isDragging = false

    private lazy var dismissTap = UITapGestureRecognizer(target: self, action: #selector(dismissSheet))
    private lazy var dragPan = UIPanGestureRecognizer(target: self, action: #selector(handleDrag))

    override var frameOfPresentedViewInContainerView: CGRect {
        guard let container = containerView else { return .zero }

        let width = min(container.bounds.width - Metrics.sideMargin * 2, Metrics.maximumWidth)
        let desired = (presentedViewController as? FloatingSheetContent)?
            .preferredSheetHeight(forWidth: width) ?? 400

        let top = container.safeAreaInsets.top + 16
        let bottom = keyboardOverlap > 0
            ? container.bounds.height - keyboardOverlap - 12
            : container.bounds.height - container.safeAreaInsets.bottom - Metrics.bottomMargin
        let height = min(desired, max(bottom - top, 180))

        return CGRect(x: (container.bounds.width - width) / 2, y: bottom - height,
                      width: width, height: height)
    }

    override func presentationTransitionWillBegin() {
        guard let container = containerView else { return }

        dimmingView.frame = container.bounds
        dimmingView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dimmingView.backgroundColor = .clear
        dimmingView.addGestureRecognizer(dismissTap)
        container.addSubview(dimmingView)

        if let presentedView {
            presentedView.accessibilityViewIsModal = true
            dragPan.delegate = self
            presentedView.addGestureRecognizer(dragPan)
        }

        observeKeyboard()
        UIView.animate(withDuration: 0.3) {
            self.dimmingView.backgroundColor = UIColor.black.withAlphaComponent(Metrics.dimAlpha)
        }
    }

    override func presentationTransitionDidEnd(_ completed: Bool) {
        if !completed { dimmingView.removeFromSuperview() }
    }

    override func dismissalTransitionWillBegin() {
        UIView.animate(withDuration: 0.25) {
            self.dimmingView.backgroundColor = .clear
        }
    }

    override func dismissalTransitionDidEnd(_ completed: Bool) {
        if completed { dimmingView.removeFromSuperview() }
        NotificationCenter.default.removeObserver(self)
    }

    override func containerViewWillLayoutSubviews() {
        super.containerViewWillLayoutSubviews()
        guard let container = containerView else { return }
        dimmingView.frame = container.bounds
        if !isDragging {
            presentedView?.frame = frameOfPresentedViewInContainerView
        }
    }

    // MARK: Keyboard

    private func observeKeyboard() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(keyboardFrameChanged),
                           name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardFrameChanged),
                           name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    @objc private func keyboardFrameChanged(_ notification: Notification) {
        guard let container = containerView else { return }

        if notification.name == UIResponder.keyboardWillHideNotification {
            keyboardOverlap = 0
        } else if let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
            let converted = container.convert(frame, from: nil)
            keyboardOverlap = max(0, container.bounds.maxY - converted.minY)
        }

        let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval
            ?? 0.25
        UIView.animate(withDuration: duration) { container.layoutIfNeeded() }
    }

    // MARK: Dismissal

    @objc private func dismissSheet() {
        presentedViewController.dismiss(animated: true)
    }

    @objc private func handleDrag(_ pan: UIPanGestureRecognizer) {
        guard let presentedView, let container = containerView else { return }

        let translation = max(0, pan.translation(in: container).y)
        let progress = min(1, translation / max(presentedView.bounds.height, 1))

        switch pan.state {
        case .began:
            isDragging = true
            dimmingView.layer.removeAllAnimations()

        case .changed:
            presentedView.transform = CGAffineTransform(translationX: 0, y: translation)
            dimmingView.backgroundColor = UIColor.black.withAlphaComponent(Metrics.dimAlpha * (1 - progress))

        case .ended, .cancelled:
            let velocity = pan.velocity(in: container).y
            if translation > 100 || velocity > 900 {
                presentedViewController.dismiss(animated: true)
            } else {
                isDragging = false
                UIView.animate(withDuration: 0.32, delay: 0,
                               usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
                    presentedView.transform = .identity
                    self.dimmingView.backgroundColor = UIColor.black.withAlphaComponent(Metrics.dimAlpha)
                }
            }

        default:
            break
        }
    }
}

extension FloatingSheetPresentationController: UIGestureRecognizerDelegate {

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === dragPan, let view = presentedView else { return true }
        // Only the header area drags the card, so the scroll view keeps its own vertical pans.
        return gestureRecognizer.location(in: view).y <= Metrics.dragAreaHeight
    }
}
