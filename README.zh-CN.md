# dsh-superagent

**简体中文** | [English](README.md)

*本文件译自英文原文 [README.md](README.md)，如有出入，以英文原文为准。*

> **仅供研究参考的原型，并非 DeepSeek 官方产品。** 本代码源自我们团队的日常开发工作，其中大量工程工作由编码智能体完成。请把它当作研究代码，而不是可用于生产的软件。它仍可能包含缺陷，编码风格与工程实践也可能不一致。在你自己的环境中使用之前，请先审查并调整。
>
> 我们为公开发布做过适配，因此它与我们的内部版本、以及《Exploring Super-agent Design: Towards a More Autonomous Agent System》一文中描述的实现在细节上并不完全相同。文中讨论的部分设计属于未来发展方向，并未在此原型中实现。

dsh-superagent 是一个面向单个 GitHub 仓库的主动型编码智能体，以 [DeepSeek Harness](https://www.deepseek.com/en/harness/) 插件包（bundle）的形式发布。它监听 GitHub，也可选择监听飞书（Feishu）。当获得许可的人向智能体提出工作请求时，它会创建一个工作项，在独立的智能体会话和目录中处理，并在原对话中回复，例如给出一个 PR。Web 面板展示哪些事项需要人来处理。

这也是一种与智能体协作的工作方式：**尽可能少地占用人的注意力，尽可能多地交付价值。** 一个能为整个团队行动的智能体，也可能浪费整个团队的注意力；因此它只在被请求时、或团队明文规则允许时才行动，并且只在有人必须行动或可以使用结果时才发言。[docs/000-philosophy.md](docs/zh-CN/000-philosophy.md) 阐述了这一原则及其对运营者的要求。

## 安装配置

安装步骤较多，因此由智能体与你一起完成。请让你的编码智能体执行：

> 阅读本仓库中的 SETUP.zh-CN.md，并和我一起配置 dsh-superagent。

它一次只问一个简短问题，先展示完整计划，然后安装并配置所有内容。它遵循的正是 [SETUP.md](SETUP.zh-CN.md)。

## 文档

按顺序阅读编号文档；每一篇只依赖它前面的内容。

- [000 理念](docs/zh-CN/000-philosophy.md)
- [001 领域模型](docs/zh-CN/001-domain.md)
- [002 授权](docs/zh-CN/002-authorization.md)
- [003 执行](docs/zh-CN/003-execution.md)
- [004 提示词](docs/zh-CN/004-prompts.md)
- [005 面板](docs/zh-CN/005-panel.md)
- [006 部署](docs/zh-CN/006-deployment.md)：手动安装、配置、升级与故障排查
- [007 架构](docs/zh-CN/007-architecture.md)
- [008 实战手册](docs/zh-CN/008-cookbook.md)：新增一种来源（Source）

## 开发

`pnpm check` 会运行类型检查、测试和构建。

## 许可证

[MIT](LICENSE)
