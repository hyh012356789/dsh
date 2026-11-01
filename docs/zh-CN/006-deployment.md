# 006 部署

> 本文件译自英文原文 [006-deployment.md](../006-deployment.md)。如有出入，以英文原文为准。

本指南介绍如何安装、配置和运维 dsh-superagent，涵盖账号、启动检查、升级与故障排查，并建立在 [001 领域模型](001-domain.md)至[005 面板](005-panel.md)的基础之上。

## 运行内容

- **一个专用的 DeepSeek Harness profile**，本指南中称为 `superagent`。请从 Web profile 模板创建它。它会加载插件包，并在 `127.0.0.1` 上为其面板提供服务。请让它与你日常使用的 profile 保持分离：插件会修改进程范围的 `PATH` 和 git 设置，而且其进程需要独立重启和升级。
- **一个智能体 GitHub 账号。** 智能体通过仅以该账号登录的 GitHub CLI，以该账号的身份发表评论、推送分支并创建 PR。
- **可选：** 用于处理聊天请求的飞书机器人。

插件配置保存状态目录和机器限制。其余内容请通过面板配置：用来源设置仓库和账号，用策略设置允许列表，用执行设置工作者目录和命令。

### 权限与隔离

插件包为执行器定义了 `dsh-superagent-worker`，为主 Session 定义了 `dsh-superagent-router`。它们会出现在 DeepSeek Harness 的预设列表中，但只供 dsh-superagent 使用。不要为个人会话选择它们，也不要禁用它们的配置行。应用需要靠它们创建和恢复会话。

在 Web UI 中打开一个空白的受管会话时，可能会选中该 profile 的默认预设。dsh-superagent 会在首轮开始前恢复其角色专用的预设。

两个预设都以运营者的操作系统用户身份、在 `danger-full-access` 下运行，并读取已订阅线程中的消息。账号包装器默认只选用智能体的凭据，但并不隔离进程。工作者可以按路径执行程序，并读取运营者的主目录。如需隔离，请使用仅包含智能体凭据的专用操作系统账号。

## 前提条件

- Node.js 22.19+ 或 24+、pnpm、git 2.32+、Python 3.8+ 以及 tmux
- GitHub CLI（`gh`）2.48 或更高版本。来源的 CLI 字段必须指向 `gh` 或 `lark-cli` 包装器；宿主依赖它们的子命令和输出格式。
- github.com 上的一个仓库；不支持 GitHub Enterprise Server。若要为每个工单创建一份检出，请保留一个本地克隆，让 prepare 命令可以基于它添加工作树。如果该仓库使用 Git LFS，请安装 `git-lfs`。
- 为 DeepSeek Harness 配置的模型提供方。除非评估或执行设置另行指定，dsh-superagent 使用该 profile 的默认模型。
- 使用飞书时：`lark-cli`（已在 1.0.90 上测试），以及一个带机器人的飞书或 Lark 应用

## 账号

### 智能体的 GitHub 账号

1. 为智能体创建一个 GitHub 用户账号，并授予其对该仓库的写权限。GitHub App 不能充当智能体，因为 dsh-superagent 需要读取该账号的通知。
2. 为它准备一个只使用其自身凭据的 GitHub CLI：

   ```sh
   mkdir -p ~/.local/bin
   cat > ~/.local/bin/gh-agent <<'EOF'
   #!/bin/sh
   GH_CONFIG_DIR="$HOME/.config/gh-agent" exec gh "$@"
   EOF
   chmod +x ~/.local/bin/gh-agent
   gh-agent auth login
   gh-agent api user --jq .login
   ```

   以智能体账号登录；最后一条命令会打印它的登录名。dsh-superagent 以同样的方式读取登录名。

### 飞书机器人（可选）

1. 创建一个具备机器人能力的自建应用。授予其接收消息事件、读取和发送聊天消息、读取聊天成员的权限，然后发布应用版本。
2. 为机器人准备专属的 `lark-cli` 配置（限定为机器人身份），以及一个包装器：

   ```sh
   LARKSUITE_CLI_CONFIG_DIR="$HOME/.lark-cli-dsh-superagent" lark-cli config init --app-id <cli_…> --app-secret-stdin
   LARKSUITE_CLI_CONFIG_DIR="$HOME/.lark-cli-dsh-superagent" lark-cli config strict-mode bot --global
   cat > ~/.local/bin/lark-bot <<'EOF'
   #!/bin/sh
   export LARKSUITE_CLI_CONFIG_DIR="$HOME/.lark-cli-dsh-superagent"
   exec lark-cli "$@"
   EOF
   chmod +x ~/.local/bin/lark-bot
   ```

   第一条命令从标准输入读取应用密钥。请使用独立的配置目录：`lark-cli` 对每个应用 ID 只允许一个配置，而你个人的配置中可能已经包含该应用的用户登录。

   宿主会拒绝能够以用户身份操作的 CLI。它会从机器人配置中读取应用 ID、飞书/Lark 品牌以及机器人的 `open_id`。

   两套配置共享应用密钥的钥匙串条目。若只想删除机器人配置，请删除其目录；不要运行 `lark-cli config remove`，那会影响共享的密钥。

## 安装

在没有 `superagent` profile 的机器上，运行一次以下代码块：

```sh
npm install -g @deepseek-ai/dsh@0.2.1-rc.3
git clone <this repository> dsh-superagent && cd dsh-superagent
pnpm install && pnpm build
dsh superagent --from-default-profile web --dump-config > /dev/null
dsh plugin --profile superagent add "link:$PWD"
```

上面固定指定的版本已公开发布；其他版本必须满足 `package.json` 中 `engines.dsh` 的要求。

第四条命令会基于 DeepSeek Harness 的 Web 模板创建 `~/.dsh/profiles/superagent`。第五条命令安装本插件包。设置 `DSH_HOME` 可以改变默认的 `~/.dsh` 目录位置。

profile 创建命令只应在全新安装时运行。如果 profile 已存在，该命令会替换它并删除其 `cordis.patch.yml`，包括机器配置。升级时不要使用它。

## 机器配置

将 [examples/profile.cordis.patch.yml](../../examples/profile.cordis.patch.yml) 复制到 `~/.dsh/profiles/superagent/cordis.patch.yml`（覆盖该文件），并替换其中的每个 `<placeholder>`。使用飞书时，还要在该文件中启用 `dsh-superagent-feishu` 条目。`webserver` 条目设置面板端口。

| 键 | 是否必需 | 含义 |
| --- | --- | --- |
| `stateDir` | 是 | 绝对路径：数据库、锁文件、`worker-bin` 中的命令 shim、智能体的 git 配置，以及默认情况下 `work` 中的工单目录。升级前请备份 |
| `promptMaxChars`、`admissionContextMaxPages`、`admissionContextTimeoutMs` | 否 | 已保存的提示词配置的最大规模，以及一次研判在限定时间内读取多少个线程页 |

首次启动后，可在**设置 → 部署**或 DeepSeek Harness 插件管理器中修改机器限制。更改无需重启即可生效。`stateDir` 无法在那里修改。无效的值或未知的配置键会阻止启动；日志会指出是哪个键。

## 启动与停止

```sh
scripts/dsh-superagent start
scripts/dsh-superagent status
```

`start` 在 tmux 会话 `dsh-superagent`（其他 profile 则为 `dsh-<profile>`）中运行 `dsh --profile superagent`。它最多等待一分钟，直到运行时就绪或报告某项初始化要求。首次运行时，它会打印缺失的初始化信息。它会拒绝重复实例，包括在本脚本之外启动的实例。

`stop` 和 `restart` 会请求优雅关闭，并最多等待五分钟让执行器结束。它们绝不会强制终止进程，也不会影响其他 tmux 会话。

`status` 打印进程 ID、健康状况和初始化问题。若要使用其他 profile 或端口，请使用 `--profile` 和 `--url`，或设置 `DSH_SUPERAGENT_PROFILE` 和 `DSH_SUPERAGENT_URL`。

`status`、`start` 和 `restart` 会以以下四种退出码之一退出：

| 退出码 | 含义 |
| --- | --- |
| 0 | 服务正常运行 |
| 1 | 服务未运行、运行了两份、无响应，或运行时报告错误；重启可能修复 |
| 2 | 服务在运行，但运行时之外的部分（例如某个来源或策略同步 `sync:<source id>`）报告错误；重启无法修复 |
| 3 | 服务在运行并等待完成初始化；重启无法修复 |

仍在启动中的来源视为正常运行。初始化无法检查的飞书机器人同样如此。

`status` 在 `errors` 下返回失败的部分及其详情，在 `setup` 下返回初始化要求。`start` 和 `restart` 会把这些问题的逐行打印出来；如果服务始终未能启动，它们会以 1 退出。只有主动执行的 `stop` 才会暂停自动恢复。

每个 profile 都会将日志和控制文件存放在 `.artifacts/` 下：

- 启动日志：`dsh-superagent-<profile>-<date>-<time>-<pid>.log`，其中的 pid 属于该脚本。仅保留最新的 20 个。
- 控制文件：`control/profiles/<profile>/`，包含停止标记、锁文件和进程 ID。

打开日志中打印的 URL，然后在侧边栏中选择 **Superagent**。

### 每小时检查

请在你日常使用的 DeepSeek Harness profile（而不是 `superagent`）中创建每小时检查。它必须在智能体服务停止时仍持续运行。在该 profile 中让智能体使用以下提示词创建每小时调度，并填入检出路径：

```text
Check dsh-superagent: run `scripts/dsh-superagent --profile superagent status` in <checkout>. Exit 0: do nothing and say nothing. Exit 2: do not restart; tell me each part under `errors` with its detail, unless you already told me about the same ones. Exit 3: do not restart; tell me what `setup` says setup needs, unless you already told me. If it reports manually_stopped: true, leave it stopped. Otherwise (exit 1) run `scripts/dsh-superagent --profile superagent --respect-stop restart`, which exits the same way: 0 means it recovered, so say nothing; 2 and 3 are reported as above; if it exits 1 or fails otherwise, read the newest .artifacts/dsh-superagent-superagent-*.log and the Troubleshooting section of docs/006-deployment.md, fix what you can, and tell me what was wrong and what you did.
```

`--respect-stop` 会保留主动停止的状态。只有 `stop` 会写入标记；`start` 会清除标记。`restart` 不写入标记，因此该检查可以恢复一次关闭超时的重启。

## 设置

在开始轮询或处理工作之前，初始化必须成功。概览会列出缺失的要求，并链接到相应的设置项。更改设置会重新运行初始化。如果你在应用之外修复了某些内容（例如 CLI 认证），请选择**再次检查**。

1. **来源。** 设置 GitHub 仓库（`owner/name`）和智能体 CLI，例如 `/home/me/.local/bin/gh-agent`。请求通常通过智能体账号的通知到达。提及该账号的新 Issue 或新评论会在下一次轮询时到达；而通过编辑已有 Issue 正文添加的提及则不会。请改为发表新评论。使用飞书时，请设置机器人 CLI、聊天、每个聊天是接收全部消息还是仅接收提及，以及是否接收私信。
2. **策略。** 两条示例规则可以编辑或删除。在**每个来源**下，添加可以请求工作的 GitHub 账号和飞书用户；在列表中有成员之前，任何请求都无法成为工单。使用飞书时，可以选择一个聊天作为该列表的同步来源，同步会在启动时以及点击**立即同步**时进行。
3. **执行。** 目录根和一个 prepare 命令。若要让每个工单都有一份该仓库的检出：

   ```sh
   git -C /home/me/src/widgets fetch --no-tags "https://github.com/$DSH_SUPERAGENT_GITHUB_REPOSITORY.git" "${DSH_SUPERAGENT_GITHUB_PR_HEAD:-HEAD}:refs/dsh-superagent/$DSH_SUPERAGENT_TICKET" &&
   git -C /home/me/src/widgets worktree add -b "agent/$DSH_SUPERAGENT_NAME" "$DSH_SUPERAGENT_DIR" "refs/dsh-superagent/$DSH_SUPERAGENT_TICKET"
   ```

   将个人 CLI（例如已登录到你本人账号的 CLI）列为禁止命令。
4. **提示词。** 设置团队部分：GitHub 披露声明行、审查机器人、提交作者以及自动合并条件。

### 管理 API

面板使用一个本地 HTTP API，智能体也可以调用它。`SETUP.md` 用它保存设置，服务脚本则读取 `GET state`。

向 `http://127.0.0.1:<port>/orchestrator/api/` 发送请求，并带上 `x-orchestrator-request: 1`。主机必须是 `127.0.0.1:<port>` 或 `localhost:<port>`。缺少该头部，或 `Origin` 来自其他站点，会收到 403。

通过 API 保存与在面板中保存的权限相同。与通过主 Session 的工具所做的保存不同，它们可以更改执行环境以及设置中的账号字段。

智能体可以依赖以下路由和字段。`src/app/api.ts` 中的其他路由供面板使用，并会随面板一起变化。

| 请求 | 返回 |
| --- | --- |
| `GET state` | 所有页面都会读取的数据：`setup`，含 `problem` 和 `feishuProblem`（各为 `null`，或一个带 `place`、`code`、`values` 和 `detail` 的初始化问题），以及初始化解析出账号后的 `accounts`；`health`，即下文中每个部分一个条目，含 `state`（`starting`、`ready`、`paused` 或 `error`）、`detail` 和 `at`；`load`，即执行器 Session 的 `running`、工单的 `queued` 和 `maxWorkers`；`paused`；以及 `masterId` |
| `GET settings` | `blocks`：`policy`、`eval` 和 `executor`，各含其 `value` 与 `revision`；`sources`：来源实例，各含 `id`、`kind`、`installed`、其区块的 `value`（`{"enabled": …, "config": {…}}`）和 `revision`、其 kind 对应的表单，以及有初始化问题时的 `problem`；`policyVersion`；以及 `environment`，即执行环境的 `root` 和 `variables` |
| `GET sources` | 每个来源的状态：`state`（`missing`、`off`、`error`、`setup`、`starting`、`paused` 或 `ready`）、其各部分的 `health`、其初始化 `problem`、最近一天的 `stats`、该天内被其 `filtered` 的触发，以及该天内被其 `dropped` 的消息（最新丢弃的排在最前），每条含 `channel`、`preview`、所属工单的 `ticket`（`id` 和 `title`，若该消息属于某个工单）、存储中存有该消息时的 `thread`，以及 `dropped.at` 和 `dropped.reason`（`channelGone` 或 `channelIgnored`） |
| `PUT settings/<block>` 携带 `{"value": …, "revision": n}` | 保存一个区块：`saved`、该区块新的 `revision`、`policy_changed` 和 `restarting`。`value` 是整个区块，其结构同 `GET settings`；缺少的键取默认值 |
| `POST executor/pause` 携带 `{"paused": true}` 或 `false` | 暂停或恢复处理：`paused` |
| `POST setup/check` | 通过重启 dsh-superagent 重新运行初始化：`restarting: true`。若没有需要修复的初始化项则拒绝 |
| `POST policy-sync/<source id>` | 立即同步该来源的允许列表：`policy`，即该来源已保存的部分 |
| `GET prompts`、`PUT prompts` 携带 `{"config", "baseRevision"}` | 读取提示词配置：`current`（含其 `revision` 和 `config`）、`defaults`、`sections`（团队部分，按会话读取它们的顺序）、`skillName`（团队技能名称的模式）、`builtin`（团队技能不能使用的名称）以及 `skillPrefix`（会话加载技能名称时所用前缀）。或者保存它：返回新的 `revision` |
| `POST tickets/<id>/retry`、`POST tickets/<id>/stop` | 重试或停止一个工单，与面板中的操作相同 |

健康条目按职责分组：

| 条目 | 报告内容 |
| --- | --- |
| `runtime` | 应用本身 |
| `models` | 等待模型预算重试的会话 |
| `evals` | 最近一小时内不可用、且此后没有判定或驳回的评估 |
| `assessment`、`launch`、`delivery`、`relay`、`notice`、`reply` | [003 执行](003-execution.md)中描述的已存储工作；交付统计等待中的工作，回复则涵盖渠道消息 |
| `worker` | 执行器 Session 的事件处理；在首次失败后出现 |
| `github`、`feishu`、`history` | 来源轮询、事件和历史恢复 |
| `sync:<source id>` | 允许列表同步 |

拒绝响应包含状态码和 `error`（英文原文）：

- 400：值无效（`issues`，各含其 `path`）、账号检查失败（`setup`）、固定拒绝（`code` 和 `values`），或请求体不是 JSON、或体积过大。
- 404：内容不存在。
- 409：修订版本已过期。
- 500：其他错误。

各配置块如下：

- `source:github`、`source:feishu`：`{"enabled": true, "config": {…}}`。GitHub 的配置包含 `repository` 和 `cli`，以及默认关闭的开关 `observeIssues`、`observePulls`、`observeComments` 和 `observeCi`，这些开关会接收仓库中每个新的 Issue、新的 PR 和评论，以及默认分支的 CI；飞书的配置包含 `cli`、形如 `[{"chatId": "oc_…", "name": "…", "listen": "mentions"}]` 的 `chats`（`listen` 也可为 `"all"`）、`directMessages`，以及取值为 `"none"` 或 `"mentions"` 的 `otherChats`。
- `policy`：`{"rules": […], "sources": {"github": {"allowed": [{"id": "<login>"}], "bots": [{"id": "dependabot[bot]"}]}, "feishu": {"allowed": [{"id": "ou_…", "name": "…"}], "syncChat": "oc_…", "admission": {"oc_…": {"unlistedAddressed": "explicit"}}}}}`。`bots` 列出其消息可作为推断候选的机器人。`admission` 的行以聊天 ID 为键（飞书还可用 `other` 或 `direct`），GitHub 则以 `issues`、`pulls`、`comments` 或 `ci` 为键；未设置的单元取默认值（见 [002 授权](002-authorization.md)）。
- `eval`：`mode`、`timeoutSeconds` 和 `model`。
- `executor`：`model`、`maxWorkers`、`directory`、`prepare` 和 `blockedCommands`。处理暂停是独立的设置 `paused`，由 `POST executor/pause` 设置。

更改仓库或 CLI 会先运行相应的初始化检查。检查失败会返回 400，详情在 `setup` 中。账号更改成功，或在初始化待处理期间的任何保存，都会返回 `restarting: true`。应用重启期间，该 API 暂时不可用。

```sh
api=http://127.0.0.1:3082/orchestrator/api
rev=$(curl -s -H 'x-orchestrator-request: 1' $api/settings | jq '.sources[] | select(.id == "github") | .revision')
curl -s -X PUT -H 'x-orchestrator-request: 1' -H 'content-type: application/json' $api/settings/source:github \
  -d "{\"value\": {\"enabled\": true, \"config\": {\"repository\": \"acme/widgets\", \"cli\": \"$HOME/.local/bin/gh-agent\"}}, \"revision\": $rev}"
```

## 初始化检查

初始化使用 DeepSeek Harness 的子进程服务，与工作者 shell 的做法相同。它会移除名称中包含 KEY、PASSWORD、SECRET 或 TOKEN 的环境变量。

初始化会验证 GitHub 仓库和智能体的推送权限，写入工作者环境，并检查 git 对 github.com 是否只使用智能体的凭据。飞书初始化失败只会禁用飞书来源。

初始化所写入的进程环境：

- `<stateDir>/worker-bin` 中的**命令 shim**，在 `PATH` 中排在首位：`gh` 运行智能体的 CLI；`lark-cli` 运行机器人的 CLI；被禁止的命令会失败。shim 在运行其目标之前，会将自己的目录从 `PATH` 中移除。
- `<stateDir>/worker-gitconfig` 中的 **git 配置**：替换运营者的全局和系统 git 配置。它将智能体 CLI 选作 github.com 的凭据助手，把 GitHub 的 SSH 地址重写为 HTTPS，并定义 Git LFS 过滤器。诸如 HTTP 代理之类的个人 git 设置不会生效。这里不设置提交者身份，git 从不提示输入凭据，并且 `GH_TOKEN` 和 `GITHUB_TOKEN` 会被移除。

`worker-bin` 或 `worker-gitconfig` 中若有非 dsh-superagent 写入的文件，初始化会中止。如果工单目录所在的 git 仓库自身的配置添加了凭据，该工单会失败。

## 试一试

用一个在允许列表中的 GitHub 账号，新建 Issue 或发表包含 `@<agent login> <request>` 的评论。在一个轮询间隔内（默认一分钟），概览中应出现一个工单。智能体会确认该请求，在自己的会话和目录中工作，并在原来的对话中交付结果。使用飞书时，在已配置的聊天中提及机器人。

## 升级

1. 等到没有执行器正处于某一轮处理中。
2. 备份 `<stateDir>/orchestrator.sqlite`。
3. 运行 `git pull && pnpm install && pnpm build`。
4. 运行 `scripts/dsh-superagent restart` 并检查其状态。

重启会终止正在运行的派工，并以带恢复说明的方式启动替代的派工。团队文本和被覆盖的提示词部分会保留；未被覆盖的部分遵循新的默认值。升级后请检查标记为**默认内容已更新**的部分。

由较新版本迁移过的数据库无法被较旧版本打开。因此回滚需要升级前的备份。升级 DeepSeek Harness 本身之后，请重启正在运行的实例，使面板加载匹配的产物。

### 智能体预设

工作者预设和路由预设会在 5 秒后将 shell 命令转入后台。会话在没有其预设的情况下无法加载。当相关会话仍在使用时，请保留 `cordis.patch.yml` 中的 `dsh-superagent-worker` 和 `dsh-superagent-router` 行；否则恢复会话会因 `agent-preset/not-found` 而失败。

## 故障排查

初始化问题会以面板所用的语言显示在概览中，并附带指向修复方法的链接；日志和 API 则显示下面的英文原文。

| 症状 | 原因与修复方法 |
| --- | --- |
| `The agent GitHub CLI is not set.` | 在 GitHub 卡片上设置智能体的 CLI |
| `The agent GitHub CLI was not found.` | 设置包装器的绝对路径，或 `PATH` 上的命令名 |
| `The agent GitHub CLI cannot read its account` | 用 `auth login` 登录该包装器 |
| `@… cannot read …` 或 `@… cannot push to …` | 授予智能体账号对该仓库的写权限 |
| `The GitHub Source names no repository.` | 在 GitHub 卡片上设置仓库，格式为 `owner/name` |
| 工单失败并提示 `The prepare command failed: …` | 输出中会指出原因，例如克隆路径错误；修正该命令后重试工单 |
| `git does not read the github.com credential configuration dsh-superagent writes` | 安装 git 2.32 或更高版本 |
| 工单失败并提示 `The git configuration of the repository in … sets …` | 从克隆的 `.git/config` 中移除所指的凭据或 `http.*.extraheader` 设置 |
| `… was not written by dsh-superagent` | 将所指的文件移出 `<stateDir>/worker-bin` 或 `<stateDir>/worker-gitconfig`，或改用其他 `stateDir` |
| `The bot lark-cli allows user identities` | 将飞书来源指向仅限机器人身份的配置，如上文飞书机器人一节所述 |
| `The bot lark-cli does not work.` 或 `The bot identity of app … is …` | 检查配置中的应用 ID 和密钥 |
| `The Feishu bot is not a member of the chat.` | 在该聊天的设置中把机器人加入聊天；下次尝试即可成功 |
| `status` 退出码为 2 | 某个部分报告错误，重启无法修复：`errors` 会列出每个部分（见管理 API 一节）及其详情；各部分恢复正常后会清除自己的条目 |
| `status` 退出码为 3 | 初始化在等待：`setup` 说明缺少什么，概览会链接到可修复它的设置项 |
| `status` 退出码为 1 | 服务未运行、运行了两份、无响应，或运行时报告错误；输出和最新日志会指出是哪种情况 |
| `… timed out after 90 s`、`… was stopped by …`、`… exited with code …` 或 `… could not run: …` | CLI 失败但没有打印原因；以运营者用户的身份手动运行所指的程序，查看它自身输出的消息 |
| 面板提示 dsh-superagent 无响应 | 它正在重启，或因配置问题未能启动；DeepSeek Harness 日志会指出原因 |
| `dsh-superagent configuration has keys it does not use`（日志） | 移除所指的键；该消息会说明每个值现在位于何处 |
| 日志提示插件与正在运行的 dsh 不兼容 | 安装处于 `engines.dsh` 范围内的 DeepSeek Harness 版本 |
| DeepSeek Harness 升级后，面板显示 "Failed to load plugins" | 重启正在运行的实例 |
| 提及后没有任何反应 | 检查作者是否在来源的允许列表中、来源是否已开启、处理是否未被暂停。在 GitHub 上，通过编辑 Issue 正文添加的提及不会被接收；请在评论中提及智能体 |
