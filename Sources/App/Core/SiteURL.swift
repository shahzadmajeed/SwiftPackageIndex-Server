import Plot
import Vapor


// MARK: - Resource declaration


// The following are all the routes we support and reference from various places, some of them
// static routes (images), others dynamic ones for use in controller definitions.
//
// Introduce nesting by declaring a new type conforming to Resourceable and embed it in the
// parent resource.
//
// Enums based on String are automatically Resourceable via RawRepresentable.


enum Api: String, Resourceable {
    case version
    case search
}


enum SiteURL: Resourceable {

    case admin
    case api(Api)
    case about
    case home
    case images(String)
    case packages
    case package(_ parameter: Parameter<Package.Id>)
    case privacy

    var path: String {
        switch self {
            case .about:
                return "about"
            case .admin:
                return "admin"
            case .api:
                return "api"
            case .home:
                return ""
            case let .images(name):
                return "images/\(name)"
            case .packages, .package(.name):
                return "packages"
            case let .package(.value(value)):
                return "packages/\(value.uuidString)"
            case .privacy:
                return "privacy"
        }
    }

    var pathComponents: [PathComponent] {
        switch self {
            case let .api(res):
                return ["api"] + res.pathComponents
            case let .package(.name(name)):
                return [.init(stringLiteral: path), .init(stringLiteral: ":\(name)")]
            case .package(.value(_)):
                fatalError("pathComponents must not be called with a value parameter")
            case .admin, .about, .home, .packages, .privacy:
                return [.init(stringLiteral: path)]
            case .images:
                fatalError("invalid resource path for routing - only use in static HTML (DSL)")
        }
    }

}


// MARK: - Types for use in resource declaration


protocol Resourceable {
    var absoluteURL: String { get }
    var relativeURL: String { get }
    var path: String { get }
    var pathComponents: [PathComponent] { get }
}


extension Resourceable {
    var absoluteURL: String { "\(Current.siteURL())/\(path)" }
    var relativeURL: String { "/" + path }
}


extension Resourceable where Self: RawRepresentable, RawValue == String {
    var path: String { rawValue }
    var pathComponents: [PathComponent] { [.init(stringLiteral: path)] }
}


enum Parameter<T> {
    case name(String)
    case value(T)
}