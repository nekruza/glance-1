import AppKit

/// Runs a one-off setup step (install, sign in, version check) visibly in
/// Terminal. A `.command` file opened through NSWorkspace runs in Terminal
/// without the Automation ("control Terminal") permission that scripting it
/// would need, and the user sees exactly what runs.
enum TerminalLauncher {

    /// POSIX single-quoting.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The script: show what runs, run it, then leave `marker` so Glance
    /// knows the step finished and re-checks on its own.
    static func script(command: String, marker: URL) -> String {
        """
        #!/bin/zsh -l
        clear
        printf 'Glance is running:  %s\\n\\n' \(quote(command))
        \(command)
        glance_status=$?
        touch \(quote(marker.path))
        echo
        if [ $glance_status -eq 0 ]; then
          echo "Done. Switch back to Glance; it picks this up on its own."
        else
          echo "That step failed (exit $glance_status). Fix the error above, then press Try again in Glance."
        fi

        """
    }

    /// Write the script next to `marker` and open it in Terminal.
    @discardableResult
    static func run(command: String, marker: URL) -> Bool {
        let dir = marker.deletingLastPathComponent()
        let url = dir.appendingPathComponent("glance-setup-\(UUID().uuidString.prefix(8)).command")
        // Earlier steps' scripts (an open Terminal keeps running its copy).
        let fm = FileManager.default
        for old in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        where old.hasPrefix("glance-setup-") && old.hasSuffix(".command") {
            try? fm.removeItem(at: dir.appendingPathComponent(old))
        }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try script(command: command, marker: marker).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        } catch {
            NSLog("Glance: couldn't write setup script: \(error.localizedDescription)")
            return false
        }
        return NSWorkspace.shared.open(url)
    }
}
