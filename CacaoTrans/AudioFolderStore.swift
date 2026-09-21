import Foundation
import AppKit

/// 音声ファイルの置き場所（既定: 書類/CacaoTrans）。サンドボックスのため、最初に一度フォルダを選んでもらい、
/// セキュリティスコープ付きブックマークとして記憶する。
@MainActor
final class AudioFolderStore: ObservableObject {
    private static let bookmarkKey = "CacaoTrans.audioFolderBookmark"

    @Published private(set) var folderURL: URL?
    private var accessing = false

    static var defaultFolderURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CacaoTrans", isDirectory: true)
    }

    init() {
        restore()
    }

    var displayPath: String {
        guard let folderURL else { return "未設定（既定: 書類/CacaoTrans）" }
        // サンドボックス内では NSHomeDirectory() がコンテナを指すので、実際のホームを passwd から取る
        let realHome = String(cString: getpwuid(getuid()).pointee.pw_dir)
        let path = folderURL.path
        if path.hasPrefix(realHome + "/") { return "~" + path.dropFirst(realHome.count) }
        return path
    }

    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else { return }
        adopt(url)
        if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey)
        }
    }

    private func adopt(_ url: URL) {
        if accessing, let old = folderURL { old.stopAccessingSecurityScopedResource() }
        accessing = url.startAccessingSecurityScopedResource()
        folderURL = url
    }

    /// フォルダ選択ダイアログ。既定の 書類/CacaoTrans を作って初期位置にする。
    func choose() -> Bool {
        let panel = NSOpenPanel()
        panel.title = "音声ファイルを置くフォルダを選択"
        panel.message = "プロジェクトを開いたとき、このフォルダから同じ名前の音声ファイルを自動で探します。"
        panel.prompt = "このフォルダを使う"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        let def = Self.defaultFolderURL
        try? FileManager.default.createDirectory(at: def, withIntermediateDirectories: true)
        panel.directoryURL = FileManager.default.fileExists(atPath: def.path) ? def : def.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        if let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        }
        adopt(url)
        return true
    }

    /// フォルダ内から名前で探す（直下 → 1階層下のサブフォルダの順）。
    func locate(fileNamed name: String) -> URL? {
        guard let folderURL, !name.isEmpty else { return nil }
        let fm = FileManager.default
        let direct = folderURL.appendingPathComponent(name)
        if fm.fileExists(atPath: direct.path) { return direct }
        if let subs = try? fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for sub in subs where (try? sub.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let candidate = sub.appendingPathComponent(name)
                if fm.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }
}
