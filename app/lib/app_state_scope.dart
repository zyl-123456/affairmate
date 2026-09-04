// AppState 依赖注入 · 避免引入 provider 包（C-003 精简理念）
// 从 main.dart 抽离，供各页面共享访问，避免设置页与主入口循环导入（M-022）。

import 'package:flutter/material.dart';

import 'state.dart';

class InheritedAppState extends InheritedWidget {
  final AppState app;
  const InheritedAppState({super.key, required this.app, required super.child});

  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<InheritedAppState>()!.app;

  @override
  bool updateShouldNotify(InheritedAppState oldWidget) => app != oldWidget.app;
}
