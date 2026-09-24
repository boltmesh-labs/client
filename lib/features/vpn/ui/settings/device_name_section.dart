import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/log.dart';
import '../../../../l10n/gen/app_localizations.dart';
import '../../data/device_store.dart';

/// Device display name editor. Self-contained: owns its controller and
/// loads the stored name on mount.
class DeviceNameSection extends ConsumerStatefulWidget {
  const DeviceNameSection({super.key});

  @override
  ConsumerState<DeviceNameSection> createState() => _DeviceNameSectionState();
}

class _DeviceNameSectionState extends ConsumerState<DeviceNameSection> {
  final _name = TextEditingController();

  @override
  void initState() {
    super.initState();
    unawaited(
      ref.read(deviceStoreProvider).deviceName().then((v) {
        if (!mounted) return;
        // Only seed an untouched field: a slow read must never clobber what the
        // user has already typed. Place the cursor at the end.
        if (v != null && _name.text.isEmpty) {
          _name.value = TextEditingValue(
            text: v,
            selection: TextSelection.collapsed(offset: v.length),
          );
        }
      }, onError: (Object e) => AppLog.error('device name load failed', e)),
    );
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(l10n.settingsDeviceNameLabel),
        TextField(
          controller: _name,
          maxLength: maxDeviceNameLength,
          decoration: InputDecoration(hintText: l10n.settingsDeviceNameHint),
        ),
        const SizedBox(height: 8),
        FilledButton.tonal(
          onPressed: () async {
            final v = _name.text.trim();
            if (v.isEmpty) {
              _snack(l10n.settingsEnterNameFirst);
              return;
            }
            // Mirror the backend's strip + length contract: `maxLength` counts
            // grapheme clusters, so a name of combining sequences can still
            // exceed the code-point limit a 422 is raised against.
            if (v.runes.length > maxDeviceNameLength) {
              _snack(l10n.settingsDeviceNameTooLong(maxDeviceNameLength));
              return;
            }
            await ref.read(deviceStoreProvider).setDeviceName(v);
            _snack(l10n.settingsDeviceNameSaved);
          },
          child: Text(l10n.settingsSaveName),
        ),
      ],
    );
  }
}
