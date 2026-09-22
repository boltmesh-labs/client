import 'package:dio/dio.dart';

/// Web has no per-request certificate hook, so pinning cannot be installed.
/// Always reports failure; callers only reach this when a pin is configured,
/// which [configureTlsPinning] treats as a misconfiguration (see there).
bool installSpkiPinning(Dio dio, List<String> pins) => false;
