# Maple Mono NL NFMono CN

工作站等宽字体包，包含 Regular、Bold、Italic、BoldItalic 四种 TTF，以及本次构建的 config.json。

## 安装与使用

Windows 解压后安装 TTF，在终端或编辑器字体设置中选择 **Maple Mono NL NFMono CN**，重开应用后检查显示。工作站 Terminal 部署脚本也会在缺失时安装该字体。

- 文件名示例：`MapleMonoNL-NFMono-CN-Regular.ttf`。
- 不启用代码连字，包含中文与单宽 Nerd Font 图标，关闭 hinting。
- 目标中西文字宽为 2:1；不同终端、字号、回退字体和显示缩放仍可能影响排版。安装后检查中文、ASCII、图标和斜体，不以字体名匹配代证显示正确。

安装前关闭使用该字体的应用；更新字体后可能需要重开应用、注销或重启才能刷新。包内 config.json 用于标识构建选择，不是系统安装器。

构建命令与选择理由见公开仓库的[字体开发说明](https://github.com/Lokyael/vpsbase/blob/main/tools/fonts/maple-mono/DEVELOPMENT.md)；该说明不随字体包分发，安装使用不依赖它。
