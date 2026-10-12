# GitHub 安全设置（Corta）

本地配置不会自动更改 GitHub 仓库设置。先把配置文件通过 PR 合并到 main，
再按下面顺序开启网页设置。最后以实际扫描结果确认配置生效。
这是严格的配置方案；扫描不能保证发现所有漏洞。

## 1. 依赖与密钥保护

打开 https://github.com/noah-qin/Corta/settings/security_analysis 。
GitHub 可能将入口显示为 Settings → Security and quality → Advanced Security。

| 选项 | 设置 |
| --- | --- |
| Dependency graph | Enabled |
| Dependabot alerts | Enabled |
| Dependabot security updates | Enabled |
| Dependabot version updates | 使用已提交的 .github/dependabot.yml |
| Secret Protection / Secret scanning | Enabled |
| Push protection | Enabled |
| Validity checks（符合套餐与仓库条件时） | Enabled；个人仓库未显示时跳过 |
| Scan for non-provider patterns（若可用） | Enabled |
| AI-detected secrets（若可用） | Enabled；检测结果仍需人工判断 |
| Private vulnerability reporting | Enabled |

Security policy 和 Security advisories 保持现有开启状态。
Secret scanning 和 push protection 在公开仓库可免费使用；不要为未显示的付费选项购买套餐。
Validity checks 的服务商模式开关受仓库归属和套餐限制；当前官方文档列出的适用条件包括组织拥有、GitHub Team 且启用 Secret Protection。个人仓库看不到此开关时跳过。
Validity checks 可能向服务提供商验证密钥状态。
非服务商模式、AI 检测并不都有 push protection 支持。
个人账户的 Push protection for users 与仓库级 Push protection 是两个开关：
个人保护默认开启并不表示此仓库的推送保护和管理员告警已开启。
发现真实密钥后先撤销/轮换，再清理代码，不能只关闭告警。

Dependabot 每天检查 Actions 和 Xcode/Sparkle 的依赖版本。
它创建升级 PR，不能绕过检查自动合并。告警覆盖依赖图和 Advisory Database
能识别的依赖/漏洞，不代表 Sparkle 或所有供应链风险都已覆盖。
在 Insights → Dependency graph 确认 Sparkle 被识别，在 Dependabot 页面确认两个更新任务成功。

## 2. CodeQL：使用本仓库的高级配置

合并 .github/workflows/codeql.yml 与 ci.yml 的修改。
如果已经开启 Default setup，先关闭 Default setup，再使用 Advanced setup；
不要同时生成第二个 CodeQL 模板工作流。

工作流通过 CI 扫描 PR、main 推送和手动调度的机器人发布 PR；另外每天扫描 main。
每天的计划时间为 UTC 21:43，即北京时间次日 05:43。
Swift 和 C/C++ 用 macos-26、固定 Xcode 26.6.0 和无签名 clean build；
Python 和 GitHub Actions 用 Linux，无需构建。
扫描构建使用通用 macOS 目标，且仅排除 CodeQL 不支持的 .metal 着色器；
这是 macOS CodeQL tracer 的 Metal 工具链兼容问题（codeql-action#3978）的规避方式。
普通 app CI 仍完整编译 Metal 着色器并执行测试。
Swift 扫描还构建全部 SwiftPM 产品，包含未被 app scheme 构建的辅助工具。
C/C++ 在引用包含 C 源码时扫描；较旧引用没有 C 源码时明确记录并跳过该语言。

使用 security-and-quality 查询集，覆盖默认、扩展安全和质量查询。
Action 固定官方仓库的完整 commit SHA，Dependabot 跟进更新。
扫描只获得 contents: read 和上传所需的 security-events: write，
不继承发布 secrets，不使用 release 环境，也不使用 self-hosted runner。

首次运行：Actions → CI → Run workflow，选择 main。
检查四个 CodeQL job 和 Dependency review；在 Security and quality → Code scanning
确认各语言的分析、时间和提交 SHA。C/C++ 无源码时不会有分析记录。
CodeQL job 成功代表分析成功，发现漏洞通常不会让 job 自动失败；
漏洞阻止合并要依靠下面的 Code scanning ruleset。

Dependency review 拒绝新增任何已知漏洞（low 及以上，覆盖所有依赖 scope）。
显式 base/head ref 使机器人 PR 的 workflow_dispatch 也能执行依赖审查。
main 上手动运行时 main 与 main 的比较不替代 PR 的依赖差异审查。
许可证检查属于单独的合规判断，这个安全门禁不把许可证告警当漏洞。

## 3. Actions 权限

Settings → Actions → General：

- Actions permissions：选择允许本仓库及指定 Action；允许 actions/* 与 github/codeql-action/*，关闭任意 Marketplace Action 的通用授权。
- 开启 Require actions to be pinned to a full-length commit SHA（若显示）。本仓库的本地 reusable workflow 不需外部 SHA。
- Workflow permissions：Read repository contents and packages permissions。
- Fork pull request workflows：Require approval for all external contributors。
- 公开仓库不要让 fork 获得 write token 或 secrets。

当前发布/更新 feed 用 GitHub Token 创建 PR，因此暂时保留
Allow GitHub Actions to create and approve pull requests；关闭这个组合开关会破坏发布。
若要关闭它，先把创建 PR 的流程迁移到权限最小化的 GitHub App。
不要用自动批准代替人工安全审核。

当前有本机 self-hosted Metal 测试 runner。它保持手动调度，
批准外部 PR 工作流前先查看 .github 的 diff。
更强隔离需要移除公开仓库的持久自托管 runner，改在本机手动测试或专用临时隔离机器执行。
单纯把某个 workflow 改成手动并不能阻止另一份恶意 workflow 选择该 runner。

## 4. main 分支规则：先扫描成功，再添加门禁

Settings → Rules → Rulesets → 编辑现有 main 规则，Enforcement 为 Active。
保留现有禁止删除、禁止 force push 和三个 CI 检查。

- Require a pull request before merging。
- Require conversation resolution before merging。
- Require status checks to pass；Require branches to be up to date。
- 新增 Dependency review 以及各语言 CodeQL job 的实际检查名称，从成功运行的列表选择。
- Require code scanning results → Add tool → CodeQL。
- Security alerts：All；Alerts：All（严格阻止安全与质量告警）。
- Require secret scanning results（若该仓库页面可用）：全部支持的 secret 类型。

没有其他维护者时，强制 1 个 reviewer 或 CODEOWNER 审批会让自己发起的 PR
无法合并，因为作者不能批准自己的 PR。当前单维护者项目先设 0 个 required approvals；
有第二位维护者后设为 1，开启 CODEOWNER 审批、dismiss stale approvals 和最新推送审批。

当前管理员有 always bypass。最严格配置是移除绕过者，但要在一个普通测试 PR 和
一个 Release 的 dry_run 验证后再移除，避免把现有发布流程锁住。
机器人 PR 已通过 CI reusable workflow 运行扫描，report-ci-statuses.sh 会报告各 job 的结果；
仍需验证 GitHub 的原生 Code scanning 门禁接受这种手动调度的分析。
若不接受，保持 PR 被阻止，迁移到能正常触发 PR workflow 的 GitHub App 后再启用自动合并；
不要伪造 CodeQL 无漏洞状态或增加管理员绕过来放行。

## 5. 发布环境与验证

Settings → Environments → release：只允许 main 的部署，签名/公证 secrets 放在该环境。
若可用，增加人工审批；单维护者需要允许自己审批，否则必须引入第二位审批者。
若有独立审批者，可同时开启 prevent self-review，关闭管理员绕过。
这一配置会把无人值守发布变成审批后发布。

验证顺序：

1. 合并配置，开启依赖和密钥保护。
2. CI 和每天的 CodeQL 扫描成功，确认 Sparkle 依赖图与 Dependabot 更新任务。
3. 用普通测试 PR 确认依赖审查和 CodeQL 检查报告；处理当前已有告警。
4. 添加 required checks 和 Code scanning/secret scanning 合并规则。
5. 使用现有 Release 的 dry_run 验证机器人 PR 路径和发布环境审批。
6. 最后移除管理员 always bypass，确认失败的门禁确实阻止合并。

不要用真实密钥验证 push protection。误报应记录证据后按规则 dismiss，
不要全局关闭扫描。设置安全告警通知，让仓库维护者能及时收到新增告警。

## 官方参考

- [GitHub security settings](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/enabling-features-for-your-repository/managing-security-and-analysis-settings-for-your-repository)
- [CodeQL workflow options](https://docs.github.com/en/code-security/reference/code-scanning/workflow-configuration-options)
- [Code scanning merge protection](https://docs.github.com/en/code-security/how-tos/find-and-fix-code-vulnerabilities/manage-your-configuration/set-merge-protection)
- [Dependency review](https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/manage-your-dependency-security/configure-dependency-review-action)
- [Secure use of Actions](https://docs.github.com/en/actions/reference/security/secure-use)
