import '../data/models.dart';

/// Pure region-selection policy extracted from the Regions tab.
///
/// Total peers per region; lowest wins for Quick Connect.
int regionLoad(Region r) => r.servers.fold<int>(0, (a, s) => a + s.activePeers);

/// Lowest-load region with dialable capacity, or null when none qualifies.
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
