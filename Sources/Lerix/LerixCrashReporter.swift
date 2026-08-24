import Foundation

/// Automatic crash capture — mirrors the Flutter SDK's `analyze()` (as
/// distinct from the manual `throwError`): install once, and any uncaught
/// exception or fatal signal gets reported on the *next* launch without the
/// app having to call anything itself.
///
/// A crash handler can't reliably do async network I/O — the process is
/// terminating — so this only ever does a synchronous file write at crash
/// time, then reports it normally once the app restarts.
enum LerixCrashReporter {
    private static let pendingCrashFileName = "lerix_pending_crash.json"
    private static let fatalSignals: [Int32] = [SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGTRAP]

    private static var pendingCrashURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(pendingCrashFileName)
    }

    /// Call once during `Lerix.initialize()`. Safe to call more than once —
    /// later calls are no-ops.
    static func install() {
        guard NSGetUncaughtExceptionHandler() == nil else { return }

        NSSetUncaughtExceptionHandler { exception in
            LerixCrashReporter.persistCrash(
                issue: "\(exception.name.rawValue): \(exception.reason ?? "no reason")",
                stack: exception.callStackSymbols
            )
        }

        for sig in fatalSignals {
            signal(sig, LerixCrashReporter.handleSignal)
        }
    }

    private static let handleSignal: @convention(c) (Int32) -> Void = { sig in
        LerixCrashReporter.persistCrash(
            issue: "Fatal signal \(sig) (\(String(cString: strsignal(sig))))",
            stack: Thread.callStackSymbols
        )
        // Restore the previous handler (if any) and re-raise, so the OS's
        // own crash reporting/debugger still sees a normal crash.
        signal(sig, SIG_DFL)
        raise(sig)
    }

    private static func persistCrash(issue: String, stack: [String]) {
        let payload: [String: Any] = ["issue": issue, "stack": stack]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: pendingCrashURL, options: .atomic)
    }

    /// Call once at startup (after registration) to report and clear any
    /// crash captured during a previous run.
    static func reportPendingCrashIfAny() async {
        let url = pendingCrashURL
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let issue = payload["issue"] as? String
        else { return }

        let stack = payload["stack"] as? [String] ?? []
        try? FileManager.default.removeItem(at: url)

        await ErrorsHandler.throwError(issue: issue, stack: stack, type: .crash, severity: .critical)
    }
}
