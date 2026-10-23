# Design

The normal-user Python CLI only creates a bounded native session and sends JSON over a local Unix
socket. A single Objective-C++ process owns one upstream client, one virtual keyboard, and one virtual
pointing device throughout the session. It launches the official daemon only when no daemon already
exists, and only terminates its own child PID. The root runtime code is copied and SHA256 checked
before execution in a root-owned temporary directory.

## Runtime limits

- Hard lifetime: at most 7200 seconds. Idle: at most 1800 seconds. Action budget: at most 500.
- Batch: at most 16 actions and 30 seconds; validates all fields and coordinates before any input.
- Protocol: one JSON line per connection, at most 16 KiB, 2-second receive deadline.
- Socket is mode 0600, belongs to the original console user; its parent belongs to root and is not
  writable by that user. No mutable Python script is executed by the privileged service.
- Only the original UID can send requests. Client verifies root peer identity before sending.
- Allowed targets: TextEdit and native WeChat. All input reports check the foreground target;
  device, console-user and display-geometry changes also abort. Neutral release reports are still
  sent during cleanup to avoid a held key/button.
- The entire request is validated before input. Successfully executed and partially failed batches
  are cached before replying. Reusing an ID with changed contents fails; reusing identical input
  retrieves its result. Operations are serialized.
- Status queries do not refresh idle lifetime. No automatic keepalive or reconnection is used.

## Request shape

`{"id":"unique-id","op":"status"}`

`{"id":"query-id","op":"result","request_id":"prior-batch-id"}`

`{"id":"stop-id","op":"stop"}`

`{"id":"batch-id","op":"batch","app":"com.apple.TextEdit","actions":[...]}`

The first action may be `{"type":"activate"}`. Other action types:

- `{"type":"key","key":"cmd+f","settle_ms":150}`
- `{"type":"move","x":600,"y":400}`
- `{"type":"click","x":600,"y":400}`
- `{"type":"double-click","x":600,"y":400}`
- `{"type":"scroll","x":600,"y":400,"delta":-50}`

Coordinates refer to the current CoreGraphics desktop coordinate space, support multiple displays,
and must fall within one active display with a small border margin. A session refuses changed
display geometry. Pointer movement retains the earlier tested 60 ms cadence; key/button holds retain
80 ms. Device readiness plus 1 second settling happens once per session. Per-action settling defaults
to 150 ms and can be increased when the application needs time.

## Deliberate limits

The service does not read application AX trees or screenshots. It cannot determine whether a chat
is the right recipient, whether a login/security dialog is visible, or whether a message was sent.
Those remain explicit checks for the caller. The tool does not disable application checks, modify
WeChat, or claim to bypass its policies. A virtual device is not a physical device.

Simulation is an explicitly separate backend, requires a non-root process, and never connects to
the driver or starts the daemon. It is used for socket/protocol/replay/lifecycle tests. It does not
establish real input delivery or WeChat stability.
