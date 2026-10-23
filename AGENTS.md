# Working on this project

- Read README.md and docs/design.md before changing the input path.
- Keep the DriverKit HID route. Do not substitute CGEventPost, cliclick, AppleScript keystrokes,
  or CUA input on WeChat as a test shortcut. Read-only UI inspection is separate from input.
- Tests default to the simulation backend and may not start a root service or send real input.
  Live-device tests require the user's task authorization and native macOS approval.
- Retain finite session limits, foreground checks, whole-batch validation, and duplicate-ID
  protection. An uncertain action must be looked up and checked in the UI before retrying.
- Never turn the temporary controller into an autostart service or add sudoers rules silently.
- Keep customer chat, names, images, QR payloads, credentials, runtime state and local absolute
  paths out of Git. Only sanitized code, documentation, tests and aggregate validation belong here.
- Do not claim that HID submission proves app receipt or that one session guarantees no logout.
- Run the build and protocol tests for input/control changes. Record actual device observations
  separately from simulated results in docs/validation.md.
