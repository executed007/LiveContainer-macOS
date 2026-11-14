import Security
import UIKit

// A UIKit app the end-to-end test installs into LiveContainer. It is built for Mac Catalyst
// (the only UIKit the Command Line Tools can link) and re-stamped as an iOS binary, which is
// what an .ipa contains. On launch it records what it sees from inside its container to
// Documents/probe.json, then quits if LC_FIXTURE_QUIT is set.

func keychainLaunchCount() -> (count: Int, status: OSStatus) {
    let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                               kSecAttrService as String: "fixture", kSecAttrAccount as String: "launches"]
    var query = base
    query[kSecReturnData as String] = true
    var result: CFTypeRef?
    var count = 0
    if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
        count = Int(String(decoding: data, as: UTF8.self)) ?? 0
    }
    count += 1
    let value = Data(String(count).utf8)
    var status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: value] as CFDictionary)
    if status == errSecItemNotFound {
        var add = base
        add[kSecValueData as String] = value
        status = SecItemAdd(add as CFDictionary, nil)
    }
    return (count, status)
}

func probe() {
    let defaults = UserDefaults.standard
    let launches = defaults.integer(forKey: "launches") + 1
    defaults.set(launches, forKey: "launches")
    defaults.synchronize()
    let keychain = keychainLaunchCount()
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let report: [String: Any] = [
        "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
        "bundlePath": Bundle.main.bundlePath,
        "executablePath": Bundle.main.executablePath ?? "",
        "home": NSHomeDirectory(),
        "documents": documents.path,
        "tmp": NSTemporaryDirectory(),
        "processName": ProcessInfo.processInfo.processName,
        "systemName": UIDevice.current.systemName,
        "defaultsLaunches": launches,
        "keychainLaunches": keychain.count,
        "keychainStatus": Int(keychain.status),
        "infoValue": Bundle.main.object(forInfoDictionaryKey: "FixtureMarker") as? String ?? "",
        "appGroup": FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.dev.livecontainer.fixture")?.path ?? "",
    ]
    let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: documents.appendingPathComponent("probe.json"))
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let controller = UIViewController()
        controller.view.backgroundColor = .systemBackground
        let label = UILabel()
        label.text = "Hello from LiveContainer"
        label.font = .preferredFont(forTextStyle: .title1)
        label.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor),
        ])
        window = UIWindow(windowScene: scene)
        window?.rootViewController = controller
        window?.makeKeyAndVisible()
        probe()
        if ProcessInfo.processInfo.environment["LC_FIXTURE_QUIT"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
        }
    }
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}
