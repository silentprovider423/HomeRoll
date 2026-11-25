import SwiftUI

/// Immichs „Gesperrter Ordner“ (GitHub #68): Fotos mit Sichtbarkeit „locked“ sieht nur eine Sitzung, die mit der
/// PIN des Kontos entsperrt ist. Die PIN liegt nach der ersten Eingabe im Schlüsselbund dieses iPhones; danach reicht
/// Face ID (LockGate davor). Beim Verlassen und in den Hintergrund wird die Sitzung wieder gesperrt.
@MainActor
enum LockedFolder {
    enum State: Equatable { case open, needsSetup, needsPin }

    private static let key = "lockedFolderPin"
    static var savedPin: String? { Keychain.get(key) }

    /// Sitzung entsperren – mit gemerkter PIN, wenn es eine gibt.
    static func prepare() async -> State {
        let api = ImmichClient.shared
        guard let s = try? await api.authStatus() else { return .needsPin }
        if s.isElevated { return .open }
        if !s.pinCode { return .needsSetup }
        guard let pin = savedPin else { return .needsPin }
        if (try? await api.unlockSession(pin)) != nil { return .open }
        Keychain.set(nil, for: key)   // PIN in Immich geändert → neu fragen
        return .needsPin
    }

    /// PIN prüfen und merken; false = falsche PIN.
    static func unlock(_ pin: String) async -> Bool {
        guard (try? await ImmichClient.shared.unlockSession(pin)) != nil else { return false }
        Keychain.set(pin, for: key)
        return true
    }

    /// Erste PIN für das Konto anlegen (gilt dann auch in Immich im Browser und in der Immich-App).
    static func setup(_ pin: String) async -> Bool {
        guard (try? await ImmichClient.shared.setupPin(pin)) != nil else { return false }
        return await unlock(pin)
    }

    static func lock() async { await ImmichClient.shared.lockSession() }

    /// „In gesperrten Ordner bewegen“: braucht eine entsperrte Sitzung, also eine schon einmal eingegebene PIN.
    static func move(_ ids: [String], app: AppModel, timeline: TimelineStore) async -> Bool {
        guard await prepare() == .open else {
            app.toast(String(localized: "Öffne zuerst „Gesperrter Ordner“ in den Sammlungen und gib deine PIN ein."))
            return false
        }
        defer { Task { await lock() } }
        guard (try? await ImmichClient.shared.update(ids, ["visibility": "locked"])) != nil else {
            app.toast(String(localized: "Konnte nicht bewegt werden")); return false
        }
        ids.forEach(timeline.remove)
        app.toast(ids.count == 1 ? String(localized: "In gesperrten Ordner bewegt") : String(localized: "\(ids.count) in gesperrten Ordner bewegt"))
        return true
    }

    /// Zurück in die Mediathek (nur aus dem geöffneten Ordner heraus, die Sitzung ist dann entsperrt).
    static func moveOut(_ ids: [String], app: AppModel, timeline: TimelineStore) {
        app.toast(ids.count == 1 ? String(localized: "Aus gesperrtem Ordner entfernt") : String(localized: "\(ids.count) aus gesperrtem Ordner entfernt"))
        Task {
            try? await ImmichClient.shared.update(ids, ["visibility": "timeline"])
            await timeline.reload()
        }
    }
}

/// Inhalt hinter Face ID: PIN anlegen/eingeben, dann das Raster.
struct LockedFolderScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(TimelineStore.self) private var timeline
    @State private var state: LockedFolder.State?
    @State private var assets: [Asset]?

    var body: some View {
        Group {
            switch state {
            case .open:
                AssetGridScreen(title: Category.lockedFolder.title,
                                subtitle: assets.map { $0.count == 1 ? String(localized: "1 Objekt") : String(localized: "\($0.count) Objekte") } ?? "",
                                assets: assets ?? [], loading: assets == nil,
                                onRemove: { id in withAnimation(.snappy) { assets?.removeAll { $0.id == id } } })
                    .task { if assets == nil { await load() } }
                    .onChange(of: app.viewer == nil) { _, closed in if closed { Task { await load() } } }
            case .needsSetup:
                PinEntry(setup: true) { pin in
                    guard await LockedFolder.setup(pin) else { return false }
                    state = .open; return true
                }
            case .needsPin:
                PinEntry(setup: false) { pin in
                    guard await LockedFolder.unlock(pin) else { return false }
                    state = .open; return true
                }
            case nil:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.appBackground)
            }
        }
        .task { if state == nil { state = await LockedFolder.prepare() } }
        .onDisappear {
            // Einzelansicht liegt darüber → offen lassen; sonst sofort wieder sperren
            if app.viewer == nil { Task { await LockedFolder.lock() } }
        }
    }

    private func load() async {
        assets = await CategoryLoader.load(.lockedFolder, timeline: timeline)
    }
}

/// Sechsstellige PIN wie in Immich (beim Anlegen zweimal).
private struct PinEntry: View {
    let setup: Bool
    let submit: (String) async -> Bool
    @State private var pin = ""
    @State private var first: String?
    @State private var error: String?
    @State private var busy = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.rectangle.stack").font(.system(size: 44)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 22, weight: .bold)).multilineTextAlignment(.center)
            Text(setup ? String(localized: "Die PIN gilt für dein Immich-Konto, also auch im Browser und in der Immich-App. HomeRoll merkt sie sich, danach reicht Face ID.")
                       : String(localized: "Die PIN deines Immich-Kontos. HomeRoll merkt sie sich, danach reicht Face ID."))
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            SecureField("PIN", text: $pin)
                .keyboardType(.numberPad).textContentType(.oneTimeCode)
                .font(.system(size: 28, weight: .semibold, design: .monospaced)).multilineTextAlignment(.center)
                .frame(width: 200, height: 52)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.appFill))
                .focused($focused)
                .onSubmit { Task { await go(pin) } }
                .onChange(of: pin) { _, v in
                    let digits = String(v.filter(\.isNumber).prefix(6))
                    if digits != v { pin = digits }
                    if digits.count == 6 { Task { await go(digits) } }
                }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            Button(String(localized: "Weiter")) { Task { await go(pin) } }
                .buttonStyle(.borderedProminent).disabled(pin.count != 6 || busy)
            if busy { ProgressView() }
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
        .overlay(alignment: .top) { ScreenHeader(title: Category.lockedFolder.title) }
        .toolbar(.hidden, for: .navigationBar)
        .task { try? await Task.sleep(for: .milliseconds(350)); focused = true }
    }

    private var title: String {
        if !setup { return String(localized: "PIN eingeben") }
        return first == nil ? String(localized: "PIN festlegen") : String(localized: "PIN bestätigen")
    }

    private func go(_ digits: String) async {
        guard !busy, digits.count == 6 else { return }
        if setup, first == nil { first = digits; pin = ""; error = nil; return }
        if setup, first != digits { first = nil; pin = ""; error = String(localized: "Die PINs stimmen nicht überein."); return }
        busy = true; defer { busy = false }
        if await submit(digits) { return }
        pin = ""
        error = setup ? String(localized: "PIN konnte nicht angelegt werden.") : String(localized: "Falsche PIN")
    }
}
