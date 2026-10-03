package com.boltmesh.boltmesh;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertTrue;

import android.content.Context;
import androidx.test.core.app.ApplicationProvider;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.filters.SdkSuppress;
import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import org.amnezia.awg.backend.GoBackend;
import org.amnezia.awg.config.Config;
import org.junit.Test;
import org.junit.runner.RunWith;

/** Exercises the shipped AWG parser and JNI library without requesting VPN consent. */
@RunWith(AndroidJUnit4.class)
@SdkSuppress(minSdkVersion = 30)
public final class AmneziaWgConnectSmokeTest {
  private static final String CONFIG =
      "[Interface]\n"
          + "PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n"
          + "Address = 10.9.0.2/32\n"
          + "DNS = 10.9.0.1\n"
          + "Jc = 4\n"
          + "Jmin = 31\n"
          + "Jmax = 621\n"
          + "S1 = 36\n"
          + "S2 = 36\n"
          + "S3 = 11\n"
          + "S4 = 35\n"
          + "H1 = 115-120\n"
          + "H2 = 130\n"
          + "H3 = 150-160\n"
          + "H4 = 171\n"
          + "\n"
          + "[Peer]\n"
          + "PublicKey = AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=\n"
          + "Endpoint = 198.51.100.1:51820\n"
          + "AllowedIPs = 10.0.0.0/8\n";

  @Test
  public void parsesObfuscationAndLoadsTheNativeEngine() throws Exception {
    Context context = ApplicationProvider.getApplicationContext();
    Config config =
        Config.parse(new ByteArrayInputStream(CONFIG.getBytes(StandardCharsets.UTF_8)));

    String userspace = config.toAwgUserspaceString();
    assertTrue(userspace.contains("jc=4\n"));
    assertTrue(userspace.contains("h1=115-120\n"));
    assertTrue(userspace.contains("allowed_ip=10.0.0.0/8\n"));
    assertFalse(userspace.contains("PrivateKey ="));
    // The engine's bind parses address literals only, so the serialized body has to
    // carry the endpoint as an address. A hostname reaching it fails the whole
    // configuration, which is why a lookup failure has to be caught before the
    // device is configured (see AndroidAwgHost.start) rather than silently dropping
    // the endpoint line.
    assertTrue(userspace.contains("endpoint=198.51.100.1:51820\n"));

    new GoBackend(context);
    String version = org.amnezia.awg.GoBackend.awgVersion();
    assertNotNull(version);
    assertFalse(version.isEmpty());
    assertFalse("native AWG version must be discoverable", "unknown".equals(version));
  }
}
