# SEO 与仓库合并验证 · 2026-11-05

网站源码现在属于 Corta 根仓库的 `website/`，内容目录默认 `..`，不需要本机路径配置或嵌套 Git。构建中间文件、依赖、输出和本地环境均不提交。

已完成：

- 英文回退页面使用英文标题、英文摘要及英文 canonical；真实译文使用各自的来源标题和摘要。首页标题九语言集中维护，描述来自对应 README。
- 根语言选择页设置 canonical；首页语言组包含指向选择页的 `x-default`。
- 静态 sitemap 当前有 45 个规范地址，排除重复英文回退页面；导出 robots.txt 指向正确 sitemap。`lastmod` 来自源文件 Git 提交时间；未提交/新建/非 Git 文档不虚构时间。CI 获取完整历史。
- CI/部署严格检查 SITE_URL，拒绝缺失、localhost（含尾随点）、回环地址、HTTP、带路径/查询/凭据的配置。
- 首页截图使用真实的 2484×1524 尺寸，生成 480、768、1200、1680、2484px 的 WebP，浏览器通过 srcSet/sizes 选择。原 PNG 约 494 KiB，480px 版本约 13 KiB；这些是本次生成文件大小，不是产品性能宣称。
- 更新日志的标题链接和 `#` 锚点保持并列，静态检查继续防止嵌套链接。

验证结果：

- 迁移后的实际目录完成根路径、`/Corta` 项目子路径两种生产构建；静态导出、TypeScript、4 个回归测试和所有产物检查通过。自定义域名的空 basePath/HTTPS origin 组合通过配置测试。
- 当前导出含 108 个语言内容页面、根选择页及 sitemap/robots；检查 13,367 个内部链接和 750 个图片/资源引用，检查 canonical、逐页描述、真实语言版本、站点地图去重及源日期、所有 WebP 的实际宽度与格式。
- 独立 `/tmp` 副本验证了 Markdown 修改的开发热更新；移走日文故障排除译文后，开发预览出现英文回退及英文 canonical。重新构建后 sitemap 从 45 项减为 44 项，没有残留日文地址，修改后的正文也进入 HTML。未为测试修改 Corta 原文档。
- 浏览器确认中文首页的新标题、canonical、x-default、真实图片尺寸及自动选择的 WebP，无页面横向溢出；英文回退功能页显示英文标题和 canonical，未记录新的控制台错误。
- 已核对原独立网站的全部已跟踪源码均在新目录中，原部署模板移到 Corta 根 `.github/workflows/website.yml`。工作流 YAML、根工作目录、全文档/图片/网站源码触发范围均已检查；本轮没有推送或执行部署。

预览：

- 开发：http://localhost:3000/zh-CN/，从 `Corta/website/` 运行并监听根仓库文档。
- 静态：http://localhost:3001/zh-CN/；新 Markdown 需要重新构建才进入静态产物。

原 `/Users/noah/website/` 及其独立 `.git` 在迁移、验证、源码保存后删除；不删除 Corta 根 `.git`。今后只在 Corta 仓库中更新网站文件。

线上限制：尚未测试或触发 GitHub Pages 的实际运行和域名；缺失译文仍按设计回退英文。Pages 项目子路径下的 robots.txt 不代替域名根 robots，需直接提交项目 sitemap。未推送更改只影响本地预览。操作说明见 README。
