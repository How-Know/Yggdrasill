import 'package:yggdrasill_pb_export_ui/yggdrasill_pb_export_ui.dart';

import 'print_routing_service.dart';

Future<bool> printProblemBankExportPreviewFile(
  ProblemBankPreviewPrintRequest request,
) {
  return PrintRoutingService.instance.printFile(
    path: request.filePath,
    channel: PrintRoutingChannel.general,
    duplexMode: switch (request.duplexMode) {
      ProblemBankPreviewDuplexMode.oneSided => PrintDuplexMode.oneSided,
      ProblemBankPreviewDuplexMode.twoSidedLongEdge =>
        PrintDuplexMode.twoSidedLongEdge,
      ProblemBankPreviewDuplexMode.twoSidedShortEdge =>
        PrintDuplexMode.twoSidedShortEdge,
    },
    preferredPaperSize: request.paperSize,
    debugSource: 'problem_bank_server_preview',
  );
}
