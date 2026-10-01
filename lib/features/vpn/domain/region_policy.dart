import '../data/models.dart';
import '../data/platform_info.dart';

/// Pure region-selection policy extracted from the Regions tab.
///
/// Total peers per region; lowest wins for Quick Connect.
int regionLoad(Region r) => r.servers.fold<int>(0, (a, s) => a + s.activePeers);

/// True when this build can produce a datagram the node carrying [obfuscation]
/// can read.
///
/// A stock node reads anything. An obfuscated region's node runs the AmneziaWG
/// device, so it can only read obfuscated datagrams — and off Linux this build
/// has no obfuscated data plane (see `platform_info.dart`), so there is nothing
/// it could send that node.
bool formatServable(Obfuscation? obfuscation) =>
    obfuscation == null || !obfuscation.isAwg || awgDataPlaneSupported();

/// True when this build can dial [r]: at least one of its servers runs a data
/// plane this build can produce a datagram for.
///
/// A region's format is region-scoped — the discovery projection stamps the
/// region's descriptor onto every server — so in practice this is one answer for
/// the whole region. It is written per server so a mixed list, if one ever
/// exists, is not collapsed to whichever server happened to be listed first.
bool regionServable(Region r) =>
    r.servers.any((s) => formatServable(s.obfuscation));

/// Lowest-load region with dialable capacity that this build can actually
/// serve, or null when none qualifies.
///
/// A region whose format this build cannot run is not a candidate: dialing it
/// could only end in a start that refuses, and on the Auto path that would
/// surface as a failure rather than a fallback to a region that works.
Region? autoPickRegion(List<Region> regions) {
  Region? best;
  var bestLoad = 1 << 30;
  for (final r in regions) {
    if (!r.hasCapacity) continue;
    if (!regionServable(r)) continue;
    final load = regionLoad(r);
    if (load < bestLoad) {
      bestLoad = load;
      best = r;
    }
  }
  return best;
}

/// Regions matching [query] (region name/country, or any server
/// name/endpoint) ordered by ascending load. [query] is expected already
/// normalized (trimmed + lowercased) by the search field; an empty query
/// keeps every region.
List<Region> regionsVisible(List<Region> regions, String query) {
  final visible = query.isEmpty
      ? List.of(regions)
      : regions
            .where(
              (r) =>
                  r.name.toLowerCase().contains(query) ||
                  (r.countryCode?.toLowerCase().contains(query) ?? false) ||
                  r.servers.any(
                    (s) =>
                        s.name.toLowerCase().contains(query) ||
                        s.endpoint.toLowerCase().contains(query),
                  ),
            )
            .toList();
  visible.sort((a, b) => regionLoad(a).compareTo(regionLoad(b)));
  return visible;
}
