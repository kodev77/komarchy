#!/usr/bin/env bash
# dataverse: vimscript db adapter routing queries through dvquery cli
set -euo pipefail

NVIM_DIR="$HOME/.config/nvim"

echo "Writing Dataverse adapter for vim-dadbod..."

mkdir -p "$NVIM_DIR/autoload/db/adapter"
cat > "$NVIM_DIR/autoload/db/adapter/dataverse.vim" << 'VIMEOF'
" Dataverse adapter for vim-dadbod
" Routes queries through dvquery CLI tool

function! db#adapter#dataverse#canonicalize(url) abort
  return a:url
endfunction

function! s:conn_name(url) abort
  " Find connection name from connections.json matching this URL
  let l:save_loc = get(g:, 'db_ui_save_location', expand('~/.local/share/db_ui'))
  let l:conn_file = l:save_loc . '/connections.json'
  if filereadable(l:conn_file)
    let l:connections = json_decode(join(readfile(l:conn_file), ''))
    for l:conn in l:connections
      if get(l:conn, 'url', '') ==# a:url
        return get(l:conn, 'name', '')
      endif
    endfor
  endif
  return ''
endfunction

function! s:dvquery_cmd(url) abort
  let l:name = s:conn_name(a:url)
  if !empty(l:name)
    return ['dvquery', '-c', l:name]
  endif
  return ['dvquery']
endfunction

function! db#adapter#dataverse#interactive(url) abort
  return s:dvquery_cmd(a:url) + ['-i']
endfunction

function! db#adapter#dataverse#input(url, in) abort
  return s:dvquery_cmd(a:url) + ['--vim', '-f', a:in]
endfunction

function! db#adapter#dataverse#tables(url) abort
  let l:cmd = s:dvquery_cmd(a:url) + ['--vim', '--tables']
  return db#systemlist(l:cmd)
endfunction

function! db#adapter#dataverse#complete_database(url) abort
  return []
endfunction
VIMEOF

echo "  autoload/db/adapter/dataverse.vim: OK"
