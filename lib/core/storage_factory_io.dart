import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'linux_file_secure_storage.dart';

FlutterSecureStorage platformSecureStorage(FlutterSecureStorage fallback) =>
    Platform.isLinux ? LinuxFileSecureStorage() : fallback;
