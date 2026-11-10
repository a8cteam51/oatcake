// Oatcake.app's one executable: the app, or with --analyse <recording folder> the helper that
// analyses one recording, reporting progress as JSON lines on standard output.

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
} else {
    OatcakeApp.main()
}
