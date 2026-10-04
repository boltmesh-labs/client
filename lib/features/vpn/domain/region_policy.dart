import '../data/models.dart';

/// Pure region-selection policy extracted from the Regions tab.
///
/// Total peers per region; lowest wins for Quick Connect.
int regionLoad(Region r) => r.servers.fold<int>(0, (a, s) => a + s.activePeers);

/// Lowest-load region with dialable capacity, or null when none qualifies.
///
/// There is no format filter here, and deliberately so. A region's servers each
/// advertise a rung list, and every one of them leads with `native` — the stock
/// device every node runs — so every region is dialable on every platform. The
/// old filter asked the narrower question "can this build produce a datagram for
/// this node's *obfuscation* format", which on a platform with no obfuscated
/// data plane excluded the whole region even though its stock device was right
/// there and readable; it was a filter that could only ever exclude regions that
/// would have worked. Whether a *particular* rung is buildable is the ladder's
/// question at start time (see `conn_obfuscation.dart`), where the answer differs
/// per rung rather than per region.
Region? autoPickRegion(List<Region> regions) {
  Region? best;
  var bestLoad = 1 << 30;
  for (final r in regions) {
    if (!r.hasCapacity) continue;
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
