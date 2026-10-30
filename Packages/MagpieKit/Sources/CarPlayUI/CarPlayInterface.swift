#if os(iOS) && canImport(CarPlay)
import CarPlay
import UIKit

/// What `CarPlayController` asks of the car's screen: `CPInterfaceController` in the car. `CPInterfaceController` has
/// no public initialiser, so tests drive the controller through a fake that keeps the template stack (T23).
@MainActor
public protocol CarPlayInterface: AnyObject {
    var delegate: (any CPInterfaceControllerDelegate)? { get set }
    var templates: [CPTemplate] { get }
    var topTemplate: CPTemplate? { get }
    var presentedTemplate: CPTemplate? { get }
    var carTraitCollection: UITraitCollection { get }
    func setRootTemplate(_ rootTemplate: CPTemplate, animated: Bool, completion: ((Bool, (any Error)?) -> Void)?)
    func pushTemplate(_ templateToPush: CPTemplate, animated: Bool, completion: ((Bool, (any Error)?) -> Void)?)
    func pop(to targetTemplate: CPTemplate, animated: Bool, completion: ((Bool, (any Error)?) -> Void)?)
    func presentTemplate(_ templateToPresent: CPTemplate, animated: Bool, completion: ((Bool, (any Error)?) -> Void)?)
    func dismissTemplate(animated: Bool, completion: ((Bool, (any Error)?) -> Void)?)
}

extension CPInterfaceController: CarPlayInterface {}
#endif
