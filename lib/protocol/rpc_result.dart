const rpcSuccessStatuses = {'accepted', 'noop', 'duplicate'};

String? rpcStatusOf(Object? result) =>
    result is Map && result['status'] is String
        ? result['status'] as String
        : null;

/// Generic command acknowledgements accept the three idempotent outcomes.
/// Responses without a status remain compatible with direct/void RPCs.
bool isRpcSuccess(Object? result, {bool requireStatus = false}) {
  final status = rpcStatusOf(result);
  return status == null ? !requireStatus : rpcSuccessStatuses.contains(status);
}

bool isRpcRejected(Object? result, {bool requireStatus = false}) =>
    !isRpcSuccess(result, requireStatus: requireStatus);

String rpcFailureReason(Object? result) {
  if (result is! Map) return '$result';
  return '${result['reasonCode'] ?? result['message'] ?? result['status'] ?? 'rejected'}';
}
