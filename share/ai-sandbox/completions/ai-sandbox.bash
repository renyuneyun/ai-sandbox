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
            COMPREPLY=($(compgen -W "claude codex opencode" -- "$cur"))
            return 0
            ;;
    esac

    if [[ "$cur" == -* ]]; then
        COMPREPLY=($(compgen -W "--help -h --version -V --tool --allow-local-git --" -- "$cur"))
        return 0
    fi

    # The optional workspace argument: complete directories.
    COMPREPLY=($(compgen -d -- "$cur"))
    return 0
}

complete -F _ai_sandbox ai-sandbox asb asb-claude asb-codex asb-opencode