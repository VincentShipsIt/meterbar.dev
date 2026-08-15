import Darwin
import Dispatch
import Foundation

/// Installs the interrupt handlers a long-running `meterbar` command needs to
/// end on its own terms — emitting its documented output and exit code —
/// instead of dying wherever the signal found it.
///
/// Five commands installed these by hand with byte-for-byte identical code.
nonisolated public enum CLISignalHandlers {
    /// SIGTERM as well as SIGINT: a command started by a script or a
    /// `timeout(1)` wrapper is far more likely to be terminated than
    /// interrupted, and both must still produce the documented JSON and exit
    /// code. `wake` is the exception — it takes SIGINT only, per its #99
    /// contract — and passes its own list.
    public static let interruptAndTerminate: [Int32] = [SIGINT, SIGTERM]

    /// Routes each signal to `flag.cancel()` and returns the live sources.
    ///
    /// The caller owns the returned sources and must cancel them (a `defer` at
    /// the top of `run()`); a released `DispatchSourceSignal` stops observing.
    ///
    /// - Parameters:
    ///   - signals: Signals to observe. Defaults to SIGINT and SIGTERM.
    ///   - flag: The flag every handler sets.
    public static func install(
        _ signals: [Int32] = interruptAndTerminate,
        cancelling flag: CLICancellationFlag
    ) -> [DispatchSourceSignal] {
        signals.map { signalNumber in
            // A signal source observes the signal, it does not consume it, so
            // without SIG_IGN the default disposition still kills the process
            // before the handler can run.
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler { flag.cancel() }
            source.resume()
            return source
        }
    }
}
