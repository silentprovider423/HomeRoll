import SwiftUI

/// Ordneransicht (GitHub #42): Fotos so, wie sie auf dem Server in Ordnern liegen – vor allem für externe
/// Bibliotheken mit eigener Ordnerstruktur. Quelle ist Immichs Ordner-Schnittstelle (view/folder).
/// Immichs interne Ablage hochgeladener Fotos (upload/<Benutzer-ID>/ab/cd) ist kein echter Ordner und bleibt weg.
@MainActor @Observable final class FolderStore {
    static let shared = FolderStore()
    /// Alle Ordner mit Fotos (volle Pfade, sortiert)
    private(set) var paths: [String] = []
    /// gemeinsamer Anfang aller Pfade – die oberste Ebene der Ansicht
    private(set) var root = ""
    private(set) var loaded = false
    private var covers: [String: String] = [:]
    private var contents: [String: [Asset]] = [:]

    func load() async {
        guard let all = try? await ImmichClient.shared.folderPaths() else { return }
        #if DEBUG
        let showAll = ProcessInfo.processInfo.environment["FOTOS_FOLDERS_ALL"] != nil
        #else
        let showAll = false
        #endif
        let keep = showAll ? all : all.filter { !Self.isInternal($0) }
        paths = keep.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        root = Self.commonDirectory(paths)
        covers = [:]; contents = [:]
        loaded = true
    }

    nonisolated static func isInternal(_ p: String) -> Bool {
        let c = p.split(separator: "/")
        if let i = c.lastIndex(of: "upload"), i + 1 < c.count, c[i + 1].count == 36 { return true }
        return c.contains("encoded-video") || c.contains("thumbs")
    }

    /// Längster gemeinsamer Ordner (bei nur einem Ordner dessen übergeordneter, damit er als Eintrag erscheint)
    nonisolated static func commonDirectory(_ paths: [String]) -> String {
        guard let first = paths.first else { return "" }
        var common = first.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if paths.count == 1 { common.removeLast() }
        for p in paths.dropFirst() {
            let c = p.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            var n = 0
            while n < common.count, n < c.count, common[n] == c[n] { n += 1 }
            common = Array(common.prefix(n))
        }
        // ein Ordner, der selbst Fotos hat, aber zugleich der Anfang ist, bleibt sichtbar: eine Ebene höher beginnen
        let j = common.joined(separator: "/")
        if paths.count > 1, paths.contains(j), !common.isEmpty { common.removeLast() }
        return common.joined(separator: "/")
    }

    /// Unterordner direkt unter `dir` (volle Pfade)
    func children(of dir: String) -> [String] {
        let prefix = dir.hasSuffix("/") ? dir : dir + "/"
        var seen = Set<String>(), out: [String] = []
        for p in paths where p.hasPrefix(prefix) {
            guard let name = p.dropFirst(prefix.count).split(separator: "/").first else { continue }
            let child = prefix + name
            if seen.insert(child).inserted { out.append(child) }
        }
        return out
    }

    func hasPhotos(_ dir: String) -> Bool { paths.contains(dir) }

    /// Anzahl der Ordner mit Fotos darunter (für die Unterzeile)
    func nestedCount(_ dir: String) -> Int { let pre = dir + "/"; return paths.filter { $0.hasPrefix(pre) }.count }

    static func name(_ dir: String) -> String { dir.split(separator: "/").last.map(String.init) ?? dir }

    func assets(_ dir: String) async -> [Asset] {
        if let c = contents[dir] { return c }
        let a = ((try? await ImmichClient.shared.folderAssets(dir)) ?? []).map(\.asset)
            .sorted { $0.date < $1.date }
        contents[dir] = a
        return a
    }

    /// Titelbild: neuestes Foto im Ordner selbst, sonst im ersten Unterordner mit Fotos
    func cover(_ dir: String) async -> String? {
        if let c = covers[dir] { return c }
        let source = hasPhotos(dir) ? dir : paths.first { $0.hasPrefix(dir + "/") }
        guard let source else { return nil }
        let list = await assets(source)
        guard let id = list.last(where: { $0.trashedAt == nil })?.id else { return nil }
        covers[dir] = id
        return id
    }
}

/// Karte eines Ordners in der Übersicht: Titelbild + Ordnersymbol
struct FolderCard: View {
    let path: String
    @State private var cover: String?
    var body: some View {
        SmallCard(assetID: cover, title: FolderStore.name(path), badge: "folder.fill")
            .task(id: path) { cover = await FolderStore.shared.cover(path) }
    }
}

/// Ein Ordner: Unterordner oben, darunter die Fotos dieses Ordners. Ohne Unterordner direkt das Raster.
struct FolderScreen: View {
    let path: String
    private var store: FolderStore { .shared }
    @State private var assets: [Asset]?

    var body: some View {
        let subs = store.children(of: path)
        let title = path == store.root ? String(localized: "Ordner") : FolderStore.name(path)
        if subs.isEmpty {
            AssetGridScreen(title: title, subtitle: subtitle, assets: assets ?? [], loading: assets == nil)
                .task { if assets == nil { assets = await store.assets(path) } }
        } else {
            List {
                if store.hasPhotos(path) {
                    Section {
                        NavigationLink(value: CollectionRoute.folderPhotos(path)) {
                            Label(String(localized: "Fotos in diesem Ordner"), systemImage: "photo.on.rectangle")
                        }
                    }
                }
                Section {
                    ForEach(subs, id: \.self) { s in
                        NavigationLink(value: CollectionRoute.folder(s)) { FolderRow(path: s) }
                    }
                }
            }
            .navigationTitle(title)
        }
    }

    private var subtitle: String {
        guard let assets else { return "" }
        return assets.count == 1 ? String(localized: "1 Objekt") : String(localized: "\(assets.count) Objekte")
    }
}

private struct FolderRow: View {
    let path: String
    @State private var cover: String?
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if let cover { AssetThumb(id: cover, size: .thumbnail) } else { Color(white: 0.14) }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(FolderStore.name(path)).font(.body)
                let n = FolderStore.shared.nestedCount(path)
                if n > 0 { Text(String(localized: "\(n) Ordner")).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .task(id: path) { cover = await FolderStore.shared.cover(path) }
    }
}
