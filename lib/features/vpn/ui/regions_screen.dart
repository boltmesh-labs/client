import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/log.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../data/models.dart';
import '../domain/region_policy.dart';
import '../state/vpn_providers.dart';
import 'regions/region_search_field.dart';
import 'regions/region_tiles.dart';
import 'regions/switch_feedback.dart';

/// Region list from GET /vpn-regions. Regions with `servers: []` have
/// no dialable capacity and are shown disabled.
///
/// The connection slice watched here is only what the list needs
/// (phase/targets): traffic and health ticks don't rebuild the list.
///
/// Discovery is consumed through [WidgetRef.listenManual] rather than
/// `ref.watch` (see [_RegionsScreenState._regionsSub]): a watch subscription
/// cached by this element can be closed underneath it by riverpod#4806,
/// which then throws on every rebuild and kills the tab.
class RegionsScreen extends ConsumerStatefulWidget {
  const RegionsScreen({super.key});

  @override
  ConsumerState<RegionsScreen> createState() => _RegionsScreenState();
}

class _RegionsScreenState extends ConsumerState<RegionsScreen> {
  final _search = TextEditingController();
  String _query = '';

  /// Discovery consumed manually instead of via `ref.watch`.
  ///
  /// riverpod#4806: a `ConsumerStatefulElement` can keep a *closed* watch
  /// subscription in its build-time dependency cache when an autoDispose
  /// provider is disposed while the element stays mounted (background/tab
  /// churn + `ref.keepAlive`), and every later rebuild then throws
  /// `called ProviderSubscription.read on a subscription that was closed`.
  /// Manual listeners live in a separate list that is never reused from the
  /// build-time cache, so they can't be read after close. Non-weak, so the
  /// provider stays alive for as long as the tab is.
  ProviderSubscription<AsyncValue<List<Region>>>? _regionsSub;
  AsyncValue<List<Region>> _regions = const AsyncValue.loading();

  @override
  void initState() {
    super.initState();
    final sub = ref.listenManual(regionsProvider, (_, next) {
      if (!mounted) return;
      setState(() => _regions = next);
    });
    _regionsSub = sub;
    _regions = sub.read();
    // One automatic retry for a failed initial discovery: the shell keeps
    // this tab mounted for its lifetime (IndexedStack), so this only runs
    // once at startup. A fresh list is reused as-is (no spinner flash);
    // later failures are retried by the in-list Retry button or by
    // pull-to-refresh. Deferred post-frame so the listener above is
    // subscribed first.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_regions.hasError) {
        ref.invalidate(regionsProvider);
      }
    });
  }

  @override
  void dispose() {
    _regionsSub?.close();
    _search.dispose();
    super.dispose();
  }

  /// Quick Connect (Auto): clears any pin back to Auto, then dials the
  /// freshly picked lowest-load region one-shot — the state stays
  /// unpinned so later connects re-pick instead of sticking.
  Future<void> _quickConnect() async {
    final ctl = ref.read(connectionProvider.notifier);
    await ctl.selectAuto();
    // The awaited persist can outlive a logout that tears this screen down;
    // never issue the connect into a dead session. Logout during the connect
    // itself is superseded by the controller's teardown/session guards.
    if (!mounted) return;
    await ctl.quickConnect();
    if (!mounted) return;
    showSwitchFeedback(context, ref.read(connectionProvider));
  }

  Future<void> _switchTo({String? regionId, String? serverId}) async {
    final ctl = ref.read(connectionProvider.notifier);
    await ctl.switchServer(regionId: regionId, serverId: serverId);
    if (!mounted) return;
    showSwitchFeedback(context, ref.read(connectionProvider));
  }

  /// Manual discovery refresh shared by the AppBar button and pull-to-refresh.
  /// Snacks the outcome so release builds
  /// — where [AppLog] is compiled out — still show whether the tap worked.
  /// Failures are also logged to the debug console.
  Future<void> _refreshRegions() async {
    final l10n = AppLocalizations.of(context);
    try {
      final regions = await ref.refresh(regionsProvider.future);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.regionsRefreshed(regions.length))),
      );
    } catch (e) {
      AppLog.error('regions refresh tapped failed', e);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.regionsLoadError)));
    }
  }

  /// Scrollable, centered placeholder so the surrounding [RefreshIndicator]
  /// has a scrollable child in the loading/error branches too (a bare
  /// [Center] cannot be pulled). Fills the viewport so the pull gesture is
  /// available anywhere.
  Widget _messageState(Widget child) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: constraints.maxHeight),
        child: Center(child: child),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final regions = _regions;
    final conn = ref.watch(
      connectionProvider.select((c) => (c.phase, c.regionId, c.serverId)),
    );
    final busy = conn.$1 == ConnPhase.working;
    final pinnedRegionId = conn.$2;
    final pinnedServerId = conn.$3;
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.navRegions),
        actions: [
          IconButton(
            key: const Key('refreshRegions'),
            icon: const Icon(Icons.refresh),
            tooltip: l10n.regionsRefresh,
            onPressed: busy ? null : _refreshRegions,
          ),
        ],
      ),
      body: Column(
        children: [
          RegionSearchField(
            controller: _search,
            onQuery: (q) => setState(() => _query = q),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refreshRegions,
              child: regions.when(
                loading: () => _messageState(const CircularProgressIndicator()),
                // Raw exception text is never shown; the provider already
                // logs it. The retry button (and pull-to-refresh) gives the
                // error branch an affordance instead of a dead end.
                error: (e, _) => _messageState(
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Text(
                          l10n.regionsLoadError,
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(height: 12),
                      FilledButton.tonal(
                        onPressed: busy ? null : _refreshRegions,
                        child: Text(l10n.commonRetry),
                      ),
                    ],
                  ),
                ),
                data: (list) {
                  final visible = regionsVisible(list, _query);
                  final best = autoPickRegion(list);
                  return ListView.builder(
                    // Row 0 is the Quick Connect header; regions follow (or a
                    // single "no match" row when the filter empties the list).
                    itemCount: 1 + (visible.isEmpty ? 1 : visible.length),
                    itemBuilder: (context, i) {
                      if (i == 0) {
                        return Column(
                          children: [
                            QuickConnectTile(
                              best: best,
                              busy: busy,
                              // Auto is selected iff nothing is pinned; a
                              // server row only highlights when explicitly
                              // pinned, so Auto never marks a server.
                              selected:
                                  best != null &&
                                  pinnedRegionId == null &&
                                  pinnedServerId == null,
                              onTap: _quickConnect,
                            ),
                            const Divider(),
                          ],
                        );
                      }
                      if (visible.isEmpty) {
                        return ListTile(title: Text(l10n.regionsNoMatch));
                      }
                      final r = visible[i - 1];
                      // Key by region id: the list is re-sorted by live load,
                      // so without it ExpansionTiles would keep state from
                      // whichever region previously held this index.
                      return RegionExpansionTile(
                        key: ValueKey(r.id),
                        region: r,
                        load: regionLoad(r),
                        busy: busy,
                        selectedServerId: pinnedServerId,
                        onServerTap: (id) => _switchTo(serverId: id),
                      );
                    },
                  );
                },
              ),
            ),
          ),
          if (busy)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(l10n.regionsSwitching),
            ),
        ],
      ),
    );
  }
}
