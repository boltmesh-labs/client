package com.boltmesh.boltmesh;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotNull;

import android.content.pm.ApplicationInfo;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import com.wireguard.android.backend.GoBackend;
import java.lang.reflect.Field;
import orban.group.wireguard_flutter.WireguardFlutterPlugin;
import org.junit.Test;
import org.junit.runner.RunWith;

/** Runtime contract for the private fields used by {@link TunnelHost}. */
@RunWith(AndroidJUnit4.class)
public final class MinifiedTunnelBridgeTest {
  @Test
  public void releaseBuildKeepsReflectedTunnelFields() throws Exception {
    // No VPN consent or live tunnel is needed: this guards the R8 field ABI
    // before the app tries any backend operation.
    ApplicationInfo applicationInfo = InstrumentationRegistry.getInstrumentation()
        .getTargetContext()
        .getApplicationInfo();
    assertEquals(
        "the bridge smoke test must run against the release variant",
        0,
        applicationInfo.flags & ApplicationInfo.FLAG_DEBUGGABLE);

    assertFields(
        WireguardFlutterPlugin.class,
        "backend",
        "futureBackend",
        "tunnel",
        "config",
        "tunnelName");
    assertFields(GoBackend.class, "currentTunnel", "currentConfig");
  }

  private static void assertFields(Class<?> owner, String... names) throws Exception {
    for (String name : names) {
      Field field = owner.getDeclaredField(name);
      field.setAccessible(true);
      assertNotNull(owner.getName() + "." + name, field);
    }
  }
}
