import AppKit

// Top-level code is nonisolated, but this all runs on the main thread before
// the run loop starts.
MainActor.assumeIsolated {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--export-icons"), i + 1 < args.count {
        do { try Logo.exportIconset(to: args[i + 1]) }
        catch { FileHandle.standardError.write(Data("icon export failed: \(error)\n".utf8)); exit(1) }
        exit(0)
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
    Retain.delegate = delegate
    app.run()
}

enum Retain {
    @MainActor static var delegate: AppDelegate?
}
