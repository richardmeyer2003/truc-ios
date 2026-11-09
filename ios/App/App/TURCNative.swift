import UIKit
import Security
import Capacitor

@objc(TURCViewController)
final class TURCViewController: CAPBridgeViewController {
    override func capacitorDidLoad() {
        bridge?.registerPluginInstance(TURCNativePlugin())
        bridge?.registerPluginInstance(TURCScannerPlugin())
    }
}

@objc(TURCNativePlugin)
public final class TURCNativePlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "TURCNativePlugin"
    public let jsName = "TURCNative"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "getItem", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setItem", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "removeItem", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "shareCSV", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "openWebsite", returnType: CAPPluginReturnPromise)
    ]

    private var service: String { (Bundle.main.bundleIdentifier ?? "org.turc.clubhouse") + ".auth" }
    private let allowedKeys = Set(["turc-auth-v1", "turc-auth-v1-code-verifier", "turc-auth-v1-user"])

    private func query(_ call: CAPPluginCall) -> [String: Any]? {
        guard let key = call.getString("key"), allowedKeys.contains(key) else {
            call.reject("Unsupported session key"); return nil
        }
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: key,
                kSecAttrSynchronizable as String: false]
    }

    @objc func getItem(_ call: CAPPluginCall) {
        guard var request = query(call) else { return }
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { call.resolve(["value": NSNull()]); return }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            call.reject("Secure session could not be read", "KEYCHAIN_READ"); return
        }
        call.resolve(["value": value])
    }

    @objc func setItem(_ call: CAPPluginCall) {
        guard let request = query(call), let value = call.getString("value") else {
            call.reject("Session value is required"); return
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(request.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            call.reject("Secure session could not be saved", "KEYCHAIN_WRITE"); return
        }
        call.resolve()
    }

    @objc func removeItem(_ call: CAPPluginCall) {
        guard let request = query(call) else { return }
        let status = SecItemDelete(request as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            call.reject("Secure session could not be removed", "KEYCHAIN_DELETE"); return
        }
        call.resolve()
    }

    @objc func openWebsite(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard let url = URL(string: "https://turc-school-run-club.richer2003.chatgpt.site/club") else {
                call.reject("Website address is unavailable"); return
            }
            UIApplication.shared.open(url) { opened in
                if opened { call.resolve() } else { call.reject("Website could not open") }
            }
        }
    }

    @objc func shareCSV(_ call: CAPPluginCall) {
        guard let text = call.getString("text"), text.utf8.count <= 10_485_760,
              let name = call.getString("name"),
              ["turc-roster.csv", "turc-fictional-roster.csv"].contains(name) else {
            call.reject("Invalid CSV export"); return
        }
        DispatchQueue.main.async { [weak self] in
            guard let controller = self?.bridge?.viewController,
                  controller.presentedViewController == nil else {
                call.reject("Close the open sheet before exporting"); return
            }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("turc-export-" + UUID().uuidString, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appendingPathComponent(name)
                try Data(text.utf8).write(to: file, options: [.atomic, .completeFileProtection])
                let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
                sheet.popoverPresentationController?.sourceView = controller.view
                sheet.popoverPresentationController?.sourceRect = CGRect(x: controller.view.bounds.midX,
                    y: controller.view.bounds.midY, width: 1, height: 1)
                sheet.completionWithItemsHandler = { _, _, _, error in
                    try? FileManager.default.removeItem(at: directory)
                    if error != nil { call.reject("CSV could not be shared") } else { call.resolve() }
                }
                controller.present(sheet, animated: true)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                call.reject("CSV could not be prepared")
            }
        }
    }
}
