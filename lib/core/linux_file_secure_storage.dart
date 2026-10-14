import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Linux secrets stored as JSON in the user's data directory. The file is
/// readable only by its owner; it is not encrypted.
class LinuxFileSecureStorage extends FlutterSecureStorage {
  LinuxFileSecureStorage();

  static Future<void> _queue = Future<void>.value();

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final result = _queue.then((_) => operation());
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<File> _file() async {
    final dataHome = Platform.environment['XDG_DATA_HOME'];
    final home = Platform.environment['HOME'];
    if ((dataHome == null || dataHome.isEmpty) &&
        (home == null || home.isEmpty)) {
      throw const FileSystemException('No user data directory is available');
    }
    final root = dataHome?.isNotEmpty == true
        ? dataHome!
        : '$home${Platform.pathSeparator}.local${Platform.pathSeparator}share';
    final directory = Directory('$root${Platform.pathSeparator}boltmesh');
    await directory.create(recursive: true);
    await _chmod('700', directory.path);
    final file = File('${directory.path}${Platform.pathSeparator}secrets.json');
    if (await file.exists()) await _chmod('600', file.path);
    return file;
  }

  Future<void> _chmod(String mode, String path) async {
    final result = await Process.run('chmod', <String>[mode, path]);
    if (result.exitCode != 0) {
      throw FileSystemException(
        'Could not restrict secret storage permissions',
        path,
      );
    }
  }

  Future<Map<String, dynamic>> _readAll(File file) async {
    if (!await file.exists()) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map ? decoded.cast<String, dynamic>() : {};
    } on FormatException {
      return <String, dynamic>{};
    }
  }

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) => _serialized(() async {
    final values = await _readAll(await _file());
    final value = values[key];
    return value is String ? value : null;
  });

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) => _serialized(() async {
    final file = await _file();
    final values = await _readAll(file);
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
    final temporary = File('${file.path}.tmp');
    if (await temporary.exists()) await temporary.delete();
    await temporary.create();
    await _chmod('600', temporary.path);
    await temporary.writeAsString(jsonEncode(values), flush: true);
    await temporary.rename(file.path);
    await _chmod('600', file.path);
  });

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) => write(key: key, value: null);
}
