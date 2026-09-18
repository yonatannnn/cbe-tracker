/// Receipt processing diagnostics contain only fixed event names, counts,
/// and timing. Never pass receipt text, model responses, keys, or error bodies.
library;

import 'package:flutter/foundation.dart';

typedef ParseDiagnostic = void Function(String event);

void logParseDiagnostic(String event) => debugPrint('[ReceiptParse] $event');
