import Foundation

/// The shell script that runs with elevated privileges while the app is open.
///
/// It owns the hosts file for exactly as long as the app does: the app spawns it once after
/// the admin prompt and talks to it over an inherited pipe. When the app quits (or crashes)
/// the pipe closes, `read` hits end-of-file and the script exits. Nothing is installed and
/// nothing stays behind.
///
/// Only `/bin/sh` and a handful of stock system binaries are executed, all by absolute path.
public enum HelperScript {
    public static let source = #"""
    HOSTS="$1"
    TMP="$HOSTS.hostmanager.tmp"
    say() { printf '%s\n' "$*"; }
    say READY
    while IFS= read -r cmd; do
      case "$cmd" in
        PING)
          say PONG ;;
        FLUSH)
          /usr/bin/dscacheutil -flushcache </dev/null >/dev/null 2>&1
          /usr/bin/killall -HUP mDNSResponder </dev/null >/dev/null 2>&1
          say FLUSHED ;;
        QUIT)
          exit 0 ;;
        'WRITE '*)
          n="${cmd#WRITE }"
          case "$n" in
            ''|*[!0-9]*) say ERR BAD_LENGTH; continue ;;
          esac
          if [ "$n" -gt __MAX_BYTES__ ]; then say ERR TOO_LARGE; continue; fi
          /bin/rm -f "$TMP" </dev/null >/dev/null 2>&1
          # Read exactly n single bytes so the next command is still waiting in the pipe.
          # The reply is only sent once the file system is in its final state.
          if ! /bin/dd of="$TMP" bs=1 count="$n" >/dev/null 2>&1; then
            /bin/rm -f "$TMP" </dev/null >/dev/null 2>&1
            say ERR IO_FAILED
            continue
          fi
          got=$(/usr/bin/wc -c < "$TMP" | /usr/bin/tr -d ' ')
          if [ "$got" -ne "$n" ]; then
            /bin/rm -f "$TMP" </dev/null >/dev/null 2>&1
            say ERR SHORT_READ
            continue
          fi
          /bin/chmod 644 "$TMP" </dev/null >/dev/null 2>&1
          /usr/sbin/chown root:wheel "$TMP" </dev/null >/dev/null 2>&1
          # rename(2) on the same volume: readers see either the old file or the new one.
          if /bin/mv -f "$TMP" "$HOSTS" </dev/null >/dev/null 2>&1; then
            say "WROTE $n"
          else
            /bin/rm -f "$TMP" </dev/null >/dev/null 2>&1
            say ERR WRITE_FAILED
          fi ;;
        *)
          say ERR UNKNOWN_COMMAND ;;
      esac
    done
    exit 0
    """#

    /// Refuse to write anything larger than a hosts file could plausibly be.
    public static let maximumBytes = 16 * 1024 * 1024

    /// The script with its one placeholder filled in.
    public static var rendered: String {
        source.replacingOccurrences(of: "__MAX_BYTES__", with: String(maximumBytes))
    }

    /// `sh -c` invocation: the hosts path travels as `$1` instead of being spliced into
    /// the script text, so it never needs escaping.
    public static func arguments(hostsPath: String) -> [String] {
        ["-c", rendered, "hostmanager", hostsPath]
    }

    /// Starts the persistent helper detached from the invoking shell, wired to a private pair of
    /// FIFOs so `osascript` returns immediately while the elevated helper stays open for the
    /// lifetime of the app. Opening `outputFIFO` before `inputFIFO` guarantees the writer side of
    /// `outputFIFO` is already open by the time the parent's `open(inputFIFO, O_WRONLY)` succeeds.
    public static func detachedSessionCommand(hostsPath: String, inputFIFO: String, outputFIFO: String) -> String {
        "( exec /bin/sh -c \(ShellQuoting.singleQuote(rendered)) hostmanager \(ShellQuoting.singleQuote(hostsPath))"
            + " > \(ShellQuoting.singleQuote(outputFIFO))"
            + " < \(ShellQuoting.singleQuote(inputFIFO)) 2>/dev/null ) </dev/null >/dev/null 2>&1 &"
    }

    /// A single `WRITE` piped through the helper in one invocation: the path taken when no
    /// session could be spawned. `cat` joins the command line and the payload file, in that
    /// order, into the helper's stdin.
    public static func oneShotCommand(byteCount: Int, payloadPath: String, hostsPath: String) -> String {
        "/usr/bin/printf 'WRITE \(byteCount)\\n'"
            + " | /bin/cat - \(ShellQuoting.singleQuote(payloadPath))"
            + " | /bin/sh -c \(ShellQuoting.singleQuote(rendered)) hostmanager \(ShellQuoting.singleQuote(hostsPath))"
    }

    /// The `do shell script` wrapper that lets osascript run a command, as the user or as root.
    public static func appleScript(forShellCommand command: String, privileged: Bool) -> String {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\"" + (privileged ? " with administrator privileges" : "")
    }
}

/// The line protocol spoken over the helper's stdio. One request, one reply.
public enum HelperProtocol {
    public enum Reply: Equatable, Sendable {
        case ready
        case pong
        case flushed
        case wrote(Int)
        case error(String)
        case unknown(String)
    }

    public static let quitCommand = "QUIT"
    public static let pingCommand = "PING"
    public static let flushCommand = "FLUSH"

    public static func writeCommand(byteCount: Int) -> String {
        "WRITE \(byteCount)"
    }

    public static func parseReply(_ line: String) -> Reply {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        switch parts.first {
        case "READY": return .ready
        case "PONG": return .pong
        case "FLUSHED": return .flushed
        case "WROTE": return .wrote(Int(parts.count == 2 ? parts[1] : "") ?? -1)
        case "ERR": return .error(parts.count == 2 ? parts[1] : "?")
        default: return .unknown(line)
        }
    }
}

/// Quotes a string for use as a single shell word.
public enum ShellQuoting {
    public static func singleQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
