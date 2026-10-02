# Android AmneziaWG native bridge

This JNI bridge is adapted from `tunnel/tools/libwg-go` in the official
[`amneziawg-android`](https://github.com/amnezia-vpn/amneziawg-android)
repository at commit `ff15093`. Its Android API and JNI shim are Apache-2.0;
the embedded AmneziaWG Go implementation is MIT-licensed by its upstream
module. See `UPSTREAM-COPYING` and the SPDX headers on the source files.

The app builds `libawg-go.so` for its Android ABIs using the pinned
`github.com/amnezia-vpn/amneziawg-go/v3` module and the installed Android NDK.
The build overlays the Go runtime's Linux clock calls to use `CLOCK_BOOTTIME`,
so keepalive timers account for time spent in device suspend. It attaches the
VPN service's TUN descriptor directly to an in-process device; the descriptor
and configuration stay in memory and are never written to disk.
