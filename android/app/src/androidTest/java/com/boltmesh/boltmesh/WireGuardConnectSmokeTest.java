package com.boltmesh.boltmesh;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertTrue;

import android.os.Build;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.filters.SdkSuppress;
import com.wireguard.config.Config;
import com.wireguard.config.InetEndpoint;
import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import org.junit.Test;
import org.junit.runner.RunWith;

/**
 * Exercises the configuration parsing at the start of the Android connect path.
 *
 * <p>This runs against the minified release APK on the API 30 floor and does not request VPN
 * consent or require a live server.
 */
@RunWith(AndroidJUnit4.class)
@SdkSuppress(minSdkVersion = 30)
public final class WireGuardConnectSmokeTest {
  private static final String CONFIG =
      "[Interface]\n"
          + "PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n"
          + "Address = 10.8.0.5/32\n"
          + "\n"
          + "[Peer]\n"
          + "PublicKey = AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=\n"
          + "Endpoint = 198.51.100.1:51820\n"
          + "AllowedIPs = 0.0.0.0/0\n";

  @Test
  public void parsesEndpointBeforeConnectingOnAndroid11() throws Exception {
    assertTrue(
        "the connect smoke test must run on the supported Android floor",
        Build.VERSION.SDK_INT >= 30);

    // Config.parse constructs InetEndpoint, which is the production
    // connect-path use of the WireGuard configuration model.
    Config config =
        Config.parse(new ByteArrayInputStream(CONFIG.getBytes(StandardCharsets.UTF_8)));
    assertNotNull(config);
    assertEquals(1, config.getPeers().size());

    InetEndpoint endpoint = config.getPeers().get(0).getEndpoint().orElse(null);
    assertNotNull(endpoint);
    assertEquals("198.51.100.1", endpoint.getHost());
    assertEquals(51820, endpoint.getPort());
  }
}
