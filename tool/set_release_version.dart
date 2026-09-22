// Rewrites `pubspec.yaml`'s `version:` from a release tag.
//
// The git tag is the release source of truth: fastforge and the Android
// build both derive artifact names/versionName from pubspec, so a stale
// checked-in `version:` labels every tagged artifact with the wrong number.
//
// Usage (from `client/`):
//
//   dart run tool/set_release_version.dart [vX.Y.Z] [build-number]
//
// Both arguments fall back to the environment, so CI can call it with no
// arguments on a `v*` tag. The build number defaults to `GITHUB_RUN_NUMBER`
// (monotonic, required by Android's versionCode) and then to 1.
import 'dart:io';

void main(List<String> args) {
  final tag = args.isNotEmpty
      ? args.first
      : Platform.environment['GITHUB_REF_NAME'] ?? '';
  if (tag.isEmpty) {
    stderr.writeln(
      'usage: dart run tool/set_release_version.dart vX.Y.Z '
      '[build-number]',
    );
    exit(2);
  }

  final version = tag.startsWith('v') ? tag.substring(1) : tag;
  final match = RegExp(r'^(\d+\.\d+\.\d+)(?:[-+].*)?$').firstMatch(version);
  if (match == null) {
    stderr.writeln("release tag '$tag' is not vX.Y.Z");
    exit(2);
  }

  final build = args.length > 1
      ? args[1]
      : (Platform.environment['GITHUB_RUN_NUMBER'] ?? '1');

  final pubspec = File('pubspec.yaml');
  final updated = pubspec.readAsStringSync().replaceFirst(
    RegExp(r'^version:.*$', multiLine: true),
    'version: ${match.group(1)}+$build',
  );
  pubspec.writeAsStringSync(updated);
  stdout.writeln('Version set to ${match.group(1)}+$build from tag $tag');
}
