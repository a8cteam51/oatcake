// Oatcake.app's one executable: the app, or with --analyse <recording folder> the helper that
// analyses one recording, or with --live <recording folder> the one that transcribes a call while
// it's recorded, or with --menu-bar the one that draws the menu bar item. All report as JSON lines
// on standard output.

import Foundation
import OatcakeCore

if let flag = CommandLine.arguments.firstIndex(of: "--analyse"), flag + 1 < CommandLine.arguments.count {
    let dir = URL(fileURLWithPath: CommandLine.arguments[flag + 1], isDirectory: true)
    let output = FileHandle.standardOutput
    let post = { (progress: AnalysisProgress) in
        if let data = try? JSONEncoder().encode(progress) { output.write(data + Data("\n".utf8)) }
    }
    Task {
        do {
            try await analyse(dir, report: post)
            post(AnalysisProgress(done: true))
            exit(0)
        } catch {
            post(AnalysisProgress(error: error.localizedDescription))
            exit(1)
        }
    }
    dispatchMain()
} else if let flag = CommandLine.arguments.firstIndex(of: "--live"), flag + 1 < CommandLine.arguments.count {
    // The live transcript of a recording still being made: one JSON line per finished stretch of speech.
    let dir = URL(fileURLWithPath: CommandLine.arguments[flag + 1], isDirectory: true)
    let output = FileHandle.standardOutput
    let post = { (event: LiveEvent) in
        if let data = try? JSONEncoder().encode(event) { output.write(data + Data("\n".utf8)) }
    }
    Task {
        do {
            try await transcribeLive(dir, report: post)
            exit(0)
        } catch {
            post(LiveEvent(error: error.localizedDescription))
            exit(1)
        }
    }
    dispatchMain()
} else if CommandLine.arguments.contains(MenuBarLink.flag) {
    MainActor.assumeIsolated { MenuBarHelper.run() }
} else {
    OatcakeApp.main()
}
