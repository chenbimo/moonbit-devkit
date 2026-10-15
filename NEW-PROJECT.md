# 新增一个模块

从建仓到文档站上线的完整清单,照着走即可。
通用规范只有这一处,项目自己的 `AGENTS.md` 只写项目特有的值,通用部分引用本文件。

## 速览

一个模块要齐五件事。

1. 仓库:命名、`main` 分支、SSH 远端
2. 工具链:接入 devkit,钩子与验收门禁到位
3. 提交:按 `[项目名](类型) 内容` 格式
4. 命名:Pages 项目、`pages.dev` 域、子域名,全部由模块名派生
5. 文档站(可选):托管在 Cloudflare Pages,改动 `docs/` 即自动发布

## 一、仓库与分支

- 仓库名 = 模块名,放在 `chenbimo` 下
- 主分支一律 `main`
- 远端一律 SSH,形如 `git@github.com:chenbimo/<模块名>.git`

```bash
git init -b main
git remote add origin git@github.com:chenbimo/<模块名>.git
```

## 二、接入 devkit

devkit(`moonbit/scripts`)是工作区唯一的公共仓库,提供钩子、验收门禁与 CI 模板。
接入一条命令:

```bash
bash /mnt/c/codes/moonbit/scripts/devkit.sh init <模块名>
```

然后做两件事。

1. 编辑 `<项目>/scripts/devkit.conf`,填全业务事实(项目名、模块名、测试 target、构建入口、启用的校验器)。每一项的说明都在该文件的注释里。
2. 在仓库里执行一次,激活钩子:`git config core.hooksPath .githooks`。

生成物(`.githooks/`、`scripts/devkit/`、`.github/workflows/verify.yml`)**禁止手改**。
要改共享逻辑,去改 `moonbit/scripts`,然后 `bash devkit.sh sync`。

## 三、提交规范

```text
[项目名](类型) 提交内容
```

- 项目名 = 模块目录名,小写,与仓库名一致
- 类型:`feat` / `fix` / `docs` / `refactor` / `test` / `chore`
- 内容:中文一句话,结尾不加句号
- Merge 与 Revert 提交豁免

格式由 `commit-msg` 钩子强制校验。

## 四、命名规范

命名的唯一输入是**模块目录名** `<name>`。
三个产物全部从它派生,不要另起名字。

| 产物 | 规则 | 例子(`<name>` = `bm2`) |
| --- | --- | --- |
| 提交里的项目名 | `<name>` | `bm2` |
| Pages 项目名 | `moonbit-<name>` | `moonbit-bm2` |
| Pages 默认域 | `moonbit-<name>.pages.dev` | `moonbit-bm2.pages.dev` |
| 自定义域 | `<name>.moonbitlang.dev` | `bm2.moonbitlang.dev` |

两个前缀不一致是故意的:`pages.dev` 那个只给 Cloudflare 内部指向用,访客只看 `moonbitlang.dev`。
两者独立绑定,绑自定义域时会自动建一条 CNAME 指向 `moonbit-<name>.pages.dev`。

**两条硬规矩。**

- `pages.dev` 子域名**全球唯一**,不是账号内唯一。所以顺序是「先建项目确认拿到,再绑自定义域」。万一被占,加后缀(`moonbit-<name>-dev`)。
- Pages 项目名**投产之后不要改**。改名会换掉 `pages.dev` 域名,自定义域要重绑。

官方门户是同一个套路,只是 `<name>` 用 `site`,即项目 `moonbit-site`、自定义域 `moonbitlang.dev`(apex)。

## 五、文档站(可选,有 `docs/` 才做)

### 一次性设置

前置:先在 GitHub 安装 App「Cloudflare Workers and Pages」(`github.com/apps/cloudflare-workers-and-pages`)。
授权围可以是「All repositories」(本工作区的选择:新建仓库即免逐个授权)或官方推荐的最小集合;关键是目标仓库必须落在围内。
没有这一步,推送事件到不了 Cloudflare,任何构建都不会触发。

然后逐条执行:

```bash
cf auth login                             # 本机一次即可

# 1) 建 Pages 项目,工具链与构建配置一次给全
cf pages create \
  --name moonbit-<name> \
  --production-branch main \
  --build-config-root-dir docs \
  --build-config-build-command 'bun install --frozen-lockfile && bun run build' \
  --build-config-destination-dir dist

# 2) 绑自定义域(证书自动签发,几分钟)
cf pages domains create moonbit-<name> --name <name>.moonbitlang.dev

# 3) CLI 建域不会自动建 DNS 记录,必须手动补一条代理 CNAME
cf dns records create -z moonbitlang.dev \
  --body '{"type":"CNAME","name":"<name>","content":"moonbit-<name>.pages.dev","proxied":true,"ttl":1}'

# 4) 连 GitHub 仓库
#    id 从 GitHub API 取:users/chenbimo 与 repos/chenbimo/<name> 返回里的 "id" 字段
cf pages source connect moonbit-<name> \
  --body '{"type":"github","config":{"owner":"chenbimo","owner_id":<owner-id>,"repo_name":"<name>","repo_id":<repo-id>,"production_branch":"main","deployments_enabled":true,"production_deployments_enabled":true,"pr_comments_enabled":true,"preview_deployment_setting":"all","path_includes":["docs/*","moon.mod"],"path_excludes":[]}}'

# 5) 两个构建环境变量,production 与 preview 都要
cf pages edit moonbit-<name> \
  --body '{"deployment_configs":{"production":{"env_vars":{"BUN_VERSION":{"type":"plain_text","value":"<本地 bun 版本>"},"SKIP_DEPENDENCY_INSTALL":{"type":"plain_text","value":"1"}}},"preview":{"env_vars":{"BUN_VERSION":{"type":"plain_text","value":"<本地 bun 版本>"},"SKIP_DEPENDENCY_INSTALL":{"type":"plain_text","value":"1"}}}}}'
```

### 为什么必钉 BUN_VERSION

- CF 构建系统在**我们自己命令之前**有一个自动「依赖安装」阶段:它看仓库里的锁文件选包管理器(`bun.lock` → bun),然后用镜像自带的 bun 去装。
- 镜像里的 bun 是 1.2.15(2026-10 实测),读不了 bun 1.4 写的 `lockfileVersion: 2`,构建会先挂在自动安装,我们的命令一次都不会执行。
- 所以 `BUN_VERSION` 要与本地写锁文件的 bun 版本一致;官方支持「Any version」,把关键预装软件钉住也是官方 best practice 原话。
- `SKIP_DEPENDENCY_INSTALL=1` 让安装只发生我们的命令里,不由 CF 的隐式阶段代劳。

门户的例外都在这一页内。

- 仓库与目录名直接用 `moonbitlang.dev`(与域同名,克隆后目录就对),不套 `<name>` 规则;Pages 项目名仍为 `moonbit-site`,提交前缀仍为 `site`。
- 上面第 3 步的 DNS 记录 `name` 对门户填 apex `moonbitlang.dev`(CNAME 展平),不是子域名。
- 门户的监听路径是全仓 `*`:站点即内容,任何一次 push 都应触发重部署。

### 持续部署:用 Pages 的 Git 集成

在 Pages 项目里连上该模块的 GitHub 仓库,填这几项。

| 项 | 值 |
| --- | --- |
| 生产分支 | `main` |
| 根目录 | `docs` |
| 构建命令 | `bun install --frozen-lockfile && bun run build` |
| 输出目录 | `dist` |
| 监听路径 | `docs/*`, `moon.mod` |

连好之后,推送到 `main` 就自动重建,且**只在监听路径命中时构建**,只发布 `dist`。
不需要在 GitHub 存任何 Cloudflare 凭据,也不用额外加 workflow。

**监听路径必须带 `moon.mod`。**
文档站构建时会从 `moon.mod` 读版本号(`docs/.vitepress/config.js` 就是这么做的),发布时改了 `version`,站点才会跟着更新。
只监听 `docs/*` 会导致「版本发了、站点还显示旧版」。

### 文档站自身的约定

- 站点是子域名根路径,所以 `base` 写 `'/'`
- VitePress 精确锁版本,不写 `^`
- 页面里不硬编码版本号,一律从 `moon.mod` 读

### 构建出问题时

```bash
# 构建与部署是否成功
cf pages deployments list --project-name moonbit-<name>

# 失败时看构建日志
cf pages deployments history logs get <deployment-id> --project-name moonbit-<name>

# 改了 Cloudflare 配置后重新构建:从分支 HEAD 触发一次,不用推送
cf pages deployments create moonbit-<name> --branch main
```

两个实测坑(2026-10)。

- `cf pages deployments retry` 会用创建那次部署时的旧配置重跑,验证新配置必须用上面的 `deployments create`。
- 环境变量的值必须是 `{"type":"plain_text","value":"..."}` 对象,裸字符串会被 400 拒绝。
- 监听路径会拦住生产部署:不命中的推送会留下一条全部阶段 `idle`、且 `is_skipped: true`、`skip_reason: path_config` 的部署记录,这是跳过,不是故障。
- `cf pages source connect` 的 `owner_id` 与 `repo_id` 必须是字符串,裸数字同样 400(8000006)。
- 在 Git Bash 里给 `--build-config-destination-dir` 传 `/` 会被 MSYS 路径转换成 `C:/Program Files/Git` 之类的主机路径,须在命令前加 `MSYS2_ARG_CONV_EXCL='*'`,或改用 `--body` 设置。

## 六、项目侧只留什么

- 业务源码、`moon.mod`、`README.md`
- `scripts/devkit.conf`,唯一由项目手工维护的清单
- `docs/`,如果有文档站
- 自己特有的慢测试(`scripts/e2e/`、`scripts/soak.sh` 之类)
- `AGENTS.md`,**只写项目特有的值**,通用规范引用本文件

其余全是生成物,不要手改。

## 七、新模块自检清单

- [ ] 仓库名 = 模块名,分支 `main`,远端走 SSH
- [ ] `devkit.sh init <模块名>` 跑过,`scripts/devkit.conf` 填全
- [ ] `core.hooksPath` 设成 `.githooks`
- [ ] 一次提交能过 `commit-msg` 与 `pre-commit`
- [ ] `bash scripts/devkit/verify.sh` 通过
- [ ] 有文档站时:Pages 项目名 `moonbit-<name>`,自定义域 `<name>.moonbitlang.dev`
- [ ] 有文档站时:`base` 为 `'/'`,监听路径含 `moon.mod`
- [ ] 有文档站时:GitHub App「Cloudflare Workers and Pages」已装,且仓库在授权围内(本工作区为 All repositories)
- [ ] 有文档站时:`BUN_VERSION` 与本地写锁文件的 bun 版本一致,`SKIP_DEPENDENCY_INSTALL=1`
- [ ] 有文档站时:首次构建成功,自定义域返回 200
