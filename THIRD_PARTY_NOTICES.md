# Dependencies

This repository contains an original session controller and client. It uses the public API of
[Karabiner-DriverKit-VirtualHIDDevice](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice),
package version 8.6.0, commit `9036bc771259ff8d61341f4d1b7072b954fdb2fa`, client protocol 7.

The official signed driver must be installed separately from its official release. Driver binaries,
package signing identities, and upstream source trees are not redistributed in this repository.
`scripts/fetch-deps.sh` downloads the pinned upstream headers and the complete vendored header
snapshot tracked in that commit. It does not regenerate dependencies from newer releases.

The upstream repository has an Unlicense dedication; individual headers also carry their own notices,
including Boost Software License 1.0. Transitive libraries (including nlohmann/json, Asio, type_safe,
and pqrs components) retain their original licenses in the downloaded dependency tree. Consult those
notices before redistributing a compiled binary. This project does not change the upstream notices.

The input sequence follows the upstream virtual HID API. The driver and upstream project are not
affiliated with this repository, and neither is an official WeChat interface.
