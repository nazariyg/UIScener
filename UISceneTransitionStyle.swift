public enum UISceneTransitionStyle {

    case system
    case defaultNext
    case defaultUp
    case defaultSet
    case immediateSet
    case sheet

    public var transition: UISceneTransition? {
        switch self {

        case .system:
            return nil

        case .defaultNext:
            let transition =
                UISceneTransition(
                    animationControllerForPresentationType: UIShiftyZoomyAnimationController.self,
                    animationControllerForDismissalType: UIShiftyZoomyAnimationController.self)
            return transition

        case .defaultUp:
            let transition =
                UISceneTransition(
                    animationControllerForPresentationType: UISlidyZoomyAnimationController.self,
                    animationControllerForDismissalType: UISlidyZoomyAnimationController.self)
            return transition

        case .defaultSet:
            let animation =
                UISceneTransition.ChildViewControllerReplacementAnimation(
                    duration: 0.33, options: .transitionCrossDissolve)
            let transition = UISceneTransition(childViewControllerReplacementAnimation: animation)
            return transition

        case .immediateSet:
            return nil

        case .sheet:
            let transition =
                UISceneTransition(
                    animationControllerForPresentationType: UISheetAnimationController.self,
                    animationControllerForDismissalType: UISheetAnimationController.self,
                    presentationControllerType: UISheetPresentationController.self,
                    interactionControllerForDismissalType: UISheetDismissalInteractionController.self)
            return transition

        }

    }

    public var isNext: Bool {
        switch self {
        case .defaultNext:
            return true
        default:
            return false
        }
    }

    public var isUp: Bool {
        switch self {
        case .defaultUp:
            return true
        default:
            return false
        }
    }

    public var isSheet: Bool {
        switch self {
        case .sheet:
            return true
        default:
            return false
        }
    }

}
