# md-sync

[English](README.md) | [简体中文](README.zh-CN.md)

这是一个 Vim/Neovim 的 Markdown 预览插件，依赖 **Markdown Pro Max** 插件：
https://lyuangg.github.io/markdown-pro-max/

## 依赖

- Vim 9+ 或 Neovim 0.9+
- Chrome、Chromium、Brave、Edge 等 Chromium 内核浏览器，并安装
  **Markdown Pro Max** 扩展
- 在 `chrome://extensions` 里为该扩展打开「允许访问文件网址」
- `curl` 或 `wget`（仅首次自动下载服务端时需要）

`md-sync-server` 会在第一次使用时按当前系统/架构自动下载并校验 SHA256，
不需要安装 Go。

## 安装

### vim-plug（Vim / Neovim）

```vim
Plug 'lyuangg/md-sync'
```

然后执行 `:PlugInstall`。

### lazy.nvim（Neovim）

```lua
{ 'lyuangg/md-sync' }
```

### 原生包目录

```bash
# Vim
git clone https://github.com/lyuangg/md-sync.git \
  ~/.vim/pack/plugins/start/md-sync

# Neovim
git clone https://github.com/lyuangg/md-sync.git \
  ~/.local/share/nvim/site/pack/plugins/start/md-sync
```

### 手动

```vim
set rtp+=/path/to/md-sync
runtime plugin/md_sync.vim
```

如果服务端二进制没下载成功，可以手动触发：

```vim
:MarkdownPreviewInstall
```

## 使用

打开一个 Markdown 文件后：

| 命令 | 作用 |
|---|---|
| `:MarkdownPreview` | 打开预览；已有预览时前置并按当前行定位 |
| `:MarkdownPreview!` | 强制打开新的预览窗口 |
| `:MarkdownPreviewClose` | 关闭预览页并退出本地服务 |
| `:MarkdownPreviewInstall` | 下载或更新服务端二进制 |

在 Vim / Neovim 里移动或滚动，浏览器预览会跟随。

## 配置

可选。在第一次预览前调用 `md_sync#setup()` 或设置 `g:md_sync_config`。

```vim
let g:md_sync_config = {
    \ 'browser': 'Google Chrome',
    \ 'window': 'right',
    \ 'window_gap': 8,
    \ }
```

```lua
-- Neovim
vim.fn['md_sync#setup']({ browser = 'Google Chrome', window = 'right' })
```

`window` 支持 `right`、`left`、`center`、`full`、`right-third`、`left-third`、
`900x700`、`l,t,w,h` 或 `off`。其余选项和默认值见 `autoload/md_sync.vim` 顶部。
