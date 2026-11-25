import SwiftUI
import ContactsUI

/// Person mit einem Kontakt verknüpfen (wie Fotos): Name und Geburtstag kommen aus dem Kontakt.
/// Der Kontakt-Auswahlbogen läuft außerhalb der App – dafür braucht es keine Kontakte-Freigabe.
/// Die Verknüpfung merkt sich die App je Person auf diesem iPhone.
enum ContactLinks {
    private static let key = "contactLinks"
    static func contact(for person: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[person]
    }
    static func set(_ contact: String?, for person: String) {
        var d = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        d[person] = contact
        UserDefaults.standard.set(d, forKey: key)
    }
}

/// Apples Kontaktauswahl direkt von UIKit aus zeigen: in einen SwiftUI-Bogen eingebettet blieb sie leer bzw. reagierte
/// nicht (GitHub #65 „link contact doesn't work“).
@MainActor enum ContactPicker {
    private static var delegate: Delegate?
    static func present(_ onPick: @escaping (CNContact) -> Void) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
              var top = scene.keyWindow?.rootViewController else { return }
        while let p = top.presentedViewController { top = p }
        let p = CNContactPickerViewController()
        let d = Delegate(onPick); delegate = d
        p.delegate = d
        top.present(p, animated: true)
    }
    @MainActor final class Delegate: NSObject, @preconcurrency CNContactPickerDelegate {
        let onPick: (CNContact) -> Void
        init(_ f: @escaping (CNContact) -> Void) { onPick = f }
        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            onPick(contact); ContactPicker.delegate = nil
        }
        func contactPickerDidCancel(_ picker: CNContactPickerViewController) { ContactPicker.delegate = nil }
    }
}

/// „Diese Person nicht vorschlagen“ wie in Fotos (GitHub #65): Fotos dieser Personen kommen nicht in Rückblicke und
/// empfohlene Fotos. Gemerkt je Gerät; die Foto-IDs werden je Sitzung einmal beim Server erfragt.
@MainActor enum NotFeatured {
    private static let key = "people.notFeatured"
    private static var cache: [String: Set<String>] = [:]
    static var people: Set<String> { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
    static func contains(_ person: String) -> Bool { people.contains(person) }
    static func set(_ person: String, _ on: Bool) {
        var p = people
        if on { p.insert(person) } else { p.remove(person); cache[person] = nil }
        UserDefaults.standard.set(Array(p), forKey: key)
    }
    /// Alle Foto-IDs der ausgeschlossenen Personen
    static func assetIDs() async -> Set<String> {
        var out = Set<String>()
        for p in people {
            if let c = cache[p] { out.formUnion(c); continue }
            guard let list = try? await ImmichClient.shared.search(filter: ["personIds": ["any": [p]]], size: 200_000) else { continue }
            let ids = Set(list.map(\.id)); cache[p] = ids; out.formUnion(ids)
        }
        return out
    }
}
