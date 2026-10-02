package org.amnezia.awg;

import androidx.annotation.Nullable;

public class GoBackend {
    @Nullable
    public static native String awgGetConfig(int handle);

    public static native int awgGetSocketV4(int handle);

    public static native int awgGetSocketV6(int handle);

    // The Android stream bridge. awgStartStream carries a validated transport
    // spec (JSON, the same shape the Dart client builds) and returns a handle
    // whose <= 0 value is a failure; the bridge then dials the node inside TLS
    // and moves the tunnel's loopback datagrams over it. Its TLS socket is
    // protected from the tunnel by the registered VpnService.
    public static native int awgStartStream(String specJson);

    public static native void awgStopStream(int handle);

    public static native void awgTurnOff(int handle);

    public static native int awgTurnOn(String ifName, int tunFd, String settings);

    public static native String awgVersion();
}
