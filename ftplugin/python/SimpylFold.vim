if exists('b:loaded_SimpylFold')
    finish
endif
let b:loaded_SimpylFold = 1

if &filetype ==# 'pyrex' || &filetype ==# 'cython'
    let b:SimpylFold_def_regex = '\v^\s*%(%(class|%(async\s+)?def|cdef|cpdef|ctypedef)\s+\w+)|cdef\s*:'
else
    let b:SimpylFold_def_regex = '\v^\s*%(class|%(async\s+)?def)\s+\w+|if\s+__name__\s*\=\=\s*%("__main__"|''__main__'')\s*:'
endif
let s:non_blank_regex = '^\s*[^[:space:]#]'
let s:multiline_def_end_regex = '):$'
let s:multiline_def_end_solo_regex = '^\s*):$'
let s:docstring_start_regex = '^\s*[rR]\?\("""\|''''''\)\%(.*\1\s*$\)\@!'
let s:docstring_end_single_regex = '''''''\s*$'
let s:docstring_end_double_regex = '"""\s*$'
let s:import_start_regex = '^\%(from\|import\)'
let s:import_cont_regex = 'from.*\((\)[^)]*$\|.*\(\\\)$'
let s:import_end_paren_regex = ')\s*$'
let s:import_end_esc_regex = '[^\\]$'

let s:fold_docstrings = !exists('g:SimpylFold_fold_docstring') || g:SimpylFold_fold_docstring
command! -bang SimpylFoldDocstrings let s:fold_docstrings = <bang>1 | call SimpylFoldRecache()
let s:fold_imports = !exists('g:SimpylFold_fold_import') || g:SimpylFold_fold_import
command! -bang SimpylFoldImports let s:fold_imports = <bang>1 | call SimpylFoldRecache()

function! s:indent(line)
    let ind = matchend(a:line, '^ *') / &tabstop
    " Fix indent for solo def multiline endings
    if a:line =~# s:multiline_def_end_solo_regex
        return ind + 1
    endif
    return ind
endfunction

" Determine the number of containing class or function definitions for the
" given line.
" This function requires that `lnum` is >= previous `lnum`s.
function! s:defs(cache, lines, non_blanks, lnum)
    if has_key(a:cache[a:lnum], 'defs')
        return a:cache[a:lnum]['defs']
    endif

    " Indent level
    let ind = s:indent(a:lines[a:lnum])
    let a:cache[a:lnum]['indent'] = ind  " Cache for use in the loop
    if ind == 0
        let a:cache[a:lnum]['defs'] = 0
        return 0
    endif

    " Walk backwards to find the previous non-blank line with
    " a lower indent level than this line
    let non_blanks_prev = a:non_blanks[:index(a:non_blanks, a:lnum) - 1]
    for lnum_prev in reverse(copy(non_blanks_prev))
        if a:cache[lnum_prev]['indent'] < ind
            let defs = s:defs(a:cache, a:lines, non_blanks_prev, lnum_prev) +
                \ a:cache[lnum_prev]['is_def']
            let a:cache[a:lnum]['defs'] = defs
            return defs
        endif
    endfor

    let a:cache[a:lnum]['defs'] = 0
    return 0
endfunction

" Construct a foldexpr value and cache it
function! s:foldexpr(cache_lnum, foldlevel, is_beginning)
    if a:is_beginning
        let a:cache_lnum['foldexpr'] = '>' . a:foldlevel
    else
        let a:cache_lnum['foldexpr'] = a:foldlevel
    endif
endfunction

function! s:cache()
    let cache = [{}]  " With padding for lnum offset
    let lines = getbufline(bufnr('%'), 1, '$')
    let lnum_last = len(lines)
    call insert(lines, '')  " Padding for lnum offset

    " Cache everything generic that needs to be used later
    let non_blanks = []
    for lnum in range(1, lnum_last)
        let line = lines[lnum]
        if line =~# s:non_blank_regex
            call add(non_blanks, lnum)
            call add(cache, {'blank': 0, 'is_def': line =~# b:SimpylFold_def_regex})
        else
            call add(cache, {'blank': 1, 'is_def': 0, 'foldexpr': -1})
        endif
    endfor

    " Cache non-blanks
    let in_docstring = 0
    let in_import = 0
    for lnum in non_blanks
        let line = lines[lnum]

        " Docstrings
        if s:fold_docstrings
            if in_docstring
                if line =~# docstring_end_regex
                    let in_docstring = 0
                endif

                call s:foldexpr(cache[lnum], s:defs(cache, lines, non_blanks, lnum) + 1, 0)
                continue
            else
                let lnum_prev = lnum - 1
                if !cache[lnum_prev]['blank']
                    let docstring_match = matchlist(line, s:docstring_start_regex)
                    if !empty(docstring_match) &&
                            \ (cache[lnum_prev]['is_def'] ||
                            \  lines[lnum_prev] =~# s:multiline_def_end_regex)
                        let in_docstring = 1

                        if docstring_match[1] ==# '"""'
                            let docstring_end_regex = s:docstring_end_double_regex
                        else
                            let docstring_end_regex = s:docstring_end_single_regex
                        endif

                        call s:foldexpr(cache[lnum], s:defs(cache, lines, non_blanks, lnum) + 1, 1)
                        continue
                    endif
                endif
            endif
        endif

        " Imports
        if s:fold_imports
            if in_import
                if line =~# import_end_regex
                    let in_import = 0
                endif

                call s:foldexpr(cache[lnum], s:defs(cache, lines, non_blanks, lnum) + 1, 0)
                continue
            elseif match(line, s:import_start_regex) != -1
                let import_cont_match = matchlist(line, s:import_cont_regex)
                if !empty(import_cont_match)
                    if import_cont_match[1] ==# '('
                        let import_end_regex = s:import_end_paren_regex
                        let in_import = 1
                    elseif import_cont_match[2] ==# '\'
                        let import_end_regex = s:import_end_esc_regex
                        let in_import = 1
                    endif
                endif

                if in_import
                    call s:foldexpr(cache[lnum], s:defs(cache, lines, non_blanks, lnum) + 1, 1)
                    continue
                endif
            endif
        endif

        " Otherwise, its fold level is equal to its number of containing
        " definitions, plus 1, if this line starts a definition of its own
        call s:foldexpr(
            \ cache[lnum],
            \ s:defs(cache, lines, non_blanks, lnum) + cache[lnum]['is_def'],
            \ cache[lnum]['is_def'],
        \ )
    endfor

    return cache
endfunction

" Compute fold level for Python code
function! SimpylFold(lnum)
    if !exists('b:SimpylFold_cache')
        let b:SimpylFold_cache = s:cache()
    endif
    return b:SimpylFold_cache[a:lnum]['foldexpr']
endfunction

" Recache the buffer
function! SimpylFoldRecache()
    if exists('b:SimpylFold_cache')
        unlet b:SimpylFold_cache
    endif
endfunction

" Obtain the first line of the docstring for the folded class or function, if
" any exists, for use in the fold text
function! SimpylFoldText()
    let next = nextnonblank(v:foldstart + 1)
    let docstring = getline(next)
    let ds_prefix = '^\s*\%(\%(["'']\)\{3}\|[''"]\ze[^''"]\)'
    if docstring =~# ds_prefix
        let quote_char = docstring[match(docstring, '["'']')]
        let docstring = substitute(docstring, ds_prefix, '', '')
        if docstring !~# s:non_blank_regex
            let docstring =
                \ substitute(getline(nextnonblank(next + 1)), '^\s*', '', '')
        endif
        let docstring = substitute(docstring, quote_char . '\{,3}$', '', '')
        return ' ' . docstring
    endif
    return ''
endfunction

augroup SimpylFold
    autocmd TextChanged,InsertLeave <buffer> call SimpylFoldRecache()
augroup END

setlocal foldexpr=SimpylFold(v:lnum)
setlocal foldmethod=expr

if exists('g:SimpylFold_docstring_preview') && g:SimpylFold_docstring_preview
    setlocal foldtext=foldtext()\ .\ SimpylFoldText()
endif
