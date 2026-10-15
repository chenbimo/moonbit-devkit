# moonbit 开发工具链(唯一源)

统一 `moonbit/` 下所有项目的开发流程。这份目录是**唯一源**,项目仓库里落一份**生成副本**,
副本禁止手改,由校验戳记兜底。

本目录自身是一个 git 仓库(`git@github.com:chenbimo/moonbit-devkit.git`),单独版本化、单独推送。
它只服务本机的工作区,CI 与各项目克隆都不需要它。

## 心智模型:骨架 + 声明 + 插槽

- **骨架**:所有项目一样的那部分——提交格式、`moon fmt`、严格 `moon check`、推送门禁、CI。
  实现就在本目录,写一次。
- **声明**:每个项目不一样的地方,做成空格,项目在 `scripts/devkit.conf` 里填。
  例如项目名、测试 target、构建入口、启用哪些校验器。
- **插槽**:声明表达不了的怪需求,在固定位置放一个项目自己的脚本,骨架到时调用。
  例如 bm2 的 e2e 与 soak。

遇到特殊需求的处理顺序:先试「能不能变成一个值」,不行就试「能不能变成一个开关(校验器)」,
再不行才挂插槽。插槽被第二个项目用到时,就把它扶正成正式声明项。**特殊只增在项目那边,骨架不被污染。**

## 目录

```
scripts/
├── devkit.sh              # 源侧工具:list / init / sync / check
├── devkit.conf            # 全局常量(如 MoonBit 工具链版本)
├── static/                # 逐字节复制到项目,不经替换
│   ├── .githooks/{commit-msg,pre-commit,pre-push}
│   └── scripts/devkit/{hook-dispatch,commit-msg,pre-commit,pre-push,verify}.sh
│       └── lib/{common,checks,manifest}.sh
├── templates/
│   ├── verify.yml         # CI 模板(替换工具链版本 + 注入项目 setup)
│   └── devkit.conf        # 项目清单种子(仅 init 时种一次)
├── NEW-PROJECT.md         # 新增模块的完整清单与命名规范
└── README.md
```

## 用法(WSL 内执行)

```bash
D=/mnt/c/codes/moonbit/scripts/devkit.sh

bash $D list            # 列出工作区里的项目
bash $D init  <项目>    # 接入一个项目:种清单 + 生成副本 + 打印钩子激活命令
bash $D sync  [项目...] # 改了源之后,把副本重新生成(省略项目名则全体)
bash $D check [项目...] # 校验副本与源一致、且没有项目落后
```

## 新增一个模块

从建仓到文档站上线的完整清单(含命名规范)见 [`NEW-PROJECT.md`](./NEW-PROJECT.md)。

## 改了共享逻辑之后

1. 改本目录里的文件
2. `bash devkit.sh sync`
3. 把各仓库里变化的生成物一起提交

## 漂移防线

生成物一旦被手改,`pre-commit` 与 CI 里的 `verify.sh` 都会拒绝,并提示你跑 `sync`。
戳记分两份:

- `scripts/devkit/.manifest` — 每个生成文件的 sha256,`sha256sum -c` 原生格式。
- `scripts/devkit/.manifest.rev` — 生成时的源树哈希,`devkit.sh check` 用它判断谁落后于源。

校验本身不需要源树,所以 CI 也能跑完整校验。唯一漏洞是同时手改文件与戳记,那等同于故意绕过,
`git commit --no-verify` 本来也拦不住。

## 提交格式与命名

见 [`NEW-PROJECT.md`](./NEW-PROJECT.md)。
