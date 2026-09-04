# AffairMate · 事务伴侣

> An AI-powered personal affairs & time management app. Chat to maintain two knowledge bases (matters + four-dimension energy state), and let the AI schedule your day with reasons.

**内置 AI 的个人事务与时间管理软件**——通过日常对话，AI 自动维护两个属于你的知识库：事项库（内核三属性 + 开放扩展层）和状态认知库（身体/认知/情绪/动机四维电量）。安排模式下说一句「安排我接下来两小时」，AI 基于全部认知给出带理由的日程。

## ✨ Features

- 💬 **双模式对话**：沟通模式（聊事务与状态，AI 自动打标入库）/ 安排模式（一句话出带理由日程）
- 🧠 **双知识库**：事项库（时间要求/精力要求/独占性内核 + 无限扩展属性）；状态库（四维电量 + 时段轨迹历史）
- 🤖 **多供应商 LLM**：OpenAI 兼容协议，内置智谱 GLM（含 Coding Plan 专属通道）/ DeepSeek / Kimi 预设，自定义任意端点
- 📊 **24h 时间轴**：当日安排可视化进度条，四维状态卡片可点开看时段轨迹
- 🎙️ **语音输入**：按住说话、松开自动发送（Android 端完整支持）
- 🔒 **数据本地优先**：全部数据仅存本机（原子写入 + 备份自愈）；API Key 仅本地存储；遥测默认关闭

## 🚀 Getting Started

```bash
cd app
flutter pub get
flutter run                    # 或 flutter run -d windows
```

- Flutter 3.24.x / Dart 3.5.x
- Android minSdk 26（Android 8.0+）/ Windows 桌面预览
- 首次使用：启动后进入右上角「设置」→ 从预设添加供应商 → 填入 API Key

## 🗂 Project Layout

```
app/
  lib/
    data/    # 两库 schema、仓库层、原子 IO
    llm/     # Agent 提示词、多供应商客户端、语音输入
    pages/   # 沟通/安排/展示三页 + 设置页
    state.dart  # 全局状态中枢（双模式会话核心闭环）
  test/         # 单元 + e2e 协议测试（37 项）
  integration_test/  # UI 冒烟测试
tools/
  build_all.ps1       # 一键构建流水线（Windows + Android）
  release_public.ps1  # 私有开发仓 → 本公开仓的发布同步
```

## 🧪 Testing

```bash
cd app
flutter test                            # 37 unit + e2e tests
flutter test integration_test/smoke_test.dart -d windows   # UI smoke
```

## 📜 License

[MIT](./LICENSE)

## 🙏 About

本仓库是开发镜像仓（公开发布版）；完整的需求文档与开发过程记录在私有开发仓中维护。项目采用「文档驱动开发」方法论——需求（EARS 句式）、技术拆解、设计、实现记录四层文档驱动全生命周期。
