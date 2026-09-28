import CalPilotCore
import Foundation

/// One shared message for the moment a terminal command blocks on a keychain dialog.
///
/// The window and the `bin/calpilot` tool are separate binaries, and keychain access is
/// granted per binary, so whichever one did not store the key asks for permission the
/// first time it reads it. Without saying so, that looks like the command hanging.
enum KeychainHint {
    static func announce() {
        Console.note("""

          waiting for the keychain: macOS is asking whether calpilot-cli may read the saved
          API key. Look for a system dialog and choose "Always Allow" so it only asks once.
          To skip the keychain entirely, export CALPILOT_API_KEY or pass --api-key.
        """)
        // The process blocks on the dialog right after this, and stdout is block-buffered
        // whenever the output is piped — so without an explicit flush the one message that
        // explains the wait is the one message that never appears.
        fflush(stdout)
    }
}
