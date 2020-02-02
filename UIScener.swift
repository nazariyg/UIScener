/// `UIScener` manages transitions between scenes with support for transition styles and tabs.
///
/// A "next" transition corresponds to pushing a view controller into a navigation controller, while an "up" transition corresponds to
/// a view controller being presented over another one. A "set" transition corresponds to replacing a root view controller with another
/// root view controller.
///
/// The view controller of every presented scene is automatically embedded into an `UIEmbeddingNavigationController` for that scene to
/// be able to make "next" (push) transitions further on, with the navigation bar hidden by default.

// MARK: - Protocol

public protocol UIScenerProtocol {

    func initialize(initialSceneType: UIInitialScene.Type)
    func initialize(initialSceneType: UIInitialScene.Type, completion: VoidClosure?)
    func initialize(tabsControllerType: UITabsController.Type, initialSceneTypes: [UIInitialScene.Type], initialTabIndex: Int)
    func initialize(tabsControllerType: UITabsController.Type, initialSceneTypes: [UIInitialScene.Type], initialTabIndex: Int, completion: VoidClosure?)

    func next<Scene: UIScene>(_: Scene.Type, parameters: Scene.Parameters?)
    func next<Scene: UIScene>(_: Scene.Type, parameters: Scene.Parameters?, transitionStyle: UISceneTransitionStyle)
    func next<Scene: UIScene>(_: Scene.Type, parameters: Scene.Parameters?, transitionStyle: UISceneTransitionStyle, completion: VoidClosure?)

    func up<Scene: UIScene>(_: Scene.Type, parameters: Scene.Parameters?)
    func up<Scene: UIScene>(_: Scene.Type, parameters: Scene.Parameters?, transitionStyle: UISceneTransitionStyle)
    func up<Scene: UIScene>(_: Scene.Type, parameters: Scene.Parameters?, transitionStyle: UISceneTransitionStyle, completion: VoidClosure?)

    func set<Scene: UIInitialScene>(_: Scene.Type)
    func set<Scene: UIInitialScene>(_: Scene.Type, transitionStyle: UISceneTransitionStyle)
    func set<Scene: UIInitialScene>(_: Scene.Type, completion: VoidClosure?)
    func set<Scene: UIInitialScene>(_: Scene.Type, transitionStyle: UISceneTransitionStyle, completion: VoidClosure?)
    func set<Scene: UIScene>(_: Scene.Type, parameters: Scene.Parameters?)
    func set<Scene: UIScene>(_: Scene.Type, parameters: Scene.Parameters?, transitionStyle: UISceneTransitionStyle)
    func set<Scene: UIScene>(_: Scene.Type, parameters: Scene.Parameters?, completion: VoidClosure?)
    func set<Scene: UIScene>(_: Scene.Type, parameters: Scene.Parameters?, transitionStyle: UISceneTransitionStyle, completion: VoidClosure?)
    func set(tabsControllerType: UITabsController.Type, initialSceneTypes: [UIInitialScene.Type], initialTabIndex: Int)
    func set(tabsControllerType: UITabsController.Type, initialSceneTypes: [UIInitialScene.Type], initialTabIndex: Int, completion: @escaping VoidClosure)
    func set(
        tabsControllerType: UITabsController.Type, initialSceneTypes: [UIInitialScene.Type], initialTabIndex: Int, transitionStyle: UISceneTransitionStyle,
        completion: VoidClosure?)

    func tab(tabIndex: Int)
    var currentTabIndex: Int { get }

    func back()
    func back(completion: VoidClosure?)
    func backTo<Scene: UISceneBase>(_: Scene.Type)

    var currentScene: UISceneBase { get }

    // Invoked by custom presentation controllers when the user finishes dismissing a scene interactively, which involves the use of
    // `UIInteractablePresentationController` protocol, so that the `UIScener` could update its state of stacked scenes.
    func _popSceneIfNeeded(ifContainsViewController viewController: UIViewController)

    // Invoked by `UIEmbeddingNavigationController` when an pushed scene is being dismissed via the native back button, without calling
    // any of dismissal methods of the `UIScener` directly, so that the `UIScener` could update its state of stacked scenes.
    func _popSceneIfNeeded(ifContainsNavigationItem navigationItem: UINavigationItem)

}

// MARK: - Implementation

private let logCategory = "UI"

public final class UIScener: UIScenerProtocol, SharedInstance {

    // DI.
    public typealias InstanceProtocol = UIScenerProtocol
    public static func defaultInstance() -> InstanceProtocol { return UIScener() }
    public static let isSharedInstanceResettable = false

    private var currentTabIndex = 0  // always `0` if there are no tabs

    private var sceneNodeStack: [[SceneNode]] = []
    private weak var tabsController: UITabsController?
    private var currentlyActiveTransition: UISceneTransition?
    private var sceneTransitionQueue = RecursiveSerialQueue(qos: Config.shared.general.uiRelatedBackgroundQueueQoS)
    private let disposeBag = Db()

    // MARK: - Lifecycle

    private init() {}

    // MARK: - Initializing with scene types to be shown initially and for which no parameters are required

    /// Initializes the scener with an initial scene.
    public func initialize(initialSceneType: UIInitialScene.Type) {
        initialize(initialSceneType: initialSceneType, completion: nil)
    }

    /// Initializes the scener with an initial scene, calling a completion closure afterwards.
    public func initialize(initialSceneType: UIInitialScene.Type, completion: VoidClosure?) {
        sceneTransitionQueue.sync {
            sceneTransitionQueue.suspend()

            DispatchQueue.main.syncSafe {
                log.info("Initializing the UI with \(stringType(initialSceneType))", logCategory)

                let initialScene = initialSceneType.init()

                let rootViewController = Self.embedInNavigationControllerIfNeeded(initialScene.viewController)

                let sceneNode = SceneNode(type: .root, scene: initialScene, viewController: rootViewController, transitionStyle: nil)
                sceneNodeStack = [[sceneNode]]

                UIRootContainer.shared.setRootViewController(rootViewController, completion: { [weak self] in
                    DispatchQueue.main.async {
                        completion?()
                    }
                    self?.sceneTransitionQueue.resume()
                })
            }
        }
    }

    /// Initializes the scener with a set of initial scenes supervised by a tab controller.
    public func initialize(tabsControllerType: UITabsController.Type, initialSceneTypes: [UIInitialScene.Type], initialTabIndex: Int) {
        initialize(tabsControllerType: tabsControllerType, initialSceneTypes: initialSceneTypes, initialTabIndex: initialTabIndex, completion: nil)
    }

    /// Initializes the scener with a set of initial scenes supervised by a tab controller, calling a completion closure afterwards.
    public func initialize(
        tabsControllerType: UITabsController.Type, initialSceneTypes: [UIInitialScene.Type], initialTabIndex: Int, completion: VoidClosure?) {

        sceneTransitionQueue.sync {
            sceneTransitionQueue.suspend()

            DispatchQueue.main.syncSafe {
                log.info("Initializing the UI with \(stringType(tabsControllerType))", logCategory)

                let initialScenes = initialSceneTypes.map { sceneType in sceneType.init() }
                let viewControllers = initialScenes.map { scene in Self.embedInNavigationControllerIfNeeded(scene.viewController) }

                let tabsController = tabsControllerType.init()
                tabsController.viewControllers = viewControllers
                tabsController.selectedIndex = initialTabIndex
                self.tabsController = tabsController

                sceneNodeStack =
                    initialScenes.enumerated().map { index, scene in
                        return [SceneNode(type: .root, scene: scene, viewController: viewControllers[index], transitionStyle: nil)]
                    }
                currentTabIndex = initialTabIndex

                UIRootContainer.shared.setRootViewController(tabsController as! UIViewController, transitionStyle: .immediateSet,
                    completion: { [weak self] in
                        DispatchQueue.main.async {
                            completion?()
                        }
                        self?.sceneTransitionQueue.resume()
                    })
            }
        }
    }

    // MARK: - "Next" transitions

    /// Makes a "next" transition to a scene using the default transition style.
    public func next<Scene: UIScene>(_: Scene.Type, parameters: Scene.Parameters?) {
        next(Scene.self, parameters: parameters, transitionStyle: .defaultNext)
    }

    /// Makes a "next" transition to a scene using a specific transition style.
    public func next<Scene: UIScene>(_: Scene.Type, parameters: Scene.Parameters?, transitionStyle: UISceneTransitionStyle) {
        next(Scene.self, parameters: parameters, transitionStyle: transitionStyle, completion: nil)
    }

    /// Makes a "next" transition to a scene using a specific transition style, calling a completion closure afterwards.
    public func next<Scene: UIScene>(_: Scene.Type, parameters: Scene.Parameters?, transitionStyle: UISceneTransitionStyle, completion: VoidClosure?) {
        sceneTransitionQueue.async { [weak self] in
            guard let self = self else { return }
            self.sceneTransitionQueue.suspend()

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }

                guard let navigationController = self.currentSceneNode.scene.viewController.navigationController else {
                    assertionFailure()
                    return
                }

                let scene = Scene(parameters: parameters)
                let viewController = scene.viewController

                if !transitionStyle.isSheet {
                    if let currentBaseViewController = self.currentSceneNode.scene.viewController as? UIViewControllerBase,
                       let nextBaseViewController = viewController as? UIViewControllerBase {

                        if currentBaseViewController.displaysTabBar != nextBaseViewController.displaysTabBar {
                            if let tabsController = self.tabsController {
                                if currentBaseViewController.displaysTabBar {
                                    currentBaseViewController.tabBarWillHide()
                                }
                                if nextBaseViewController.displaysTabBar {
                                    tabsController.showTabBar()
                                } else {
                                    tabsController.hideTabBar()
                                }
                            }
                        }
                    }
                }

                let sceneNode = SceneNode(type: .next, scene: scene, viewController: viewController, transitionStyle: transitionStyle)
                self.pushSceneNode(sceneNode)

                log.info("Making a \"next\" transition to \(stringType(Scene.self))", logCategory)

                self.makeNextTransition(
                    navigationController: navigationController, viewController: viewController, toScenes: [scene], transition: sceneNode.cachedTransition,
                    completion: { [weak self] in
                        DispatchQueue.main.async {
                            completion?()
                        }
                        self?.sceneTransitionQueue.resume()
                    })
            }
        }
    }

    // MARK: - "Up" transitions

    /// Makes an "up" transition to a scene using the default transition style.
    public func up<Scene: UIScene>(_: Scene.Type, parameters: Scene.Parameters?) {
        up(Scene.self, parameters: parameters, transitionStyle: .defaultUp)
    }

    /// Makes an "up" transition to a scene using a specific transition style.
    public func up<Scene: UIScene>(_: Scene.Type, parameters: Scene.Parameters?, transitionStyle: UISceneTransitionStyle) {
        up(Scene.self, parameters: parameters, transitionStyle: transitionStyle, completion: nil)
    }

    /// Makes an "up" transition to a scene using a specific transition style, calling a completion closure afterwards.
    public func up<Scene: UIScene>(_: Scene.Type, parameters: Scene.Parameters?, transitionStyle: UISceneTransitionStyle, completion: VoidClosure?) {
        sceneTransitionQueue.async { [weak self] in
            guard let self = self else { return }
            self.sceneTransitionQueue.suspend()

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }

                let scene = Scene(parameters: parameters)
                let viewController = Self.embedInNavigationControllerIfNeeded(scene.viewController)

                if !transitionStyle.isSheet {
                    if let currentBaseViewController = self.currentSceneNode.scene.viewController as? UIViewControllerBase,
                       let nextBaseViewController = scene.viewController as? UIViewControllerBase {

                        if currentBaseViewController.displaysTabBar != nextBaseViewController.displaysTabBar {
                            if let tabsController = self.tabsController {
                                if currentBaseViewController.displaysTabBar {
                                    currentBaseViewController.tabBarWillHide()
                                }
                                if nextBaseViewController.displaysTabBar {
                                    tabsController.showTabBar()
                                } else {
                                    tabsController.hideTabBar()
                                }
                            }
                        }
                    }
                }

                let sceneNode = SceneNode(type: .up, scene: scene, viewController: viewController, transitionStyle: transitionStyle)
                let currentScene = self.currentSceneNode.scene
                self.pushSceneNode(sceneNode)

                log.info("Making an \"up\" transition to \(stringType(Scene.self))", logCategory)

                self.makeUpTransition(
                    viewController: viewController, fromScene: currentScene, toScenes: [scene], transition: sceneNode.cachedTransition,
                    completion: { [weak self] in
                        DispatchQueue.main.async {
                            completion?()
                        }
                        self?.sceneTransitionQueue.resume()
                    })
            }
        }
    }

    // MARK: - "Set" transitions

    /// Makes a "set" transition to a scene using the default transition style.
    public func set<Scene: UIInitialScene>(_: Scene.Type) {
        set(Scene.self, transitionStyle: .defaultSet, completion: nil)
    }

    /// Makes a "set" transition to a scene using a specific transition style.
    public func set<Scene: UIInitialScene>(_: Scene.Type, transitionStyle: UISceneTransitionStyle) {
        set(Scene.self, transitionStyle: transitionStyle, completion: nil)
    }

    /// Makes a "set" transition to a scene, calling a completion closure afterwards.
    public func set<Scene: UIInitialScene>(_: Scene.Type, completion: VoidClosure?) {
        set(Scene.self, transitionStyle: .defaultSet, completion: completion)
    }

    /// Makes a "set" transition to a scene using a specific transition style, calling a completion closure afterwards.
    public func set<Scene: UIInitialScene>(_: Scene.Type, transitionStyle: UISceneTransitionStyle, completion: VoidClosure?) {
        sceneTransitionQueue.async { [weak self] in
            guard let self = self else { return }
            self.sceneTransitionQueue.suspend()

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }

                if let presentedViewController = UIRootContainer.shared.presentedViewController {
                    presentedViewController.dismiss(animated: false, completion: nil)
                }

                let scene = Scene()

                self.currentlyActiveTransition = nil

                if !transitionStyle.isNext &&
                   !transitionStyle.isUp {

                    log.info("Setting the root scene to \(stringType(Scene.self))", logCategory)

                    let rootViewController = Self.embedInNavigationControllerIfNeeded(scene.viewController)

                    let sceneNode = SceneNode(type: .root, scene: scene, viewController: rootViewController, transitionStyle: nil)
                    self.sceneNodeStack = [[sceneNode]]
                    self.currentTabIndex = 0

                    scene.sceneIsInitialized
                        .observeOn(Ms.instance)
                        .filter { $0 }
                        .take(1)
                        .subscribe { [weak self] _ in
                            UIRootContainer.shared.setRootViewController(
                                rootViewController, transitionStyle: transitionStyle, completion: { [weak self] in
                                    DispatchQueue.main.async {
                                        completion?()
                                    }
                                    self?.sceneTransitionQueue.resume()
                                })
                        }
                        .disposed(by: self.disposeBag)
                } else {
                    let semiCompletion = { [weak self] in
                        guard let self = self else { return }
                        let transitionStyle: UISceneTransitionStyle = .immediateSet

                        let scene = Scene()

                        log.info("Setting the root scene to \(stringType(Scene.self))", logCategory)

                        let rootViewController = Self.embedInNavigationControllerIfNeeded(scene.viewController)

                        let sceneNode = SceneNode(type: .root, scene: scene, viewController: rootViewController, transitionStyle: nil)
                        self.sceneNodeStack = [[sceneNode]]
                        self.currentTabIndex = 0

                        scene.sceneIsInitialized
                            .observeOn(Ms.instance)
                            .filter { $0 }
                            .take(1)
                            .subscribe { [weak self] _ in
                                UIRootContainer.shared.setRootViewController(
                                    rootViewController, transitionStyle: transitionStyle, completion: { [weak self] in
                                        DispatchQueue.main.async {
                                            completion?()
                                        }
                                        self?.sceneTransitionQueue.resume()
                                    })
                            }
                            .disposed(by: self.disposeBag)
                    }

                    let currentScene = self.currentSceneNode.scene

                    if transitionStyle.isNext {
                        guard let navigationController = currentScene.viewController.navigationController else {
                            assertionFailure()
                            return
                        }
                        let transition = UISceneTransitionStyle.defaultNext.transition
                        self.makeNextTransition(
                            navigationController: navigationController, viewController: scene.viewController, toScenes: [scene], transition: transition,
                            completion: semiCompletion)

                    } else if transitionStyle.isUp {
                        let transition = UISceneTransitionStyle.defaultUp.transition
                        self.makeUpTransition(
                            viewController: scene.viewController, fromScene: currentScene, toScenes: [scene], transition: transition,
                            completion: semiCompletion)
                    }
                }
            }
        }
    }

    /// Makes a "set" transition to a scene using the default transition style.
    public func set<Scene: UIScene>(_: Scene.Type, parameters: Scene.Parameters?) {
        set(Scene.self, parameters: parameters, transitionStyle: .defaultSet, completion: nil)
    }

    /// Makes a "set" transition to a scene using a specific transition style.
    public func set<Scene: UIScene>(_: Scene.Type, parameters: Scene.Parameters?, transitionStyle: UISceneTransitionStyle) {
        set(Scene.self, parameters: parameters, transitionStyle: transitionStyle, completion: nil)
    }

    /// Makes a "set" transition to a scene, calling a completion closure afterwards.
    public func set<Scene: UIScene>(_: Scene.Type, parameters: Scene.Parameters?, completion: VoidClosure?) {
        set(Scene.self, parameters: parameters, transitionStyle: .defaultSet, completion: completion)
    }

    /// Makes a "set" transition to a scene using a specific transition style, calling a completion closure afterwards.
    public func set<Scene: UIScene>(_: Scene.Type, parameters: Scene.Parameters?, transitionStyle: UISceneTransitionStyle, completion: VoidClosure?) {
        sceneTransitionQueue.async { [weak self] in
            guard let self = self else { return }
            self.sceneTransitionQueue.suspend()

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }

                if let presentedViewController = UIRootContainer.shared.presentedViewController {
                    presentedViewController.dismiss(animated: false, completion: nil)
                }

                let scene = Scene(parameters: parameters)

                self.currentlyActiveTransition = nil

                if !transitionStyle.isNext &&
                   !transitionStyle.isUp {

                    log.info("Setting the root scene to \(stringType(Scene.self))", logCategory)

                    let rootViewController = Self.embedInNavigationControllerIfNeeded(scene.viewController)

                    let sceneNode = SceneNode(type: .root, scene: scene, viewController: rootViewController, transitionStyle: nil)
                    self.sceneNodeStack = [[sceneNode]]
                    self.currentTabIndex = 0

                    scene.sceneIsInitialized
                        .observeOn(Ms.instance)
                        .filter { $0 }
                        .take(1)
                        .subscribe { [weak self] _ in
                            UIRootContainer.shared.setRootViewController(
                                rootViewController, transitionStyle: transitionStyle, completion: { [weak self] in
                                    DispatchQueue.main.async {
                                        completion?()
                                    }
                                    self?.sceneTransitionQueue.resume()
                                })
                        }
                        .disposed(by: self.disposeBag)
                } else {
                    let semiCompletion = { [weak self] in
                        guard let self = self else { return }
                        let transitionStyle: UISceneTransitionStyle = .immediateSet

                        let scene = Scene(parameters: parameters)

                        log.info("Setting the root scene to \(stringType(Scene.self))", logCategory)

                        let rootViewController = Self.embedInNavigationControllerIfNeeded(scene.viewController)

                        let sceneNode = SceneNode(type: .root, scene: scene, viewController: rootViewController, transitionStyle: nil)
                        self.sceneNodeStack = [[sceneNode]]
                        self.currentTabIndex = 0

                        scene.sceneIsInitialized
                            .observeOn(Ms.instance)
                            .filter { $0 }
                            .take(1)
                            .subscribe { [weak self] _ in
                                UIRootContainer.shared.setRootViewController(
                                    rootViewController, transitionStyle: transitionStyle, completion: { [weak self] in
                                        DispatchQueue.main.async {
                                            completion?()
                                        }
                                        self?.sceneTransitionQueue.resume()
                                    })
                            }
                            .disposed(by: self.disposeBag)
                    }

                    let currentScene = self.currentSceneNode.scene

                    if transitionStyle.isNext {
                        guard let navigationController = currentScene.viewController.navigationController else {
                            assertionFailure()
                            return
                        }
                        let transition = UISceneTransitionStyle.defaultNext.transition
                        self.makeNextTransition(
                            navigationController: navigationController, viewController: scene.viewController, toScenes: [scene], transition: transition,
                            completion: semiCompletion)

                    } else if transitionStyle.isUp {
                        let transition = UISceneTransitionStyle.defaultUp.transition
                        self.makeUpTransition(
                            viewController: scene.viewController, fromScene: currentScene, toScenes: [scene], transition: transition,
                            completion: semiCompletion)
                    }
                }
            }
        }
    }

    /// Makes a "set" transition to a tabs controller.
    public func set(tabsControllerType: UITabsController.Type, initialSceneTypes: [UIInitialScene.Type], initialTabIndex: Int) {
        set(tabsControllerType: tabsControllerType, initialSceneTypes: initialSceneTypes, initialTabIndex: initialTabIndex, transitionStyle: .defaultSet,
            completion: nil)
    }

    /// Makes a "set" transition to a tabs controller using a specific transition style.
    public func set(
        tabsControllerType: UITabsController.Type, initialSceneTypes: [UIInitialScene.Type], initialTabIndex: Int, completion: @escaping VoidClosure) {

        set(
            tabsControllerType: tabsControllerType, initialSceneTypes: initialSceneTypes, initialTabIndex: initialTabIndex, transitionStyle: .defaultSet,
            completion: completion)
    }

    /// Makes a "set" transition to a tabs controller using a specific transition style, calling a completion closure afterwards.
    public func set(
        tabsControllerType: UITabsController.Type, initialSceneTypes: [UIInitialScene.Type], initialTabIndex: Int,
        transitionStyle: UISceneTransitionStyle, completion: VoidClosure?) {

        sceneTransitionQueue.async { [weak self] in
            guard let self = self else { return }
            self.sceneTransitionQueue.suspend()

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }

                if let presentedViewController = UIRootContainer.shared.presentedViewController {
                    presentedViewController.dismiss(animated: false, completion: nil)
                }

                let initialScenes = initialSceneTypes.map { sceneType in sceneType.init() }
                let viewControllers = initialScenes.map { scene in Self.embedInNavigationControllerIfNeeded(scene.viewController) }

                let tabsController = tabsControllerType.init()
                tabsController.viewControllers = viewControllers
                tabsController.selectedIndex = initialTabIndex
                let tabsControllerViewController = tabsController as! UIViewController

                self.currentlyActiveTransition = nil

                if !transitionStyle.isNext &&
                   !transitionStyle.isUp {

                    log.info("Setting the root scene to \(stringType(tabsControllerType))", logCategory)

                    O.combineLatest(initialScenes.map({ $0.sceneIsInitialized }))
                        .observeOn(Ms.instance)
                        .filter { $0.allSatisfy({ $0 }) }
                        .take(1)
                        .subscribe { [weak self] _ in
                            guard let self = self else { return }

                            self.sceneNodeStack =
                                initialScenes.enumerated().map { index, scene in
                                    return [SceneNode(type: .root, scene: scene, viewController: viewControllers[index], transitionStyle: nil)]
                                }
                            self.currentTabIndex = initialTabIndex
                            self.tabsController = tabsController

                            UIRootContainer.shared.setRootViewController(
                                tabsControllerViewController, transitionStyle: transitionStyle,
                                completion: { [weak self] in
                                    DispatchQueue.main.async {
                                        completion?()
                                    }
                                    self?.sceneTransitionQueue.resume()
                                })
                        }
                        .disposed(by: self.disposeBag)
                } else {
                    let semiCompletion = {
                        let transitionStyle: UISceneTransitionStyle = .immediateSet

                        let initialScenes = initialSceneTypes.map { sceneType in sceneType.init() }
                        let viewControllers = initialScenes.map { scene in Self.embedInNavigationControllerIfNeeded(scene.viewController) }

                        let tabsController = tabsControllerType.init()
                        tabsController.viewControllers = viewControllers
                        tabsController.selectedIndex = initialTabIndex
                        let tabsControllerViewController = tabsController as! UIViewController

                        log.info("Setting the root scene to \(stringType(tabsControllerType))", logCategory)

                        O.combineLatest(initialScenes.map({ $0.sceneIsInitialized }))
                            .observeOn(Ms.instance)
                            .filter { $0.allSatisfy({ $0 }) }
                            .take(1)
                            .subscribe { [weak self] _ in
                                guard let self = self else { return }

                                self.sceneNodeStack =
                                    initialScenes.enumerated().map { index, scene in
                                        return [SceneNode(type: .root, scene: scene, viewController: viewControllers[index], transitionStyle: nil)]
                                    }
                                self.currentTabIndex = initialTabIndex
                                self.tabsController = tabsController

                                UIRootContainer.shared.setRootViewController(
                                    tabsControllerViewController, transitionStyle: transitionStyle,
                                    completion: { [weak self] in
                                        DispatchQueue.main.async {
                                            completion?()
                                        }
                                        self?.sceneTransitionQueue.resume()
                                    })
                            }
                            .disposed(by: self.disposeBag)
                    }

                    let currentScene = self.currentSceneNode.scene

                    if transitionStyle.isNext {
                        guard let navigationController = currentScene.viewController.navigationController else {
                            assertionFailure()
                            return
                        }
                        let transition = UISceneTransitionStyle.defaultNext.transition
                        self.makeNextTransition(
                            navigationController: navigationController, viewController: tabsControllerViewController, toScenes: initialScenes,
                            transition: transition, completion: semiCompletion)

                    } else if transitionStyle.isUp {
                        let transition = UISceneTransitionStyle.defaultUp.transition
                        self.makeUpTransition(
                            viewController: tabsControllerViewController, fromScene: currentScene, toScenes: initialScenes,
                            transition: transition, completion: semiCompletion)
                    }
                }
            }
        }
    }

    // MARK: - "Tab" transitions

    /// Makes a "tab" transition to the scene that is currently topmost in the scene stack located at the specified tab index.
    public func tab(tabIndex: Int) {
        DispatchQueue.main.syncSafe {
            guard let tabsController = tabsController else {
                assertionFailure()
                return
            }

            guard tabIndex != tabsController.selectedIndex else { return }

            if let firstSceneNode = sceneNodeStack[currentTabIndex].first,
               let tabBarController = firstSceneNode.viewController.tabBarController,
               let transition = firstSceneNode.transitionStyle?.transition {

                currentlyActiveTransition = transition
                tabBarController.delegate = currentlyActiveTransition
            }

            log.info("Making a \"tab\" transition to \(stringType(sceneNodeStack[tabIndex].first!.scene))", logCategory)
            tabsController.selectedIndex = tabIndex

            currentTabIndex = tabIndex
        }
    }

    // MARK: - "Back" transitions

    /// Makes a "back" ("pop" or "dismiss") transition to the previous scene using the backward flavor of the transition style that was used
    /// to transition to the current scene, if any.
    public func back() {
        back(completion: nil)
    }

    /// Makes a "back" ("pop" or "dismiss") transition to the previous scene using the backward flavor of the transition style that was used
    /// to transition to the current scene, if any, and calling a completion closure afterwards.
    public func back(completion: VoidClosure?) {
        sceneTransitionQueue.async { [weak self] in
            guard let self = self else { return }
            self.sceneTransitionQueue.suspend()

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }

                assert(self.sceneNodeCount > 1)

                if let currentBaseViewController = self.currentSceneNode.scene.viewController as? UIViewControllerBase,
                   let nextBaseViewController = self.underlyingSceneNode?.scene.viewController as? UIViewControllerBase {

                    if currentBaseViewController.displaysTabBar != nextBaseViewController.displaysTabBar {
                        if let tabsController = self.tabsController {
                            if currentBaseViewController.displaysTabBar {
                                currentBaseViewController.tabBarWillHide()
                            }
                            if nextBaseViewController.displaysTabBar {
                                tabsController.showTabBar()
                            } else {
                                tabsController.hideTabBar()
                            }
                        }
                    }
                }

                switch self.currentSceneNode.type {
                case .next:
                    guard let navigationController = self.currentSceneNode.scene.viewController.navigationController else {
                        assertionFailure()
                        return
                    }
                    if self.currentSceneNode.transitionStyle != nil {
                        let transition = self.currentSceneNode.cachedTransition
                        self.currentlyActiveTransition = transition
                        navigationController.delegate = transition
                    }
                    log.info("Making a \"back\" transition to \(stringType(self.backSceneNode.scene))", logCategory)
                    self.popSceneNode()
                    navigationController.popViewController(animated: true, completion: { [weak self] in
                        self?.currentlyActiveTransition = nil
                        DispatchQueue.main.async {
                            completion?()
                        }
                        self?.sceneTransitionQueue.resume()
                    })
                case .up:
                    guard let presentingViewController = self.currentSceneNode.viewController.presentingViewController else {
                        assertionFailure()
                        return
                    }
                    if self.currentSceneNode.transitionStyle != nil {
                        let transition = self.currentSceneNode.cachedTransition
                        self.currentlyActiveTransition = transition
                        self.currentSceneNode.viewController.transitioningDelegate = transition
                    }
                    log.info("Making a \"back\" transition to \(stringType(self.backSceneNode.scene))", logCategory)
                    self.popSceneNode()
                    presentingViewController.dismiss(animated: true, completion: { [weak self] in
                        self?.currentlyActiveTransition = nil
                        DispatchQueue.main.async {
                            completion?()
                        }
                        self?.sceneTransitionQueue.resume()
                    })
                default:
                    assertionFailure()
                }
            }
        }
    }

    /// Traverses the scene stack back from the current scene in search for the scene of the specified type and makes a "pop" or "dismiss" transition
    /// using the backward flavor of the transition style that was used to transition to the found scene. The reverse traversal goes through
    /// any chain of "next" scenes, if such exist, and then through any chain of "up" scenes. The reverse traversal does not go beyond the last
    /// encountered scene in the first encountered chain of "up" scenes.
    public func backTo<Scene: UISceneBase>(_: Scene.Type) {
        sceneTransitionQueue.async { [weak self] in
            guard let self = self else { return }
            self.sceneTransitionQueue.suspend()

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }

                if self.currentSceneNode.scene is Scene {
                    return
                }

                let backToPresenting = { [weak self] in
                    guard let self = self else { return }
                    for index in (0..<(self.sceneNodeCount - 1)).reversed() {
                        let previousSceneNode = self.sceneNodeStack[self.currentTabIndex][index]
                        let nextSceneNode = self.sceneNodeStack[self.currentTabIndex][index + 1]
                        if previousSceneNode.scene is Scene {
                            guard let presentingViewController = nextSceneNode.viewController.presentingViewController else {
                                assertionFailure()
                                return
                            }
                            if self.currentSceneNode.transitionStyle != nil {
                                let transition = self.currentSceneNode.cachedTransition
                                self.currentlyActiveTransition = transition
                                self.currentSceneNode.viewController.transitioningDelegate = transition
                            }
                            self.sceneNodeStack[self.currentTabIndex].removeSubrange((index + 1)...)
                            log.info("Making a \"back\" transition to \(stringType(Scene.self))", logCategory)
                            presentingViewController.dismiss(animated: true, completion: { [weak self] in
                                guard let self = self else { return }
                                self.currentlyActiveTransition = nil
                                self.sceneTransitionQueue.resume()
                            })
                            return
                        }
                    }
                    assertionFailure()
                }

                if self.currentSceneNode.type == .next {
                    for index in (0..<(self.sceneNodeCount - 1)).reversed() {
                        let previousSceneNode = self.sceneNodeStack[self.currentTabIndex][index]
                        let nextSceneNode = self.sceneNodeStack[self.currentTabIndex][index + 1]
                        if nextSceneNode.type != .next { break }
                        if previousSceneNode.scene is Scene {
                            guard let navigationController = nextSceneNode.scene.viewController.navigationController else {
                                assertionFailure()
                                return
                            }
                            if self.currentSceneNode.transitionStyle != nil {
                                let transition = self.currentSceneNode.cachedTransition
                                self.currentlyActiveTransition = transition
                                navigationController.delegate = transition
                            }
                            self.sceneNodeStack[self.currentTabIndex].removeSubrange((index + 1)...)
                            log.info("Making a \"back\" transition to \(stringType(Scene.self))", logCategory)
                            navigationController.popToViewController(
                                previousSceneNode.scene.viewController, animated: true, completion: { [weak self] in
                                    guard let self = self else { return }
                                    self.currentlyActiveTransition = nil
                                    self.sceneTransitionQueue.resume()
                                })
                            return
                        }
                    }

                    backToPresenting()
                } else if self.currentSceneNode.type == .up {
                    backToPresenting()
                } else {
                    assertionFailure()
                }
            }
        }
    }

    // MARK: - Current scene

    /// Returns the current scene.
    public var currentScene: UISceneBase {
        return DispatchQueue.main.syncSafe {
            return currentSceneNode.scene
        }
    }

    // MARK: - Internal UI management

    public func _popSceneIfNeeded(ifContainsViewController viewController: UIViewController) {
        DispatchQueue.main.syncSafe {
            let doPop: Bool
            let currentViewController = currentSceneNode.viewController
            if viewController === currentViewController {
                doPop = true
            } else {
                doPop = currentViewController.children.contains { childViewController -> Bool in
                    return viewController === childViewController
                }
            }

            if doPop {
                popSceneNode()
            }
        }
    }

    public func _popSceneIfNeeded(ifContainsNavigationItem navigationItem: UINavigationItem) {
        DispatchQueue.main.syncSafe {
            let currentViewController = currentSceneNode.viewController
            if currentViewController.navigationItem === navigationItem {
                popSceneNode()
            }
        }
    }

    // MARK: - Private

    private enum SceneNodeType {
        case root
        case next
        case up
    }

    private struct SceneNode {

        let type: SceneNodeType
        let scene: UISceneBase
        let viewController: UIViewController
        let transitionStyle: UISceneTransitionStyle?
        let cachedTransition: UISceneTransition?

        init(type: SceneNodeType, scene: UISceneBase, viewController: UIViewController, transitionStyle: UISceneTransitionStyle?) {
            self.type = type
            self.scene = scene
            self.viewController = viewController
            self.transitionStyle = transitionStyle
            self.cachedTransition = transitionStyle?.transition
        }

    }

    private func makeNextTransition(
        navigationController: UINavigationController, viewController: UIViewController, toScenes: [UISceneBase], transition: UISceneTransition?,
        completion: VoidClosure?) {

        DispatchQueue.main.syncSafe {
            currentlyActiveTransition = transition
            navigationController.delegate = currentlyActiveTransition

            O.combineLatest(toScenes.map({ $0.sceneIsInitialized }))
                .observeOn(Ms.instance)
                .filter { $0.allSatisfy({ $0 }) }
                .take(1)
                .subscribe { [weak self] _ in
                    navigationController.pushViewController(viewController, animated: true, completion: { [weak self] in
                        self?.currentlyActiveTransition = nil
                        DispatchQueue.main.syncSafe {
                            completion?()
                        }
                    })
                }
                .disposed(by: disposeBag)
        }
    }

    private func makeUpTransition(
        viewController: UIViewController, fromScene: UISceneBase, toScenes: [UISceneBase], transition: UISceneTransition?,
        completion: VoidClosure?) {

        DispatchQueue.main.syncSafe {
            currentlyActiveTransition = transition
            viewController.transitioningDelegate = currentlyActiveTransition

            // The value for `modalPresentationStyle` is `.custom` only for transitions with a presentation controller.
            if transition?.presentationControllerType == nil {
                viewController.modalPresentationStyle = .fullScreen
            } else {
                viewController.modalPresentationStyle = .custom
            }

            O.combineLatest(toScenes.map({ $0.sceneIsInitialized }))
                .observeOn(Ms.instance)
                .filter { $0.allSatisfy({ $0 }) }
                .take(1)
                .subscribe { [weak self] _ in
                    fromScene.viewController.present(viewController, animated: true, completion: { [weak self] in
                        self?.currentlyActiveTransition = nil
                        DispatchQueue.main.syncSafe {
                            completion?()
                        }
                    })
                }
                .disposed(by: disposeBag)
        }
    }

    private static func embedInNavigationControllerIfNeeded(_ viewController: UIViewController) -> UIViewController {
        if !(viewController is UINavigationController) &&
           !(viewController is UITabBarController) &&
           !(viewController is UISplitViewController) {

            // Embed into a UINavigationController.
            return UIEmbeddingNavigationController(rootViewController: viewController)
        } else {
            // Use as is.
            return viewController
        }
    }

    private var currentSceneNode: SceneNode {
        return sceneNodeStack[currentTabIndex].last!
    }

    private var underlyingSceneNode: SceneNode? {
        return sceneNodeStack[currentTabIndex][safe: sceneNodeStack[currentTabIndex].lastIndex - 1]
    }

    private func pushSceneNode(_ sceneNode: SceneNode) {
        return sceneNodeStack[currentTabIndex].append(sceneNode)
    }

    private func popSceneNode() {
        sceneNodeStack[currentTabIndex].removeLast()
    }

    private var sceneNodeCount: Int {
        return sceneNodeStack[currentTabIndex].count
    }

    private var backSceneNode: SceneNode {
        let lastIndex = sceneNodeStack[currentTabIndex].lastIndex
        return sceneNodeStack[currentTabIndex][lastIndex - 1]
    }

}
