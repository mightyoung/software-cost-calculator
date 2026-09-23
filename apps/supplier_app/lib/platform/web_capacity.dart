import 'dart:convert';
import 'dart:js_interop';

import 'package:supplier_core/supplier_core.dart';

@JS('supplierPlatform.capacityEstimate')
external JSPromise<JSString> _estimate();

Future<CapacitySample> readWebCapacity() async {
  try {
    final value = jsonDecode((await _estimate().toDart).toDart) as Map;
    return CapacitySample(
      status: value['status'] as String,
      scope: 'web-storage-key',
      availableBytes: value['available'] as int?,
      usageBytes: value['usage'] as int?,
      quotaBytes: value['quota'] as int?,
      diagnostic: value['diagnostic'],
    );
  } catch (error) {
    return CapacitySample(
      status: 'failed',
      scope: 'web-storage-key',
      diagnostic: error,
    );
  }
}
