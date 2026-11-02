# Maple Mono 构建与选择

配置源为本目录 config.json；随包使用说明为 [README](README.md)。构建流水线 `.github/workflows/build-font.yml` 克隆上游 v7、Python 3.11，编译四种 TTF 并发布到 assets 分支。这里不存字体产物。

## 构建（Bash）

克隆 [Maple Font](https://github.com/subframe7536/maple-font) 的对应版本，将本目录 config.json 覆盖至上游根目录后执行：

```bash
# 1. 安装构建依赖
pip install -r requirements.txt

# 2. 触发自编译构建 (锁定 Regular / Bold / Italic / BoldItalic 核心工态字重)
python build.py \
  --cn \
  --cn-wenyuan \
  --nf \
  --nf-mono \
  --no-liga \
  --no-hinted \
  --ttf-only \
  --least-styles
```

联网构建及 assets 分支发布不属于默认离线检查。打包只包含 CN TTF、config.json 和随包 README；不打包本开发说明。修改配置、构建参数和触发路径须同步核验，不修改已发布下载 URL。

## 最终选择

| 对象 | 选择与理由 |
| :--- | :--- |
| 连字 | 关闭，保留代码符号逐字形态；不选将多个符号合成视觉字形的风格 |
| 中文基字 | 文渊静态基字，目标是所需全角字符覆盖及编辑器度量一致；具体缺字／换行行为仍须对应版本字体和编辑器复验 |
| 中文宽度 | cn.narrow=false，维持中西文 2:1 目标；不选窄中文，不据此承诺所有终端分类与排版一致 |
| Nerd Font | mono=true、propo=false，优先单列图标；不选变宽图标，实际终端列宽仍需测试 |
| Hinting | 中文和西文均关闭，偏向目标高分屏渲染风格；不将体积、低分屏清晰度或 DirectWrite 表现作通用保证 |
| 字重 | Regular／Bold／Italic／BoldItalic，限制交付体积，不生成无需求样式 |

feature_freeze 中启用 cv01（规整符号）、cv34/35/36（斜体风格）、cv61（直尾标点）；cv04、cv09/10、cv42/43 保持 ignore，不将 l 底座和 7/Z 横线固化为默认。cv96（全角引号）、cv97（全角省略号）、cv98（全角破折号）也保持 ignore，不强制全角；cv99=disable 移除该居中标点特性。ignore 仅表示不冻结、不删除，应用仍可显式启用保留的特性，不等于从字体中禁用。精确值以 config.json 为准，不再复制所有默认项。以上为个人显示选择，不是防止一切误读或排版故障的证明。

特性语义依据 Maple Font v7 的[构建 schema](https://github.com/subframe7536/maple-font/blob/5ee93150fbafe59dc805c2f64ad879fd14c3ce78/source/schema.json)与[冻结实现](https://github.com/subframe7536/maple-font/blob/5ee93150fbafe59dc805c2f64ad879fd14c3ce78/source/py/freeze.py)。链接固定核验提交，不代表 CI 的 v7 引用已固定至该提交。

## 集成与验收

`desktop/apps/terminal.ps1` 检查系统字体，缺失时下载 assets 分支 zip，在临时目录解包安装，再将名称写入 Terminal 配置。下载清理不等于安全擦除；需实际重开终端并核验中文、ASCII、图标、斜体和所用字号的字宽／换行。

编辑器验收包含全角 `ｍ`（U+FF4D）与长中文自动换行；[VS Code 1.144.0 的测量实现](https://github.com/microsoft/vscode/blob/1.144.0/src/vs/editor/browser/config/fontMeasurements.ts)使用该字符测量全角宽度。终端验收包含 `“a`、`…a`、`—a` 的字符衔接，并记录应用、字体版本和特性设置。这些是复验样本；未比对具体字体产物的 cmap、字宽和实际显示，不断言其他基字必然缺字、文渊必然修复换行或保留全角特性必然造成重叠。
