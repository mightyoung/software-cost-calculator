export 'workspace_factory_unsupported.dart'
    if (dart.library.io) 'workspace_factory_native.dart'
    if (dart.library.js_interop) 'workspace_factory_web.dart';
