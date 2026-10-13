# bash completion for ai-sandbox and its aliases (asb / asb-claude / asb-codex /
# asb-opencode). Keep in sync with the launcher's --help text when options,
# tools, or aliases change (see docs/development.md).
_ai_sandbox() {
    local cur prev i
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    # Everything after a bare -- belongs to the selected tool; defer to the
    # shell's default (file) completion there.
    for ((i = 1; i < COMP_CWORD; i++)); do
        [[ "${COMP_WORDS[i]}" == "--" ]] && return 0
    done

    case "$prev" in
        --tool)
            if [[ "${COMP_WORDS[1]:-}" == serve ]]; then
                COMPREPLY=($(compgen -W "opencode" -- "$cur"))
            else
                COMPREPLY=($(compgen -W "claude codex opencode" -- "$cur"))
            fi
            return 0
            ;;
        --git-preset)
            COMPREPLY=($(compgen -W "strict daily relaxed" -- "$cur"))
            return 0
            ;;
        --runtime)
            COMPREPLY=($(compgen -W "docker bwrap" -- "$cur"))
            return 0
            ;;
        serve)
            COMPREPLY=($(compgen -W "start stop attach" -- "$cur"))
            return 0
            ;;
        --hostname)
            COMPREPLY=($(compgen -W "all lo" -- "$cur"))
            return 0
            ;;
        --port)
            return 0
            ;;
    esac

    if [[ "${COMP_WORDS[1]:-}" == serve ]]; then
        if [[ "$cur" == -* ]]; then
            COMPREPLY=($(compgen -W "--tool --git-preset --hostname --port --headless --allow-local-git" -- "$cur"))
        else
            COMPREPLY=($(compgen -d -- "$cur"))
        fi
        return 0
    fi

    if [[ "$cur" == -* ]]; then
        COMPREPLY=($(compgen -W "--help -h --version -V --tool --git-preset --allow-local-git --runtime --read-home --" -- "$cur"))
        return 0
    fi

    # The optional workspace argument: complete directories.
    COMPREPLY=($(compgen -W "serve" -- "$cur") $(compgen -d -- "$cur"))
    return 0
}

complete -F _ai_sandbox ai-sandbox asb asb-claude asb-codex asb-opencode
