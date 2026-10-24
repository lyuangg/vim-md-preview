" md-sync: open a synced Markdown preview in the browser.
if exists('g:loaded_md_sync')
    finish
endif
let g:loaded_md_sync = 1

command! -bang MarkdownPreview call md_sync#preview(<bang>0)
command! MarkdownPreviewClose call md_sync#close()
command! MarkdownPreviewInstall call md_sync#install()
