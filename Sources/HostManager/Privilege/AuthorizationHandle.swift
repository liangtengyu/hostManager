import Foundation
import Security

/// Why something that needed the admin password did not happen.
enum PrivilegeError: Error, Equatable {
    /// The user dismissed the password prompt.
    case canceled
    case authorizationFailed(OSStatus)
    case toolLaunchFailed(OSStatus)
    /// Started, but never answered the handshake.
    case helperUnavailable
    /// Was running, then its pipe closed.
    case helperStopped
    case timedOut
    /// The helper understood the request and refused it; its reason is carried along.
    case rejected(String)
    case payloadTooLarge
    case notRunning

    /// The one-line explanation shown in the UI.
    var message: String {
        switch self {
        case .canceled:
            return L10n.t("privilege.canceled")
        case .authorizationFailed(let status):
            return L10n.f("privilege.authorizationFailed", status)
        case .toolLaunchFailed(let status):
            return L10n.f("privilege.launchFailed", status)
        case .helperUnavailable, .notRunning:
            return L10n.t("privilege.helperUnavailable")
        case .helperStopped:
            return L10n.t("privilege.helperStopped")
        case .timedOut:
            return L10n.t("privilege.timedOut")
        case .rejected(let reason):
            return L10n.f("privilege.rejected", reason)
        case .payloadTooLarge:
            return L10n.t("privilege.payloadTooLarge")
        }
    }
}

/// Owns the one right the app needs (`system.privilege.admin`) and the deprecated call that
/// starts a tool with it.
///
/// `AuthorizationExecuteWithPrivileges` is the only way to get a privileged process that is
/// tied to this app's lifetime without installing a launch daemon, which is exactly what a
/// tool that must not leave anything behind needs. Its replacement (SMAppService) registers
/// a permanent system helper instead. Swift declares the old function "unavailable", so it
/// is looked up by name at run time; should a future macOS drop it, the lookup fails and the
/// session falls back to `osascript`.
final class AuthorizationHandle {
    private typealias ExecuteWithPrivileges = @convention(c) (
        AuthorizationRef, UnsafePointer<CChar>, AuthorizationFlags,
        UnsafePointer<UnsafeMutablePointer<CChar>?>?, UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
    ) -> OSStatus

    private var reference: AuthorizationRef?

    /// Whether `AuthorizationExecuteWithPrivileges` is still present in Security.framework on this
    /// macOS version. Checked before prompting so a system that dropped it can fall back cleanly.
    var isExecuteAvailable: Bool {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "AuthorizationExecuteWithPrivileges") != nil
    }

    /// Shows the system password prompt unless the right was granted recently.
    /// Returns `errAuthorizationSuccess`, or the reason it was not granted.
    func obtainRight() -> OSStatus {
        if reference == nil {
            let status = AuthorizationCreate(nil, nil, [], &reference)
            guard status == errAuthorizationSuccess else { return status }
        }
        guard let reference else { return errAuthorizationInternal }

        // Both the right's name and the item array are read as C pointers, so they have to be
        // kept alive by hand for the duration of the call.
        let rightName = strdup(kAuthorizationRightExecute)!
        defer { free(rightName) }
        var item = AuthorizationItem(name: rightName, valueLength: 0, value: nil, flags: 0)
        return withUnsafeMutablePointer(to: &item) { items in
            var rights = AuthorizationRights(count: 1, items: items)
            return AuthorizationCopyRights(
                reference, &rights, nil,
                [.interactionAllowed, .extendRights, .preAuthorize], nil
            )
        }
    }

    /// Starts `tool` as root and returns the descriptor of the bidirectional pipe to its
    /// standard I/O. The caller owns the descriptor.
    func launch(_ tool: String, arguments: [String]) throws -> Int32 {
        guard let reference else { throw PrivilegeError.notRunning }
        // RTLD_DEFAULT (search every loaded image) is a C macro, hence the literal.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "AuthorizationExecuteWithPrivileges") else {
            throw PrivilegeError.toolLaunchFailed(errAuthorizationInternal)
        }
        let execute = unsafeBitCast(symbol, to: ExecuteWithPrivileges.self)

        // The arguments start with the first real one; the tool is passed separately and the
        // system puts it in front as argv[0]. Passing it here as well makes the call fail
        // with errAuthorizationToolExecuteFailure. A null pointer ends the list.
        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }

        let pipes = UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>.allocate(capacity: 2)
        pipes.initialize(repeating: nil, count: 2)
        defer { pipes.deallocate() }

        let status = argv.withUnsafeBufferPointer { execute(reference, tool, [], $0.baseAddress, pipes) }
        guard status == errAuthorizationSuccess else {
            throw status == errAuthorizationCanceled ? PrivilegeError.canceled : PrivilegeError.toolLaunchFailed(status)
        }
        // The header says "a UNIX stdio FILE pointer for a bidirectional pipe": one handle
        // that carries both directions, not one per direction.
        guard let channel = pipes[0] else {
            throw PrivilegeError.toolLaunchFailed(errAuthorizationInternal)
        }
        // Keep a plain descriptor rather than the FILE pointer so nothing else closes it.
        let descriptor = dup(fileno(channel))
        fclose(channel)
        guard descriptor >= 0 else {
            throw PrivilegeError.toolLaunchFailed(errAuthorizationInternal)
        }
        return descriptor
    }

    func release() {
        if let reference {
            AuthorizationFree(reference, [])
            self.reference = nil
        }
    }
}
