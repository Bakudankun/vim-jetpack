"=================================== Jetpack ==================================
"Copyright (c) 2022 TANIGUCHI Masaya
"
"Permission is hereby granted, free of charge, to any person obtaining a copy
"of this software and associated documentation files (the "Software"), to deal
"in the Software without restriction, including without limitation the rights
"to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
"copies of the Software, and to permit persons to whom the Software is
"furnished to do so, subject to the following conditions:
"
"The above copyright notice and this permission notice shall be included in all
"copies or substantial portions of the Software.
"
"THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
"IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
"FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
"AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
"LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
"OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
"SOFTWARE.
"==============================================================================
vim9script

if exists('g:loaded_jetpack')
  finish
endif
g:loaded_jetpack = 1

def Execute(code: string)
  if !code->trim()
    return
  endif
  :execute "function g:JetpackTemp() abort\n" .. code .. "\nendfunction"
  try
    g:JetpackTemp()
  finally
    delfunction g:JetpackTemp
  endtry
enddef

g:jetpack_njobs = get(g:, 'jetpack_njobs', 8)

g:jetpack_download_method =
  get(g:, 'jetpack_download_method', has('ivim') ? 'curl' : 'git')
  # curl: Use CURL to download
  # wget: Use Wget to download

type PkgOpts = dict<any>

enum Status
  pending,
  skipped,
  installed,
  installing,
  updated,
  updating,
  switched,
  copied
endenum

class Package
  const keys:	list<string>
  const cmd:	list<string>
  const event:	list<string>
  const url:	string
  const local:	bool
  const branch:	string
  const tag:	string
  const commit:	string
  const rtp:	string
  const do:	any
  const frozen:	bool
  const dir:	string
  const path:	string
  final status:	list<Status> = [Status.pending]
  var output:	string = ''
  const hook_add:	string
  const hook_source:	string
  const hook_post_source:	string
  const dependees:	list<string>
  const dependers_before:	list<string>
  const dependers_after:	list<string>
  const opt:	bool

  def new(plugin: string, opts: PkgOpts = {})
    const name: string = Gets(opts, ['as', 'name'], [fnamemodify(plugin, ':t')])[0]
    if has_key(declared_packages, name)
      return
    endif
    this.local = IsLocalPlug(plugin)
    this.url = this.local ? expand(plugin) : (plugin !~ '.\+://' ? 'https://github.com/' : '') .. plugin
    this.path = optdir .. '/' ..  substitute(this.url, '.\+/\(.\+\)', '\1', '')
    this.path = expand(this.local ? plugin : Gets(opts, ['dir', 'path'], [this.path])[0])
    this.dependees = Gets(opts, ['requires', 'depends'], [])
    map(this.dependees, (_, r) => r =~ '/' ? substitute(r, '.*/', '', '') : r)
    this.dependers_before = Gets(opts, ['before', 'on_source'], [])
    map(this.dependers_before, (_, r) => r =~ '/' ? substitute(r, '.*/', '', '') : r)
    this.dependers_after = Gets(opts, ['after', 'on_post_source'], [])
    map(this.dependers_after, (_, r) => r =~ '/' ? substitute(r, '.*/', '', '') : r)
    final keys_on = Gets(opts, ['on'], [])
    filter(keys_on, (_, k) => k =~? '^<Plug>')
    this.keys = keys_on + Gets(opts, ['keys', 'on_map'], [])
    final cmd_on = Gets(opts, ['on'], [])
    filter(cmd_on, (_, k) => k =~? '^[A-Z]')
    this.cmd = cmd_on + Gets(opts, ['cmd', 'on_cmd'], [])
    this.event = Gets(opts, ['on', 'event', 'on_event'], [])
    filter(this.event, (_, v) => exists('##' .. substitute(v, ' .*', '', '')))
    final filetypes = Gets(opts, ['for', 'ft', 'on_ft'], [])
    extend(this.event, map(filetypes, (_, ft) => 'FileType ' .. ft))

    this.branch = get(opts, 'branch', '')
    this.tag = get(opts, 'tag', '')
    this.commit = get(opts, 'commit', 'HEAD')
    this.rtp = get(opts, 'rtp', '')
    this.do = Gets(opts, ['do', 'run', 'build'], [''])[0]
    this.frozen = Gets(opts, ['frozen', 'lock'], [false])[0]
    this.dir = Gets(opts, ['dir', 'path'], [''])[0]
    this.hook_add = get(opts, 'hook_add', '')
    this.hook_source = get(opts, 'hook_source', '')
    this.hook_post_source = get(opts, 'hook_post_source', '')
    this.opt = get(opts, 'opt', this.IsOpt())

    declared_packages[name] = this
    Execute(this.hook_add)
  enddef

  def MakeDownloadCmd(): list<string>
    var download_method = g:jetpack_download_method
    if this.url =~? '\.tar\.gz$'
      download_method = 'curl'
    endif
    if download_method == 'git'
      if isdirectory(this.path)
        return [$'git -C {this.path} pull --rebase']
      else
        final git_cmd = ['git', 'clone']
        if this.commit == 'HEAD'
          extend(git_cmd, ['--depth', '1', '--recursive'])
        endif
        if !empty(this.branch)
          extend(git_cmd, ['-b', this.branch])
        endif
        if !empty(this.tag)
          extend(git_cmd, ['-b', this.tag])
        endif
        extend(git_cmd, [this.url, this.path])
        var rmdir_cmd: string
        var mkdir_cmd: string
        if has('unix')
          rmdir_cmd = $'rm -rf {this.path}'
          mkdir_cmd = $'mkdir -p {this.path}'
        else
          rmdir_cmd = $'(if exist {this.path} rmdir /s /q {this.path})'
          mkdir_cmd = $'mkdir {this.path}'
        endif
        return [rmdir_cmd, mkdir_cmd, join(git_cmd, ' ')]
      endif
    else
      const temp = tempname()
      var label: string
      if !empty(this.tag)
        label = this.tag
      elseif !empty(this.branch)
        label = this.branch
      else
        label = this.commit
      endif
      var download_cmd: string
      if download_method == 'curl'
        const curl_flags = has('ivim') ? ' -kfsSL ' : ' -fsSL '
        if this.url =~? '\.tar\.gz$'
          download_cmd = $'curl{curl_flags}{this.url} -o {temp}'
        else
          download_cmd = $'curl{curl_flags}{this.url}/archive/{label}.tar.gz -o {temp}'
        endif
      elseif download_method == 'wget'
        if this.url =~? '\.tar\.gz$'
          download_cmd = $'wget {this.url} -O {temp}'
        else
          download_cmd = $'wget {this.url}/archive/{label}.tar.gz -O {temp}'
        endif
      else
        throw $'g:jetpack_download_method: {download_method} is not a valid value'
      endif
      var extract_cmd = $'tar -zxf {temp} -C {this.path} --strip-components 1'
      var rmdir_cmd_1: string
      var rmdir_cmd_2: string
      var mkdir_cmd: string
      if has('unix')
        rmdir_cmd_1 = $'rm -rf {this.path}'
        rmdir_cmd_2 = $'rm {temp}'
        mkdir_cmd = $'mkdir -p {this.path}'
      else
        rmdir_cmd_1 = $'(if exist {this.path} rmdir /s /q {this.path})'
        rmdir_cmd_2 = $'(if exist {temp} del {temp})'
        mkdir_cmd = $'mkdir {this.path}'
      endif
      return [rmdir_cmd_1, mkdir_cmd, download_cmd, extract_cmd, rmdir_cmd_2]
    endif
  enddef

  def Download(jobs: list<job>)
    if this.local
      return
    endif
    ShowProgress('Install Plugins')
    var status: Status
    if isdirectory(this.path)
      if this.frozen
        add(this.status, Status.skipped)
        return
      endif
      add(this.status, Status.updating)
      status = Status.updated
    else
      add(this.status, Status.installing)
      status = Status.installed
    endif
    final commands = this.MakeDownloadCmd()
    if executable('sh') || executable('cmd.exe')
      const cmd = [
        (has('unix') ? 'sh' : 'cmd.exe'),
        (has('unix') ? '-c' : '/c'),
        join(commands, ' && ')
      ]
      const job = Jobstart(cmd, (output) => {
        add(this.status, status)
        this.output = output
      })
      add(jobs, job)
      Jobwait(jobs, g:jetpack_njobs)
    else
      this.output = join(map(commands, (_, cmd) => System(cmd)), "\n")
      add(this.status, status)
    endif
  enddef

  def IsOpt(): bool
    return !!this.dependers_before
      || !!this.dependers_after
      || !!this.cmd
      || !!this.keys
      || !!this.event
  enddef

  def ToDict(): dict<any>
    return {local: this.local, dir: this.dir, path: this.path}
  enddef

  # Original: https://github.com/junegunn/vim-plug/blob/e3001/plug.vim#L479-L529
  #  License: MIT, https://raw.githubusercontent.com/junegunn/vim-plug/e3001/LICENSE
  static def IsLocalPlug(repo: string): bool
    if has('win32')
      return repo =~? '^[a-z]:\|^[%~]'
    else
      return repo[0] =~ '[/$~]'
    endif
  enddef
endclass


var cmds: dict<list<string>>
var maps: dict<list<string>>
var declared_packages: dict<Package>
final loaded_count: dict<number> = {}
var available_packages: dict<dict<any>>
var optdir: string


def ParseToml(lines: list<string>): list<PkgOpts>
  final plugins = []
  var plugin = {}
  var key = ''
  var multiline = ''
  for line: string in lines
    if !!multiline
      plugin[key] ..= line .. (multiline =~ ']' ? "" : "\n")
      if line =~ multiline
        if multiline == ']'
          plugin[key] = eval(plugin[key])
        else
          plugin[key] = substitute(plugin[key], multiline, '', 'g')
        endif
        multiline = ''
      endif
    elseif trim(line) =~ '^#\|^$'
    elseif line =~ '\[\[plugins\]\]'
      add(plugins, deepcopy(plugin))
      plugin = {}
    elseif line =~ '\(\w\+\)\s*=\s*'
      key = substitute(line, '\(\w\+\)\s*=\s*.*', '\1', '')
      var raw = substitute(line, '\w\+\s*=\s*', '', '')
      if raw =~ "\\(\"\"\"\\|'''\\)\\(.*\\)\\1"
        plugin[key] = substitute(raw, "\\(\"\"\"\\|'''\\)\\(.*\\)\\1", '\2', '')
      elseif raw =~ '"""' || raw =~ "'''"
        multiline = raw =~ '"""' ? '"""' : "'''"
        plugin[key] = raw
      elseif raw =~ '\[.*\]'
        plugin[key] = eval(raw)
      elseif raw =~ '\['
        multiline = ']'
        plugin[key] = raw
      else
        plugin[key] = eval(trim(raw) =~ 'true\|false' ? 'v:' .. raw : raw)
      endif
    endif
  endfor
  add(plugins, plugin)
  return filter(plugins, (_, val) => !!val)
enddef

def MakeProgressbar(n: float): string
  return '[' .. join(map(range(0, 100, 3), ((_, v) => v < n ? '=' : ' ')), '') .. ']'
enddef

def Jobcount(jobs: list<job>): number
  return len(filter(copy(jobs), (_, val) => job_status(val) == 'run'))
enddef

def Jobwait(jobs: list<job>, njobs: number)
  var running = Jobcount(jobs)
  while running > njobs
    running = Jobcount(jobs)
  endwhile
enddef

# Original: https://github.com/lambdalisue/vital-Whisky/blob/90c71/autoload/vital/__vital__/System/Job/Vim.vim#L46
#  License: https://github.com/lambdalisue/vital-Whisky/blob/90c71/LICENSE
def NvimExitCb(cmd: list<string>, buf: list<string>, Cb: func(string), job: job, st: number)
  const ch = job_getchannel(job)
  while ch_status(ch) == 'open' | sleep 1ms | endwhile
  while ch_status(ch) == 'buffered' | sleep 1ms | endwhile
  if st != 0
    :echoerr $'`{join(cmd, ' ')}`:{join(buf, "\n")}'
  endif
  Cb(join(buf, "\n"))
enddef

def Jobstart(cmd: list<string>, Cb: func): job
  final buf: list<string> = []
  return job_start(cmd, {
    out_mode: 'raw',
    out_cb: (_, data) => extend(buf, split(data, "\n")),
    err_mode: 'raw',
    err_cb: (_, data) => extend(buf, split(data, "\n")),
    exit_cb: function(NvimExitCb, [cmd, buf, Cb])
  })
enddef

def System(cmd: string): string
  final buf: list<string> = []
  const job = job_start(cmd, {
    out_cb: (_, data) => extend(buf, split(data, "\n"))
  })
  Jobwait([job], 0)
  return buf->join("\n")
enddef

def InitializeBuffer()
  :execute 'silent! bdelete!' bufnr('JetpackStatus')
  :silent :40vnew +setlocal\ buftype=nofile\ nobuflisted\ nonumber\ norelativenumber\ signcolumn=no\ noswapfile\ nowrap JetpackStatus
  :syntax clear
  :syntax match jetpackProgress /^[a-z]*ing/
  :syntax match jetpackComplete /^[a-z]*ed/
  :syntax keyword jetpackSkipped ^skipped
  :highlight def link jetpackProgress DiffChange
  :highlight def link jetpackComplete DiffAdd
  :highlight def link jetpackSkipped DiffDelete
  :redraw
enddef

def ShowProgress(title: string)
  const buf = bufnr('JetpackStatus')
  deletebufline(buf, 1, '$')
  const processed = len(filter(copy(declared_packages), (_, val) => val.status[-1].name =~ 'ed'))
  setbufline(buf, 1, $'{title} ({processed} / {len(declared_packages)})')
  appendbufline(buf, '$', MakeProgressbar((0.0 + processed) / len(declared_packages) * 100))
  for [pkg_name, pkg] in items(declared_packages)
    appendbufline(buf, '$', $'{pkg.status[-1].name} {pkg_name}')
  endfor
  redraw
enddef

def ShowResult()
  const buf = bufnr('JetpackStatus')
  deletebufline(buf, 1, '$')
  setbufline(buf, 1, 'Result')
  appendbufline(buf, '$', MakeProgressbar(100.0))
  for [pkg_name, pkg] in items(declared_packages)
    if index(pkg.status, Status.installed) >= 0
      appendbufline(buf, '$', $'installed {pkg_name}')
    elseif index(pkg.status, Status.updated) >= 0
      appendbufline(buf, '$', $'updated {pkg_name}')
    else
      appendbufline(buf, '$', $'skipped {pkg_name}')
    endif
    var output = substitute(pkg.output, '\r\n\|\r', '\n', 'g')
    output = substitute(output, '^From.\{-}\zs\n\s*', '/compare/', '')
    for line in split(output, '\n')
      appendbufline(buf, '$', $'  {line}')
    endfor
  endfor
  redraw
enddef

def CleanPlugins()
  for [pkg_name, pkg] in items(available_packages)
    if !has_key(declared_packages, pkg_name) && empty(pkg.local) && empty(pkg.dir)
      delete(pkg.path, 'rf')
    endif
  endfor
  if g:jetpack_download_method != 'git'
    return
  endif
  for [pkg_name, pkg] in items(declared_packages)
    if !isdirectory(pkg.path .. '/.git')
      delete(pkg.path, 'rf')
      continue
    endif
    if isdirectory(pkg.path)
      System($'git -C {pkg.path} reset --hard')
      const branch = trim(System($'git -C {pkg.path} rev-parse --abbrev-ref {pkg.commit}'))
      if v:shell_error && !empty(pkg.commit)
        delete(pkg.path, 'rf')
        continue
      endif
      if !empty(pkg.branch) && pkg.branch != branch
        delete(pkg.path, 'rf')
        continue
      endif
      if !empty(pkg.tag) && pkg.tag != branch
        delete(pkg.path, 'rf')
        continue
      endif
    endif
  endfor
enddef

def DownloadPlugins()
  final jobs: list<job> = []
  for [pkg_name, pkg] in items(declared_packages)
    add(pkg.status, Status.pending)
  endfor
  for [pkg_name, pkg] in items(declared_packages)
    pkg.Download(jobs)
  endfor
  Jobwait(jobs, 0)
enddef

def SwitchPlugins()
  if g:jetpack_download_method != 'git'
    return
  endif
  for [pkg_name, pkg] in items(declared_packages)
    add(pkg.status, Status.pending)
  endfor
  for [pkg_name, pkg] in items(declared_packages)
    ShowProgress('Switch Plugins')
    if !isdirectory(pkg.path)
      add(pkg.status, Status.skipped)
      continue
    else
      add(pkg.status, Status.switched)
    endif
    System($'git -C {pkg.path} checkout {pkg.commit}')
  endfor
enddef

def PostupdatePlugins()
  for [pkg_name, pkg] in items(declared_packages)
    if empty(pkg.do) || pkg.output =~ 'Already up to date.'
      continue
    endif
    Load(pkg_name)
    const pwd = chdir(pkg.path)
    if type(pkg.do) == v:t_func
      pkg.do()
    elseif type(pkg.do) == v:t_string
      if pkg.do =~ '^:'
        :execute pkg.do
      else
        System(pkg.do)
      endif
    endif
    chdir(pwd)
  endfor
  for dir in glob(optdir .. '/*/doc', false, 1)
    :execute 'silent! helptags' dir
  endfor
  mkdir(optdir .. '/_/plugin', 'p')
  mkdir(optdir .. '/_/after/plugin', 'p')
  writefile([
    'autocmd Jetpack User JetpackPre:init ++once :',
    'doautocmd <nomodeline> User JetpackPre:init'
  ], optdir .. '/_/plugin/hook.vim')
  writefile([
    'autocmd Jetpack User JetpackPost:init ++once :',
    'doautocmd <nomodeline> User JetpackPost:init'
  ], optdir .. '/_/after/plugin/hook.vim')
enddef

export def Sync()
  InitializeBuffer()
  CleanPlugins()
  DownloadPlugins()
  SwitchPlugins()
  ShowResult()
  available_packages = mapnew(declared_packages, (_, v) => v.ToDict())
  writefile([json_encode(available_packages)], optdir .. '/available_packages.json')
  PostupdatePlugins()
enddef

def Gets(opts: PkgOpts, keys: list<string>, default: any): any
  final values: list<any> = []
  for key: string in keys
    if has_key(opts, key)
      if type(opts[key]) == v:t_list
        extend(values, opts[key])
      else
        add(values, opts[key])
      endif
    endif
  endfor
  return values ?? default
enddef

export def Add(plugin: string, opts: PkgOpts = {})
  Package.new(plugin, opts)
enddef

def LoadToml(path: string)
  const lines = readfile(path)
  for pkg in ParseToml(lines)
    Add(pkg.repo, pkg)
  endfor
enddef

export def Begin(homepath: any = null)
  # In lua, passing nil and no argument are synonymous, but in practice, v:null is passed.
  var home: string
  if !!homepath
    home = expand(homepath)
    &runtimepath = $'{expand(home)},{&runtimepath}'
    &packpath = $'{expand(home)},{&packpath}'
  elseif has('win32')
    home = expand('~/vimfiles')
  else
    home = expand('~/.vim')
  endif
  cmds = {}
  maps = {}
  declared_packages = {}
  optdir = home .. '/pack/jetpack/opt'
  var runtimepath = split(&runtimepath, ',')
  runtimepath = filter(runtimepath, (_, v) => v !~ optdir)
  &runtimepath = join(runtimepath, ',')
  var available_packages_file = optdir .. '/available_packages.json'
  var available_packages_text =
    filereadable(available_packages_file)
    ? join(readfile(available_packages_file)) : "{}"
  available_packages = json_decode(available_packages_text)
  :augroup Jetpack
    :autocmd!
  :augroup END
  :command! -nargs=+ -bar Jetpack Add(<args>)
enddef

def Doautocmd(ord: string, pkg_name: string)
  const pkg = Get(pkg_name)
  if Tap(pkg_name) || (pkg.local && isdirectory($'{pkg.path}/{pkg.rtp}'))
    var pattern_a = $'jetpack_{pkg_name}_{ord}'
    pattern_a = substitute(pattern_a, '\W\+', '_', 'g')
    pattern_a = substitute(pattern_a, '\(^\|_\)\(.\)', '\u\2', 'g')
    const pattern_b = $'Jetpack{substitute(ord, '.*', '\u\0', '')}:{pkg_name}'
    for pattern in [pattern_a, pattern_b]
      if exists('#User#' .. pattern)
        :execute 'doautocmd <nomodeline> User' pattern
      endif
    endfor
  endif
enddef

def LoadPlugin(pkg_name: string)
  const pkg = Get(pkg_name)
  for dep_name in pkg.dependees
    LoadPlugin(dep_name)
  endfor
  &runtimepath = $'{pkg.path}/{pkg.rtp},{&runtimepath}'
  if v:vim_did_enter
    Doautocmd('pre', pkg_name)
    for file in glob($'{pkg.path}/{pkg.rtp}/plugin/**/*.vim', false, 1)
      :execute 'source' file
    endfor
  else
    const cmd = $'Doautocmd("pre", "{pkg_name}")'
    :execute 'autocmd Jetpack User JetpackPre:init ++once' cmd
  endif
enddef

def LoadAfterPlugin(pkg_name: string)
  const pkg = Get(pkg_name)
  &runtimepath = $'{&runtimepath},{pkg.path}/{pkg.rtp}'
  if v:vim_did_enter
    for file in glob($'{pkg.path}/{pkg.rtp}/after/plugin/**/*.vim', false, 1)
      :execute 'source' file
    endfor
    Doautocmd('post', pkg_name)
  else
    const cmd = $'Doautocmd("post", "{pkg_name}")'
    :execute 'autocmd Jetpack User JetpackPost:init ++once' cmd
  endif
  for dep_name in pkg.dependees
    LoadAfterPlugin(dep_name)
  endfor
enddef

def CheckDependees(pkg_name: string): bool
  if !Tap(pkg_name)
    return false
  endif
  const pkg = Get(pkg_name)
  for dep_name in pkg.dependees
    if !CheckDependees(dep_name)
      return false
    endif
  endfor
  return true
enddef

def Load(pkg_name: string): bool
  if !CheckDependees(pkg_name)
    return false
  endif
  LoadPlugin(pkg_name)
  LoadAfterPlugin(pkg_name)
  return true
enddef

# Original: https://github.com/junegunn/vim-plug/blob/e3001/plug.vim#L683-L693
#  License: MIT, https://raw.githubusercontent.com/junegunn/vim-plug/e3001/LICENSE
def LoadMap(map: string, names: list<string>, with_prefix: bool, prefix: string)
  for name in names
    Load(name)
  endfor
  var extra = ''
  var code = getchar(0)
  while (code != 0 && code != 27)
    extra ..= nr2char(code)
    code = getchar(0)
  endwhile
  if with_prefix
    var p = v:count ? v:count : ''
    p ..= $'"{v:register}{prefix}'
    if mode(1) == 'no'
      if v:operator == 'c'
        p = "\<Esc>" .. p
      endif
      p ..= v:operator
    endif
    feedkeys(p, 'n')
  endif
  feedkeys(substitute(map, '^<Plug>', "\<Plug>", 'i') .. extra)
enddef

def LoadCmd(cmd: string, names: list<string>, ...args: list<string>)
  :execute 'delcommand' cmd
  for name in names
    Load(name)
  endfor
  const argstr = join(args, ' ')
  try
    :execute cmd argstr
  catch /.*/
    :echohl ErrorMsg
    :echomsg v:exception
    :echohl None
  endtry
enddef

export def End()
  final runtimepath: list<string> = []
  :delcommand Jetpack
  :command! -bar JetpackSync Sync()

  :syntax off
  :filetype plugin indent off

  if !has_key(declared_packages, 'vim-jetpack')
    :echomsg 'vim-jetpack is not declared. Please add Add("tani/vim-jetpack") .'
  endif

  if sort(keys(declared_packages)) != sort(keys(available_packages))
    :echomsg 'Some packages are not synchronized. Run :JetpackSync'
  endif

  for [pkg_name, pkg] in items(declared_packages)
    for dep_name in pkg.dependers_before
      const cmd = $'Load("{pkg_name}")'
      const pattern = $'JetpackPre:{dep_name}'
      :execute 'autocmd Jetpack User' pattern '++once' cmd
    endfor
    const slug = substitute(pkg_name, '\W\+', '_', 'g')
    loaded_count[slug] = len(pkg.dependers_after)
    for dep_name in pkg.dependers_after
      const cmd =<< trim eval END
      {{
        if loaded_count[{slug}] == 1
          Load("{pkg_name}")
        else
          loaded_count[{slug}] -= 1
        endif
      }}
      END
      const pattern = $'JetpackPost:{dep_name}'
      :execute 'autocmd Jetpack User' pattern '++once' cmd->join("\n")
    endfor
    for it in pkg.keys
      maps[it] = add(get(maps, it, []), pkg_name)
      :execute $'inoremap <silent> {it} <C-\><C-O><ScriptCmd>LoadMap("{it}", {maps[it]}, 0, "")<CR>'
      :execute $'nnoremap <silent> {it} <ScriptCmd>LoadMap("{it}", {maps[it]}, 1, "")<CR>'
      :execute $'vnoremap <silent> {it} <ScriptCmd>LoadMap("{it}", {maps[it]}, 1, "gv")<CR>'
      :execute $'onoremap <silent> {it} <ScriptCmd>LoadMap("{it}", {maps[it]}, 1, "")<CR>'
    endfor
    for it in pkg.event
      const cmd = $'Load("{pkg_name}")'
      var [event, pattern] = split(it .. (it =~ ' ' ? '' : ' *'), ' ')
      :execute 'autocmd Jetpack' event pattern '++once' cmd
    endfor
    for it in pkg.cmd
      const cmd_name = substitute(it, '^:', '', '')
      cmds[cmd_name] = add(get(cmds, cmd_name, []), pkg_name)
      const cmd = $'LoadCmd("{cmd_name}", {cmds[cmd_name]}, <f-args>)'
      :execute 'command! -range -nargs=*' cmd_name cmd
    endfor
    if !empty(pkg.hook_source)
      const pattern = 'JetpackPre:' .. pkg_name
      const cmd = $'Execute(declared_packages["{pkg_name}"].hook_source)'
      :execute 'autocmd Jetpack User' pattern '++once' cmd
    endif
    if !empty(pkg.hook_post_source)
      const pattern = 'JetpackPost:' .. pkg_name
      const cmd = $'Execute(declared_packages["{pkg_name}"].hook_post_source)'
      :execute 'autocmd Jetpack User' pattern '++once' cmd
    endif
    if pkg.opt
      for file in glob(pkg.path .. '/ftdetect/*.vim', false, 1)
        #echomsg '[[source' file ']]'
        :execute 'source' file
      endfor
    else
      runtimepath
        ->insert($'{pkg.path}/{pkg.rtp}')
        ->add($'{pkg.path}/{pkg.rtp}/after')
      var cmd = $'Doautocmd("pre", "{pkg_name}")'
      :execute 'autocmd Jetpack User JetpackPre:init ++once' cmd
      cmd = $'Doautocmd("post", "{pkg_name}")'
      :execute 'autocmd Jetpack User JetpackPost:init ++once' cmd
    endif
  endfor
  runtimepath
    ->insert(optdir .. '/_')
    ->add(optdir .. '/_/after')
  &runtimepath ..= ',' .. join(runtimepath, ',')
  :syntax enable
  :filetype plugin indent on
enddef

export def Tap(name: string): bool
  return has_key(available_packages, name) && has_key(declared_packages, name)
enddef

export def Names(): list<string>
  return keys(declared_packages)
enddef

export def Get(name: string): Package
  return get(declared_packages, name, null_object)
enddef
