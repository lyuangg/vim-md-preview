" vim-md-preview: sync the editor cursor line to a browser Markdown preview.
" Works in Vim 9 and Neovim; the job/channel APIs differ.

" <sfile> is only reliable at script level.
let s:plugin_root = expand('<sfile>:p:h:h')

let s:cfg = {
    \ 'binary': '',
    \ 'server_repo': 'lyuangg/md-sync-server',
    \ 'server_version': 'latest',
    \ 'download_base': '',
    \ 'auto_install': 1,
    \ 'port_base': 8765,
    \ 'port_tries': 10,
    \ 'opener': '',
    \ 'browser': 'Google Chrome',
    \ 'browser_args': [],
    \ 'new_window': 1,
    \ 'window': 'right',
    \ 'window_gap': 8,
    \ 'close_tab_on_exit': 1,
    \ 'throttle_ms': 60,
    \ }

let s:state = {
    \ 'job': v:null,
    \ 'port': 0,
    \ 'token': '',
    \ 'seq': 0,
    \ 'session': '',
    \ 'opened': {},
    \ 'clients': {},
    \ 'backed_temp': {},
    \ 'temp': {},
    \ 'temp_content': {},
    \ 'temp_timer': -1,
    \ 'bufkey': {},
    \ 'timer': -1,
    \ 'last_line': -1,
    \ 'last_key': '',
    \ 'outbuf': '',
    \ 'bound': 0,
    \ }

function! md_sync#setup(opts) abort
    let opts = copy(a:opts)
    if has_key(opts, 'mac_app')
        if !has_key(opts, 'browser')
            let opts.browser = opts.mac_app
        endif
        call remove(opts, 'mac_app')
    endif
    if has_key(opts, 'mac_new_window')
        if !has_key(opts, 'new_window')
            let opts.new_window = opts.mac_new_window
        endif
        call remove(opts, 'mac_new_window')
    endif
    call extend(s:cfg, opts)
endfunction

" Can also be set with g:md_sync_config in vimrc; md_sync#setup() overrides it.
if exists('g:md_sync_config') && type(g:md_sync_config) == v:t_dict
    call md_sync#setup(g:md_sync_config)
endif


function! md_sync#preview(force) abort
    if &filetype !=# 'markdown' && expand('%:e') !~? '^\%(md\|markdown\|mdown\)$'
        call s:warn('Current buffer is not markdown')
        return
    endif
    if !s:start()
        return
    endif
    call s:bind_autocmds()

    let bufnr = bufnr('%')
    let file = expand('%:p')
    let use_temp = &modified || empty(file)
    let key = empty(file) ? 'buf:' . bufnr : file
    let s:state.bufkey[bufnr] = key

    " Keep temp mode once created, so saving does not open another tab.
    let temp = get(s:state.temp, key, '')
    if empty(temp) && use_temp
        let temp = tempname() . '.md'
        let s:state.temp[key] = temp
    endif
    let target = file
    let temp_changed = 0
    if !empty(temp)
        let lines = getline(1, '$')
        let temp_changed = !has_key(s:state.temp_content, key)
                    \ || lines !=# s:state.temp_content[key]
        let s:state.temp_content[key] = lines
        call writefile(lines, temp)
        let target = temp
    endif

    let prev = get(s:state.opened, key, '')
    let prev_is_temp = !empty(get(s:state.backed_temp, prev, ''))
    if !a:force && !empty(prev) && get(s:state.clients, prev, 0) > 0
                \ && (prev_is_temp == !empty(temp))
        if temp_changed
            call s:send({'type': 'reload', 'session': prev, 'file': target})
        endif
        call s:send({'type': 'focus', 'session': prev, 'file': target, 'line': line('.')})
        return
    endif

    let s:state.seq += 1
    let session = printf('%s-%d-%d', has('nvim') ? 'nvim' : 'vim', getpid(), s:state.seq)
    let s:state.session = session
    let s:state.opened[key] = session
    let s:state.backed_temp[session] = temp
    call s:open(s:build_url(target, session))
    call s:send({'type': 'pos', 'session': session, 'file': target, 'line': line('.')})
endfunction

function! md_sync#install() abort
    let path = s:install_binary(1)
    if empty(path)
        call s:warn('Download failed; place the binary manually in ' . s:download_dir())
    else
        echomsg 'md-sync: installed ' . path
    endif
endfunction

function! md_sync#close() abort
    if s:state.port > 0
        call s:send({'type': 'close'})
        sleep 200m
    endif
    call s:stop()
    call s:cleanup_temps()
    call s:reset_session_state()
endfunction

function! s:reset_session_state() abort
    let s:state.opened = {}
    let s:state.clients = {}
    let s:state.backed_temp = {}
    let s:state.bufkey = {}
    let s:state.last_line = -1
    let s:state.last_key = ''
    let s:state.timer = -1
    let s:state.temp_timer = -1
endfunction


function! s:start() abort
    if s:state.port > 0
        return 1
    endif
    let bin = s:find_binary()
    if empty(bin)
        call s:warn('md-sync-server not found (set g:md_sync_binary)')
        return 0
    endif

    let cmd = [bin, '--port-base', string(s:cfg.port_base), '--tries', string(s:cfg.port_tries),
        \ '--close-on-exit=' . (s:cfg.close_tab_on_exit ? 'true' : 'false')]
    if has('nvim')
        let s:state.job = jobstart(cmd, {
            \ 'on_stdout': function('s:on_stdout_nvim'),
            \ 'on_stderr': function('s:on_stderr_nvim'),
            \ 'on_exit': function('s:on_exit'),
            \ })
    else
        let s:state.job = job_start(cmd, {
            \ 'out_mode': 'nl',
            \ 'err_mode': 'nl',
            \ 'out_cb': function('s:on_line'),
            \ 'err_cb': function('s:on_stderr'),
            \ 'exit_cb': function('s:on_exit'),
            \ })
    endif

    let waited = 0
    while s:state.port == 0 && waited < 1500
        sleep 10m
        let waited += 10
    endwhile
    if s:state.port == 0
        call s:warn('Failed to start md-sync-server')
        call s:stop()
        return 0
    endif
    return 1
endfunction

function! s:send(msg) abort
    let line = json_encode(extend({'v': 1}, a:msg)) . "\n"
    if has('nvim')
        if type(s:state.job) != v:t_number || s:state.job <= 0
            return 0
        endif
        return chansend(s:state.job, line) > 0
    endif
    if type(s:state.job) != v:t_job || job_status(s:state.job) !=# 'run'
        return 0
    endif
    try
        call ch_sendraw(s:state.job, line)
        return 1
    catch
        return 0
    endtry
endfunction

" Neovim may split stdout into chunks; reassemble lines.
function! s:on_stdout_nvim(id, data, event) abort
    let s:state.outbuf .= join(a:data, "\n")
    let parts = split(s:state.outbuf, "\n", 1)
    let s:state.outbuf = remove(parts, -1)
    for line in parts
        call s:on_line(a:id, line)
    endfor
endfunction

function! s:on_line(...) abort
    let line = a:0 > 1 ? a:2 : a:1
    if type(line) != v:t_string || line ==# ''
        return
    endif
    try
        let msg = json_decode(line)
    catch
        return
    endtry
    if type(msg) != v:t_dict
        return
    endif

    let kind = get(msg, 'type', '')
    if kind ==# 'hello'
        let s:state.port = get(msg, 'port', 0)
        let s:state.token = get(msg, 'token', '')
    elseif kind ==# 'client'
        let s:state.clients[get(msg, 'session', '')] = get(msg, 'count', 0)
    elseif kind ==# 'error'
        call s:warn('md-sync: ' . get(msg, 'message', 'unknown error'))
    endif
endfunction

function! s:on_stderr(...) abort
    let line = a:0 > 1 ? a:2 : a:1
    if type(line) == v:t_string && line !=# ''
        call s:warn('md-sync: ' . line)
    endif
endfunction

function! s:on_stderr_nvim(id, data, event) abort
    for line in a:data
        call s:on_stderr(line)
    endfor
endfunction

function! s:on_exit(...) abort
    let s:state.job = v:null
    let s:state.port = 0
    let s:state.token = ''
    let s:state.clients = {}
endfunction

function! s:stop() abort
    if has('nvim')
        if type(s:state.job) == v:t_number && s:state.job > 0
            silent! call jobstop(s:state.job)
        endif
    else
        if type(s:state.job) == v:t_job && job_status(s:state.job) ==# 'run'
            silent! call job_stop(s:state.job)
        endif
    endif
    let s:state.job = v:null
    let s:state.port = 0
endfunction


function! s:bind_autocmds() abort
    if s:state.bound
        return
    endif
    let s:state.bound = 1
    augroup md_sync
        autocmd!
        autocmd CursorMoved,CursorMovedI,BufEnter * call s:schedule_push()
        if exists('##WinScrolled')
            autocmd WinScrolled * call s:schedule_push()
        endif
        autocmd BufWritePost * call s:on_write(expand('<afile>:p'), str2nr(expand('<abuf>')))
        autocmd TextChanged,TextChangedI * call s:schedule_temp_flush()
        autocmd VimLeavePre * call s:on_vim_leave()
    augroup END
endfunction

function! s:on_vim_leave() abort
    if s:state.port > 0 && s:cfg.close_tab_on_exit
        call s:send({'type': 'close'})
        sleep 200m
    endif
    call s:cleanup_temps()
    call s:stop()
endfunction

function! s:schedule_push() abort
    if &filetype !=# 'markdown'
        return
    endif
    if s:state.timer != -1
        call timer_stop(s:state.timer)
    endif
    let s:state.timer = timer_start(s:cfg.throttle_ms, function('s:push_pos'))
endfunction

function! s:push_pos(timer) abort
    let s:state.timer = -1
    if &filetype !=# 'markdown' || s:state.port == 0
        return
    endif
    let key = get(s:state.bufkey, bufnr('%'), '')
    let session = get(s:state.opened, key, '')
    if empty(session)
        return
    endif
    let lnum = line('.')
    if lnum == s:state.last_line && key ==# s:state.last_key
        return
    endif
    let s:state.last_line = lnum
    let s:state.last_key = key
    call s:send({'type': 'pos', 'session': session, 'file': s:preview_target(key), 'line': lnum})
endfunction

function! s:on_write(file, bufnr) abort
    let key = get(s:state.bufkey, a:bufnr, '')
    if empty(key)
        let key = a:file
    endif
    let session = get(s:state.opened, key, '')
    if empty(session)
        return
    endif
    call s:flush_temp_buf(a:bufnr)
    call s:send({'type': 'reload', 'session': session, 'file': s:preview_target(key)})
endfunction

function! s:preview_target(key) abort
    if empty(a:key)
        return ''
    endif
    let temp = get(s:state.temp, a:key, '')
    return empty(temp) ? a:key : temp
endfunction


function! s:schedule_temp_flush() abort
    let bufnr = bufnr('%')
    let key = get(s:state.bufkey, bufnr, '')
    if empty(key) || !has_key(s:state.temp, key)
        return
    endif
    if s:state.temp_timer != -1
        call timer_stop(s:state.temp_timer)
    endif
    let s:state.temp_timer = timer_start(400, function('s:flush_temp', [bufnr]))
endfunction

function! s:flush_temp(bufnr, timer) abort
    let s:state.temp_timer = -1
    call s:flush_temp_buf(a:bufnr)
endfunction

function! s:flush_temp_buf(bufnr) abort
    let key = get(s:state.bufkey, a:bufnr, '')
    if empty(key)
        return
    endif
    let temp = get(s:state.temp, key, '')
    if empty(temp)
        return
    endif
    let lines = getbufline(a:bufnr, 1, '$')
    if has_key(s:state.temp_content, key) && lines ==# s:state.temp_content[key]
        return
    endif
    call writefile(lines, temp)
    let s:state.temp_content[key] = lines
    let session = get(s:state.opened, key, '')
    if !empty(session)
        call s:send({'type': 'reload', 'session': session, 'file': temp})
    endif
endfunction

function! s:cleanup_temps() abort
    for temp in values(s:state.temp)
        if type(temp) == v:t_string && temp !=# ''
            silent! call delete(temp)
        endif
    endfor
    let s:state.temp = {}
    let s:state.temp_content = {}
endfunction


" Params must live in the hash: Chrome does not inject content scripts
" into "*.md" URLs that carry a query string.
function! s:build_url(file, session) abort
    let path = substitute(a:file, '\\', '/', 'g')
    let prefix = path =~# '^/' ? 'file://' : 'file:///'
    let url = printf('%s%s#mdp=%s&mdpPort=%d&mdpToken=%s',
        \ prefix, s:url_encode(path), a:session, s:state.port, s:state.token)
    let win = s:normalize_window(s:cfg.window)
    if !empty(win) && win !=# 'off'
        let url .= '&mdpWin=' . s:url_encode(win)
        let gap = str2nr(s:cfg.window_gap)
        if gap < 0
            let gap = 0
        elseif gap > 64
            let gap = 64
        endif
        let url .= '&mdpGap=' . gap
    endif
    return url
endfunction

function! s:normalize_window(spec) abort
    if type(a:spec) != v:t_string
        return ''
    endif
    let spec = tolower(trim(a:spec))
    let aliases = {'right-half': 'right', 'left-half': 'left', 'middle': 'center'}
    return get(aliases, spec, spec)
endfunction

function! s:utf8_bytes(cp) abort
    if a:cp < 0x80
        return [a:cp]
    elseif a:cp < 0x800
        return [0xC0 + a:cp / 64, 0x80 + a:cp % 64]
    elseif a:cp < 0x10000
        return [0xE0 + a:cp / 4096, 0x80 + (a:cp / 64) % 64, 0x80 + a:cp % 64]
    endif
    return [0xF0 + a:cp / 262144, 0x80 + (a:cp / 4096) % 64,
        \ 0x80 + (a:cp / 64) % 64, 0x80 + a:cp % 64]
endfunction

function! s:url_encode(str) abort
    let out = []
    for cp in str2list(a:str)
        if cp < 0x80 && nr2char(cp) =~# '[0-9A-Za-z_.~/-]'
            call add(out, nr2char(cp))
        else
            for b in s:utf8_bytes(cp)
                call add(out, printf('%%%02X', b))
            endfor
        endif
    endfor
    return join(out, '')
endfunction

function! s:open(url) abort
    if type(s:cfg.opener) == v:t_func
        call call(s:cfg.opener, [a:url])
        return
    endif
    if type(s:cfg.opener) == v:t_list && !empty(s:cfg.opener)
        let cmd = s:cfg.opener + [a:url]
    elseif type(s:cfg.opener) == v:t_string && s:cfg.opener !=# ''
        let cmd = [s:cfg.opener, a:url]
    else
        let cmd = s:open_command(a:url)
    endif
    if has('nvim')
        call jobstart(cmd)
    else
        call job_start(cmd)
    endif
endfunction

function! s:open_command(url) abort
    let browser = s:browser_name()
    let extra = s:browser_args()
    let chromium = s:is_chromium(browser)

    if has('mac')
        " Only Chromium browsers accept --args --new-window.
        if !empty(browser) && s:mac_app_available(browser)
            if s:cfg.new_window && chromium
                return ['open', '-na', browser, '--args'] + extra + ['--new-window', a:url]
            endif
            if !empty(extra)
                return ['open', '-a', browser, '--args'] + extra + [a:url]
            endif
            return ['open', '-a', browser, a:url]
        endif
        return ['open', a:url]
    endif

    if has('win32')
        let exe = s:resolve_windows_browser(browser)
        if !empty(exe)
            let args = s:cfg.new_window && chromium ? ['--new-window'] + extra : extra
            return [exe] + args + [a:url]
        endif
        return ['cmd', '/c', 'start', '', a:url]
    endif

    let exe = s:resolve_posix_browser(browser)
    if !empty(exe)
        let args = s:cfg.new_window && chromium ? ['--new-window'] + extra : extra
        return [exe] + args + [a:url]
    endif
    return ['xdg-open', a:url]
endfunction

function! s:browser_name() abort
    if type(s:cfg.browser) != v:t_string
        return ''
    endif
    if !empty(s:cfg.browser)
        return s:cfg.browser
    endif
    return has('mac') ? 'Google Chrome' : has('win32') ? 'chrome' : 'google-chrome'
endfunction

function! s:browser_args() abort
    return type(s:cfg.browser_args) == v:t_list ? copy(s:cfg.browser_args) : []
endfunction

function! s:is_chromium(name) abort
    return a:name =~? '\%(chrome\|chromium\|brave\|edge\|vivaldi\|arc\|opera\)'
endfunction

function! s:mac_app_available(name) abort
    if type(a:name) != v:t_string || a:name ==# ''
        return 0
    endif
    if a:name =~# '/'
        return isdirectory(a:name)
    endif
    return isdirectory('/Applications/' . a:name . '.app')
        \ || isdirectory(expand('~/Applications/' . a:name . '.app'))
endfunction

function! s:resolve_posix_browser(name) abort
    if empty(a:name)
        return ''
    endif
    if a:name =~# '/' && executable(a:name)
        return a:name
    endif
    return exepath(a:name)
endfunction

function! s:resolve_windows_browser(name) abort
    if empty(a:name)
        return ''
    endif
    let exe = exepath(a:name)
    if !empty(exe)
        return exe
    endif
    if a:name =~? 'chrome'
        for candidate in [
            \ $ProgramFiles . '\Google\Chrome\Application\chrome.exe',
            \ $LOCALAPPDATA . '\Google\Chrome\Application\chrome.exe',
            \ ]
            if executable(candidate)
                return candidate
            endif
        endfor
    endif
    return ''
endfunction


function! s:platform() abort
    return [has('mac') ? 'darwin' : has('win32') ? 'windows' : 'linux',
        \ s:arch(), has('win32') ? '.exe' : '']
endfunction

function! s:binary_name() abort
    let [os, arch, ext] = s:platform()
    return 'md-sync-server_' . os . '_' . arch . ext
endfunction

" Prefer the plugin dir; fall back to the user data dir.
function! s:download_dir() abort
    let dirs = [s:plugin_root . '/bin']
    if has('nvim') && exists('*stdpath')
        call add(dirs, stdpath('data') . '/md-sync/bin')
    endif
    if has('win32')
        call add(dirs, $LOCALAPPDATA . '\md-sync\bin')
    else
        let base = empty($XDG_DATA_HOME) ? expand('~/.local/share') : $XDG_DATA_HOME
        call add(dirs, base . '/md-sync/bin')
    endif
    for dir in dirs
        if isdirectory(dir)
            if filewritable(dir) == 2
                return dir
            endif
        elseif filewritable(fnamemodify(dir, ':h')) == 2
            return dir
        endif
    endfor
    return ''
endfunction

function! s:download_urls(name) abort
    if !empty(get(s:cfg, 'download_base', ''))
        let base = substitute(s:cfg.download_base, '/\+$', '', '')
        return [base . '/' . a:name, base . '/checksums.txt']
    endif
    let repo = s:cfg.server_repo
    let ver = s:cfg.server_version
    if empty(ver) || ver ==# 'latest'
        let prefix = printf('https://github.com/%s/releases/latest/download/', repo)
    else
        let prefix = printf('https://github.com/%s/releases/download/%s/', repo, ver)
    endif
    return [prefix . a:name, prefix . 'checksums.txt']
endfunction

function! s:download_to(url, dest) abort
    if executable('curl')
        let cmd = 'curl -fsSL --connect-timeout 10 --max-time 180 -o '
            \ . shellescape(a:dest) . ' ' . shellescape(a:url)
    elseif executable('wget')
        let cmd = 'wget -q -O ' . shellescape(a:dest) . ' ' . shellescape(a:url)
    elseif has('win32')
        let cmd = 'powershell -NoProfile -Command "Invoke-WebRequest -UseBasicParsing -Uri '''
            \ . a:url . ''' -OutFile ''' . a:dest . '''"'
    else
        return [127, 'curl or wget not found']
    endif
    let out = system(cmd)
    return [v:shell_error, out]
endfunction

function! s:sha256(path) abort
    if executable('shasum')
        let out = system('shasum -a 256 ' . shellescape(a:path))
    elseif executable('sha256sum')
        let out = system('sha256sum ' . shellescape(a:path))
    elseif has('win32')
        let out = system('powershell -NoProfile -Command "(Get-FileHash -Algorithm SHA256 -LiteralPath '''
            \ . a:path . ''').Hash"')
    else
        return ''
    endif
    if v:shell_error
        return ''
    endif
    return tolower(matchstr(out, '\c\<[0-9a-f]\{64}\>'))
endfunction

function! s:expected_hash(sums_file, name) abort
    if !filereadable(a:sums_file)
        return ''
    endif
    for line in readfile(a:sums_file)
        let parts = matchlist(substitute(line, '\r$', '', ''), '^\(\x\{64}\)\s\+\*\?\(\S\+\)$')
        if !empty(parts) && parts[2] ==# a:name
            return tolower(parts[1])
        endif
    endfor
    return ''
endfunction

function! s:install_binary(force) abort
    let dir = s:download_dir()
    if empty(dir)
        call s:warn('No writable install directory; download the binary manually')
        return ''
    endif
    call mkdir(dir, 'p')

    let name = s:binary_name()
    let target = dir . '/' . name
    if !a:force && executable(target)
        return target
    endif

    let [asset_url, sums_url] = s:download_urls(name)
    let tmp = target . '.download'
    let tmp_sums = target . '.sums'
    call delete(tmp)
    call delete(tmp_sums)

    echomsg 'md-sync: downloading ' . name . ' ...'
    redraw

    let [code, out] = s:download_to(asset_url, tmp)
    if code != 0 || !filereadable(tmp)
        call delete(tmp)
        call s:warn('Download failed: ' . substitute(out, '\n', ' ', 'g'))
        return ''
    endif

    let [code2, _] = s:download_to(sums_url, tmp_sums)
    if code2 == 0
        let want = s:expected_hash(tmp_sums, name)
        let got = s:sha256(tmp)
        call delete(tmp_sums)
        if !empty(want) && got !=# '' && want !=# got
            call delete(tmp)
            call s:warn('Checksum mismatch; installation aborted')
            return ''
        endif
        if empty(want)
            echomsg 'md-sync: no checksum entry for this file, skipping verification'
        endif
    else
        call delete(tmp_sums)
        echomsg 'md-sync: checksums.txt unavailable, skipping verification'
    endif

    if !has('win32')
        call setfperm(tmp, 'rwxr-xr-x')
    endif
    if filereadable(target)
        call delete(target)
    endif
    if rename(tmp, target) != 0
        call delete(tmp)
        call s:warn('Cannot write ' . target)
        return ''
    endif
    return target
endfunction

function! s:find_binary() abort
    if type(s:cfg.binary) == v:t_string && !empty(s:cfg.binary)
        return s:cfg.binary
    endif
    if exists('g:md_sync_binary') && type(g:md_sync_binary) == v:t_string
                \ && !empty(g:md_sync_binary)
        return g:md_sync_binary
    endif

    let name = s:binary_name()
    let candidates = []
    let dir = s:download_dir()
    if !empty(dir)
        call add(candidates, dir . '/' . name)
    endif
    call add(candidates, s:plugin_root . '/bin/' . name)
    let [_, _, ext] = s:platform()
    call add(candidates, s:plugin_root . '/bin/md-sync-server' . ext)
    for candidate in candidates
        if executable(candidate)
            return candidate
        endif
    endfor

    if s:cfg.auto_install
        let installed = s:install_binary(0)
        if !empty(installed)
            return installed
        endif
    endif
    return exepath('md-sync-server')
endfunction

function! s:arch() abort
    if exists('g:md_sync_arch')
        return g:md_sync_arch
    endif
    if has('win64')
        let g:md_sync_arch = 'amd64'
    else
        let machine = substitute(system('uname -m'), '\n', '', 'g')
        let g:md_sync_arch = machine ==# 'x86_64' ? 'amd64'
            \ : machine ==# 'aarch64' ? 'arm64' : machine
    endif
    return g:md_sync_arch
endfunction

function! s:warn(msg) abort
    echohl WarningMsg
    echomsg 'md-sync: ' . a:msg
    echohl None
endfunction
