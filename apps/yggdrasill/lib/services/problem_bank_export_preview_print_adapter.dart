import 'print_routing_service.dart';

Future<bool> printProblemBankExportPreviewFile(
  String filePath, {
  String preferredPaperSize = '',
}) {
  return PrintRoutingService.instance.printFile(
    path: filePath,
    channel: PrintRoutingChannel.general,
    preferredPaperSize: preferredPaperSize,
    debugSource: 'problem_bank_server_preview',
  );
}
