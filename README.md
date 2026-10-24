# vim-md-preview

[English](README.md) | [简体中文](README.zh-CN.md)

A Markdown preview plugin for Vim/Neovim. It depends on the **Markdown Pro Max**
extension: https://lyuangg.github.io/markdown-pro-max/

## Requirements

- Vim 9+ or Neovim 0.9+
- Chrome, Chromium, Brave, Edge or another Chromium browser with the
  **Markdown Pro Max** extension installed
- "Allow access to file URLs" enabled for the extension in `chrome://extensions`
- `curl` or `wget` for the first-time server download

The `md-sync-server` binary for your OS/architecture is downloaded and
checksum-verified on first use. No Go toolchain is required.

## Installation

### vim-plug (Vim and Neovim)

```vim
Plug 'lyuangg/vim-md-preview'
```

Then run `:PlugInstall`.

### lazy.nvim (Neovim)

```lua
{ 'lyuangg/vim-md-preview' }
```

### Native packages

```bash
# Vim
git clone https://github.com/lyuangg/vim-md-preview.git \
  ~/.vim/pack/plugins/start/vim-md-preview

# Neovim
git clone https://github.com/lyuangg/vim-md-preview.git \
  ~/.local/share/nvim/site/pack/plugins/start/vim-md-preview
```

### Manual

```vim
set rtp+=/path/to/vim-md-preview
runtime plugin/md_sync.vim
```

If the server binary is missing, install it explicitly with:

```vim
:MarkdownPreviewInstall
```

## Usage

Open a Markdown file and run:

| Command | Description |
|---|---|
| `:MarkdownPreview` | Open the preview, or focus/scroll an existing one |
| `:MarkdownPreview!` | Always open a new preview window |
| `:MarkdownPreviewClose` | Close preview tabs and stop the server |
| `:MarkdownPreviewInstall` | Download or update the server binary |

Move or scroll in Vim/Neovim and the preview follows.

## Configuration

Optional. Call `md_sync#setup()` or set `g:md_sync_config` before previewing.

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

`window` accepts `right`, `left`, `center`, `full`, `right-third`,
`left-third`, `900x700`, `l,t,w,h` or `off`. All options and defaults are
documented at the top of `autoload/md_sync.vim`.
