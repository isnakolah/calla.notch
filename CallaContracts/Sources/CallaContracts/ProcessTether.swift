import Darwin
import Dispatch

/// Keeps every process calla.notch starts underneath the one that started it.
///
/// macOS has no `PR_SET_PDEATHSIG`: when a parent dies, its children are
/// reparented to launchd and keep running. Killing the notch used to leave a
/// call host holding the microphone and `agy` language servers resident for
/// days. Two pieces close that gap:
///
/// * processes we write (the call host) watch their parent with
///   `onExit(of:)` and shut themselves down when it goes;
/// * processes we do not write (`script`, `agy`, `perl`) are launched through
///   `tethered(_:_:)`, a few lines of `/bin/sh` that run the command and end it
///   as soon as the parent is gone.
///
/// The chain is app → engine → call host → `agy`, so killing the app, by any
/// means, takes the whole tree down within a second or two.
public enum ProcessTether {
    /// The launch for `executable arguments`, wrapped so it is ended when
    /// `parent` exits. The wrapper also forwards SIGTERM/SIGINT/SIGHUP, so
    /// `Process.terminate()` and tree kills keep working on it as before.
    ///
    /// Standard input is passed through explicitly: `sh` would otherwise hand a
    /// background job `/dev/null`, which breaks the interactive sign-in.
    public static func tethered(_ executable: String, _ arguments: [String],
                                to parent: pid_t = getpid()) -> (executable: String, arguments: [String]) {
        // `k` signals a whole subtree, deepest first, so nothing the command
        // started is reparented to launchd on the way down.
        let script = """
        p=$1; shift
        k() { for x in $(/usr/bin/pgrep -P "$1"); do k "$x" "$2"; done; kill -"$2" "$1" 2>/dev/null; }
        "$@" <&0 &
        c=$!
        trap 'k "$c" TERM; wait "$c"; exit 143' TERM INT HUP
        while kill -0 "$p" 2>/dev/null && kill -0 "$c" 2>/dev/null; do sleep 1; done
        if kill -0 "$c" 2>/dev/null; then
          k "$c" TERM; sleep 1; k "$c" KILL
        fi
        wait "$c"
        """
        return ("/bin/sh", ["-c", script, "callanotch-tether", String(parent), executable] + arguments)
    }

    /// Calls `handler` once when `pid` exits, or at once if it already has.
    /// Keep the returned source alive for as long as the watch should last.
    public static func onExit(of pid: pid_t, queue: DispatchQueue = .global(),
                              _ handler: @escaping @Sendable () -> Void) -> DispatchSourceProcess? {
        guard pid > 1 else { return nil }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler(handler: handler)
        source.resume()
        // The parent may have died between reading its pid and arming the watch.
        if kill(pid, 0) != 0 && errno == ESRCH { queue.async(execute: handler) }
        return source
    }
}
