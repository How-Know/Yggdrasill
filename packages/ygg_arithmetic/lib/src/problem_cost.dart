import 'policy.dart';

enum CostKind { operation, reasoning }

class CostNode {
  const CostNode({
    required this.id,
    required this.kind,
    required this.unitCost,
    required this.quantity,
    this.parentId,
    this.counts = true,
  });

  final String id;
  final CostKind kind;
  final double unitCost;
  final int quantity;
  final String? parentId;

  /// 부모와 같은 작업을 또 세면 false로 둔다.
  final bool counts;
}

class ProblemCost {
  const ProblemCost({
    required this.operation,
    required this.reasoningUsed,
    required this.total,
    required this.operationShare,
    required this.reasoningShare,
    required this.basis,
    required this.lambdaApplied,
    required this.anchorGap,
    required this.warnings,
  });

  final double operation;
  final double reasoningUsed;
  final double total;
  final double? operationShare;
  final double? reasoningShare;
  final ReasoningBasis basis;
  final bool lambdaApplied;
  final double anchorGap;
  final List<String> warnings;
}

ProblemCost problemCost({
  required List<CostNode> nodes,
  required ModelPolicy policy,
  ReasoningBasis? basis,
}) {
  final usedBasis = basis ?? policy.reasoningBasis;
  final warnings = <String>[];
  final countedParents = {
    for (final node in nodes)
      if (node.counts && node.parentId == null) node.id,
  };
  var operation = 0.0;
  var reasoning = 0.0;
  for (final node in nodes) {
    if (!node.counts) continue;
    if (node.quantity < 0 || node.unitCost < 0 || node.unitCost.isNaN) {
      throw ArgumentError('비용과 횟수는 0 이상이어야 합니다.');
    }
    if (node.parentId != null && countedParents.contains(node.parentId)) {
      warnings.add('노드 ${node.id}는 부모 ${node.parentId}와 같은 작업이라 합산에서 뺐습니다.');
      continue;
    }
    final amount = node.unitCost * node.quantity;
    if (node.kind == CostKind.operation) {
      operation += amount;
    } else {
      reasoning += amount;
    }
  }
  var lambdaApplied = false;
  var reasoningUsed = reasoning;
  if (usedBasis == ReasoningBasis.raw) {
    lambdaApplied = true;
    reasoningUsed = policy.reasoningLambdaHypothesis * reasoning;
    warnings.add('가중 전 연구 예시입니다. 운영 문항 점수는 이 배수를 다시 곱하지 않습니다.');
  } else if (usedBasis == ReasoningBasis.unknown) {
    warnings.add('사고 점수가 가중 전인지 가중 후인지 몰라 배수를 곱하지 않았습니다.');
  } else if (policy.reasoningLambdaHypothesis != 1) {
    warnings.add('사고 점수는 이미 가중된 합입니다. 가설 배수 ${policy.reasoningLambdaHypothesis}는 다시 곱하지 않습니다.');
  }
  final total = operation + reasoningUsed;
  final shareOp = total == 0 ? null : operation / total;
  final shareR = total == 0 ? null : reasoningUsed / total;
  return ProblemCost(
    operation: operation,
    reasoningUsed: reasoningUsed,
    total: total,
    operationShare: shareOp,
    reasoningShare: shareR,
    basis: usedBasis,
    lambdaApplied: lambdaApplied,
    anchorGap: total - policy.anchorScore,
    warnings: warnings,
  );
}

class CostProposal {
  const CostProposal({
    required this.proposed,
    required this.comparable,
    required this.note,
  });

  final double? proposed;
  final bool comparable;
  final String note;
}

/// 같은 프로토콜의 기준 시간 비율로 비용을 가늠한다. 운영 비용을 바꾸지 않는다.
CostProposal proposeCost({
  required double anchorCost,
  required double anchorReferenceMs,
  required double targetReferenceMs,
  required bool sameProtocol,
  required bool empirical,
}) {
  if (!sameProtocol) {
    return const CostProposal(proposed: null, comparable: false, note: '프로토콜이 달라 비용을 견주지 않습니다.');
  }
  if (anchorCost <= 0 || anchorReferenceMs <= 0 || targetReferenceMs <= 0) {
    return const CostProposal(proposed: null, comparable: false, note: '앵커 비용과 기준 시간은 0보다 커야 합니다.');
  }
  final proposed = anchorCost * targetReferenceMs / anchorReferenceMs;
  final note = empirical
      ? '같은 프로토콜의 적용 기준 시간 비율로 가늠한 제안입니다. 승인 전에는 운영 비용을 바꾸지 않습니다.'
      : '최초 시드 시간으로 가늠한 가설입니다. 실측 기준이 아니므로 운영 비용에 넣지 않습니다.';
  return CostProposal(proposed: proposed, comparable: true, note: note);
}
