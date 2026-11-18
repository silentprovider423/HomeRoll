import Foundation
import UIKit

/// Backup-Uploads über eine Hintergrund-Sitzung von iOS (wie iCloud-Fotos): Die Übertragung läuft im System weiter,
/// auch wenn die App in den Hintergrund geht, gesperrt oder beendet wird. Ohne das brach ein 5,4-GB-Video bei jedem
/// App-Wechsel ab (07.11.2026).
/// - Läuft die App noch, wartet `upload(…)` ganz normal auf das Ergebnis.
/// - Ist die App inzwischen weg, startet iOS sie im Hintergrund neu und meldet das Ende hier; das Ergebnis geht dann an
///   `BackupEngine.adopt(…)` (die Angaben dazu stehen in `taskDescription`).
final class BackgroundUploader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = BackgroundUploader()
    static let sessionID = "org.homeroll.app.backup-upload"

    /// Was zu einem Upload gehört, falls die App das Ende nicht mehr selbst erlebt.
    struct Meta: Codable {
        var user: String            // Server-Nutzer (Backup-Gedächtnis je Konto)
        var localID: String         // PHAsset.localIdentifier
        var kind: String            // "main" | "live" | "edited"
        var body: String            // Pfad des Multipart-Rumpfs (danach löschen)
        var localDate: String?      // Videos/Bildschirmfotos: Aufnahmezeit mit Zeitzone (Immich zeigt sonst UTC)
        var checksum: String?       // SHA1 – falls die Antwort leer ankommt, findet der Server das Objekt darüber
    }

    private let lock = NSLock()
    private var waiting: [Int: CheckedContinuation<ImmichClient.UploadResult, Error>] = [:]
    private var received: [Int: Data] = [:]
    /// Von iOS beim Neustart im Hintergrund übergeben; aufrufen, wenn alle Meldungen verarbeitet sind.
    var finishEvents: (() -> Void)?

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        c.isDiscretionary = false            // sofort, nicht „wenn es dem System passt“
        c.sessionSendsLaunchEvents = true    // App nach dem Ende im Hintergrund wecken
        c.timeoutIntervalForResource = 3 * 24 * 3600
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    /// Beim App-Start einmal anlegen, damit Meldungen aus einer früheren Sitzung ankommen.
    func reconnect() { _ = session }

    /// Hochladen und auf das Ergebnis warten. Wird die wartende Aufgabe abgebrochen (App geht in den Hintergrund und
    /// iOS nimmt die Zeit weg), läuft die Übertragung trotzdem weiter – das Ergebnis kommt dann über `adopt`.
    func upload(_ req: URLRequest, body: URL, meta: Meta) async throws -> ImmichClient.UploadResult {
        let task = session.uploadTask(with: req, fromFile: body)
        task.taskDescription = (try? String(data: JSONEncoder().encode(meta), encoding: .utf8)) ?? nil
        let id = task.taskIdentifier
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                lock.withLock { waiting[id] = c }
                task.resume()
            }
        } onCancel: {
            // nur nicht mehr warten – NICHT die Übertragung abbrechen
            if let c = lock.withLock({ waiting.removeValue(forKey: id) }) { c.resume(throwing: CancellationError()) }
        }
    }

    /// Pausieren: alle laufenden Backup-Übertragungen wirklich stoppen.
    func cancelAll() {
        session.getAllTasks { $0.forEach { $0.cancel() } }
    }

    /// Objekte, die gerade noch im System übertragen werden (z. B. aus einer früheren Sitzung).
    func activeLocalIDs() async -> Set<String> {
        let tasks = await session.allTasks.filter { $0.state == .running || $0.state == .suspended }
        return Set(tasks.compactMap { $0.taskDescription.flatMap { try? JSONDecoder().decode(Meta.self, from: Data($0.utf8)) }?.localID })
    }

    /// Dateinamen der Rümpfe, die das System gerade noch überträgt – alles andere im Rumpf-Ordner ist verwaist.
    func activeBodies() async -> Set<String> {
        let tasks = await session.allTasks.filter { $0.state == .running || $0.state == .suspended }
        return Set(tasks.compactMap { $0.taskDescription.flatMap { try? JSONDecoder().decode(Meta.self, from: Data($0.utf8)) } }
            .map { ($0.body as NSString).lastPathComponent })
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0,
              let meta = task.taskDescription.flatMap({ try? JSONDecoder().decode(Meta.self, from: Data($0.utf8)) }) else { return }
        let p = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        Task { @MainActor in
            if BackupEngine.shared.currentLocalID == meta.localID { BackupEngine.shared.progress = p }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { received[dataTask.taskIdentifier, default: Data()].append(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskIdentifier
        let (c, data) = lock.withLock { (waiting.removeValue(forKey: id), received.removeValue(forKey: id) ?? Data()) }
        let meta = task.taskDescription.flatMap { try? JSONDecoder().decode(Meta.self, from: Data($0.utf8)) }
        if let meta { try? FileManager.default.removeItem(atPath: meta.body) }
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        Task {
            var result: Result<ImmichClient.UploadResult, Error>
            if let error { result = .failure(error) }
            else {
                do { result = .success(try ImmichClient.shared.uploadResult(data, task.response)) }
                catch { result = .failure(error) }
                // Angekommen (2xx), aber Antwort leer: kommt bei der Hintergrund-Übertragung vor, wenn die App gerade
                // eingefroren war (07.11.2026, 3 Fotos). Dann die ID über die Prüfsumme beim Server erfragen.
                if case .failure = result, (200..<300).contains(status), let m = meta, let sum = m.checksum,
                   let id = try? await ImmichClient.shared.bulkUploadCheck(id: m.localID, checksum: sum) {
                    result = .success(ImmichClient.UploadResult(id: id, status: "created"))
                }
            }
            if let c { c.resume(with: result); return }
            // Niemand wartet mehr (App war weg): Ergebnis ins Backup-Gedächtnis übernehmen
            guard let meta, case .success(let r) = result else { return }
            await BackupEngine.shared.adopt(r, meta: meta)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            // kurz Zeit lassen, damit `adopt` gespeichert hat, bevor iOS die App wieder einfriert
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.finishEvents?(); self?.finishEvents = nil }
        }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        await ImmichClient.shared.urlSession(session, didReceive: challenge)
    }
}

/// Nimmt iOS’ Weckruf für die Hintergrund-Übertragung entgegen.
final class HomeRollAppDelegate: NSObject, UIApplicationDelegate {
    /// Hochformat überall, nur die Einzelansicht darf sich drehen (wie Fotos), siehe `Orientation`
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { Orientation.allowed }
    }
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundUploader.sessionID else { completionHandler(); return }
        BackgroundUploader.shared.finishEvents = completionHandler
        BackgroundUploader.shared.reconnect()
    }
}

/// Welche Ausrichtungen gerade erlaubt sind: Raster und Sammlungen im Hochformat, die Einzelansicht auch quer.
@MainActor enum Orientation {
    static var allowed: UIInterfaceOrientationMask = .portrait

    static func set(_ mask: UIInterfaceOrientationMask) {
        guard allowed != mask else { return }
        allowed = mask
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            // Zurück ins Hochformat drehen, wenn die Einzelansicht quer geschlossen wird
            if mask == .portrait, scene.interfaceOrientation != .portrait {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            }
        }
    }
}
