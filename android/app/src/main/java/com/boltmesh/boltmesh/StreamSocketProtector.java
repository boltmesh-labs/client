package com.boltmesh.boltmesh;

import android.net.VpnService;

/**
 * Registers the live {@link VpnService} so the native stream bridge can protect
 * its TLS socket from the tunnel it carries.
 *
 * <p>The bridge dials the node on the physical network, but once the tunnel is
 * up the app's default network <em>is</em> the tunnel: without
 * {@link VpnService#protect} the bridge's own TLS connection would be routed
 * into the tunnel it is meant to carry and never come up. The native side calls
 * {@link #nativeAttach} from the AWG service; with nothing registered,
 * protection fails and the dial fails closed rather than leaking.
 *
 * <p>Deliberately a plain Java class: the JNI symbols are bound by exact class
 * and method name, which a Kotlin object's generated statics make easy to get
 * subtly wrong.
 */
public final class StreamSocketProtector {
    private StreamSocketProtector() {}

    /** Registers [service]; a later attach replaces an earlier one. */
    public static native void nativeAttach(VpnService service);

    /** Clears the registration when [service] is still the current one. */
    public static native void nativeDetach(VpnService service);
}
