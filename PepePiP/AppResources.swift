// Loose-file lookup that also works when the app runs as a guest inside LiveContainer: there `Bundle.main` is the HOST
// app's bundle, so `Bundle.main.url(forResource:)` finds nothing (black backdrop, no puff, possibly no glb). We try, in
// order, the bundle that contains our own classes, Bundle.main, and the directory of the running executable, and log
// which one answered the first time plus a one-off inventory of every asset.
import Foundation
import UIKit

enum AppResources {
    static let assets = ["pepe.glb", "puff.png", "glow.png", "floor_shadow.png", "bg_lounge.png", "bg_office.png", "bg_neon.png"]
    private static var announced = false
    private static var reported = false

    /// Candidate directories, most specific first.
    static var searchDirectories: [(String, URL)] {
        var out: [(String, URL)] = [("Bundle(for: PepeScene)", Bundle(for: PepeScene.self).bundleURL), ("Bundle.main", Bundle.main.bundleURL)]
        if let exe = Bundle(for: PepeScene.self).executableURL { out.append(("class executable dir", exe.deletingLastPathComponent())) }
        if let exe = Bundle.main.executableURL { out.append(("main executable dir", exe.deletingLastPathComponent())) }
        if let arg0 = CommandLine.arguments.first { out.append(("argv[0] dir", URL(fileURLWithPath: arg0).deletingLastPathComponent())) }
        var seen = Set<String>()
        return out.filter { seen.insert($0.1.standardizedFileURL.path).inserted }
    }

    /// `name` includes the extension ("bg_lounge.png").
    static func url(_ name: String) -> URL? {
        for (label, dir) in searchDirectories {
            let u = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: u.path) {
                if !announced { announced = true; Log.add("resources: '\(name)' answered by \(label) = \(dir.path)") }
                return u
            }
        }
        Log.add("resources: '\(name)' NOT FOUND in \(searchDirectories.map { $0.1.path }.joined(separator: " | "))")
        return nil
    }

    static func image(_ name: String) -> UIImage? {
        url(name.hasSuffix(".png") ? name : name + ".png").flatMap { UIImage(contentsOfFile: $0.path) }
    }

    /// The bundle whose Info.plist describes THIS app (Bundle.main is the host's inside LiveContainer).
    static var ownBundle: Bundle { Bundle(for: PepeScene.self) }

    /// Once: the resolved directories and whether each asset is present, for the in-app log.
    static func report() {
        guard !reported else { return }
        reported = true
        Log.add("resources: main=\(Bundle.main.bundleURL.path) own=\(ownBundle.bundleURL.path) argv0=\(CommandLine.arguments.first ?? "?")")
        for name in assets {
            let hit = searchDirectories.first { FileManager.default.fileExists(atPath: $0.1.appendingPathComponent(name).path) }
            Log.add("resources: \(name) \(hit.map { "ok (\($0.0))" } ?? "MISSING")")
        }
    }
}
