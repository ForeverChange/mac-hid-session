# Validation

## Baseline

On 2026-10-23, the earlier single-action DriverKit path was used on one Apple Silicon Mac to read
references through the native UI and send three revised images plus an original-image archive.
The application remained logged in through that workflow. This is a local observation, not a
guarantee about future sessions or other systems.

## Session-reuse version — 2026-10-23

Environment: Apple Silicon, macOS 27.0, official package 8.6.0 / active driver extension 1.8.0,
client protocol 7. The existing driver was reused; no additional system extension was installed.

### Automated checks

The default dependency-fetch and build scripts were checked against a separate pinned upstream checkout; the release already includes its vendor headers, so no CMake rebuild is needed.

19 native socket/protocol tests passed. They cover device reuse, duplicate-ID suppression including
concurrent callers, changed-content ID rejection, validation of an entire batch before input,
foreground mismatch, app/key restrictions, coordinate bounds, large-integer rejection, peer identity,
socket permissions, malformed/oversized requests, idle exit, action budgets, existing-file preservation,
and the CLI's default no-input validation. Tests use the explicit simulation backend.

### Actual input

One macOS administrator approval started the real session. A second `start` returned `reused: true`
with the same native process. Both devices stayed initialized once throughout the following tests:

| Test | Observation | Measured input batch time |
|---|---|---:|
| TextEdit: activate, select all, enter test character, save | AX showed the character and the saved local test file contained exactly `x` | 0.94 s |
| WeChat: activate and Cmd+F | The search field became focused; the expected chat was still available | 0.37 s |
| WeChat: eight alternating Escape / Cmd+F keys | Search remained functional, with no observed re-login prompt | 2.44 s |
| Foreground switched to Chrome before a mouse request | Request rejected with zero input reports | 0.003 s |
| Explicitly activate WeChat and click the freshly observed search-field coordinates | Cursor reached the target; search field focused; no observed re-login prompt | 1.84 s |
| Finish with Escape | Normal chat composer restored, empty; message list still present | 0.30 s |

The successful batches contained 18 actions in total; one additional attempted action was rejected
before input. The session reported one device initialization. No customer text, test message,
image or archive was sent by these tests. Timings are native batch durations, not total agent
reasoning, UI-reading or end-to-end business task times; they are not a controlled speedup ratio.

After the last action, the current UI still showed the expected chat and message list and no
re-login prompt. `stop` then succeeded; the native service, its owned official daemon, and the
root-owned temporary runtime directory were verified absent. No autostart was added.

This is a short real-session result. It does not establish day-long stability, behavior on other
versions/accounts, or the internal cause of earlier application security logouts. Initial device
attachment still displayed Keyboard Setup Assistant once; keeping the devices connected avoided
re-initializing them for each request during this session.
