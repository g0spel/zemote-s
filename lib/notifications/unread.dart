import 'package:flutter/foundation.dart';

/// 未读任务事件计数（通知在三重门控下真正发出时 +1；用户打开对应会话
/// 时清零）。设备管理入口显示总数徽标。
class UnreadEvents extends ChangeNotifier {
  UnreadEvents._();

  static final UnreadEvents instance = UnreadEvents._();

  final Map<String, int> _byTask = {};

  int get total =>
      _byTask.values.fold(0, (sum, count) => sum + count);

  void add(String taskId) {
    if (taskId.isEmpty) return;
    _byTask[taskId] = (_byTask[taskId] ?? 0) + 1;
    notifyListeners();
  }

  /// 打开某会话即清它的未读（弹回的重复事件不再计入，见门控）。
  void clearTask(String taskId) {
    if (_byTask.remove(taskId) == null) return;
    notifyListeners();
  }

  void clearAll() {
    if (_byTask.isEmpty) return;
    _byTask.clear();
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _byTask.clear();
  }
}
