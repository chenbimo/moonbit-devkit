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

```bash
cf auth login
cf pages create                          # 项目名填 moonbit-<name>
cf pages domains create moonbit-<name>   # 域名填 <name>.moonbitlang.dev
```

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
