_immutable_overlays() {
    local overlays
    overlays=$(immutable list-names 2>/dev/null)
    if [ -z "$overlays" ]; then
        # Fallback: list overlay subvolumes directly if daemon isn't running
        overlays=$(ls -1d /pool/@overlay-* 2>/dev/null | sed 's|.*/@overlay-||')
        [ -d /pool/@base ] && overlays="$overlays
@base"
        [ -d /pool/@data ] && overlays="$overlays
@data"
    fi
    COMPREPLY=($(compgen -W "$overlays" -- "${COMP_WORDS[COMP_CWORD]}"))
}

_immutable() {
    local cur prev
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    local subcommands="create shell run list list-names switch reset delete status lock unlock recovery reset-recovery clean-boot update-initramfs update help"

    # Completing the command name itself (e.g. immu<TAB>)
    if [ "$COMP_CWORD" -eq 0 ]; then
        COMPREPLY=($(compgen -W "immutable" -- "$cur"))
        return
    fi

    # First argument: subcommands
    if [ "$COMP_CWORD" -eq 1 ]; then
        COMPREPLY=($(compgen -W "$subcommands" -- "$cur"))
        return
    fi

    local subcmd="${COMP_WORDS[1]}"

    case "$subcmd" in
        shell|run|switch|reset|delete)
            # Second argument: overlay names
            if [ "$COMP_CWORD" -eq 2 ]; then
                _immutable_overlays
                return
            fi
            # For 'run', third+ args are commands — no completion
            ;;
        create)
            case "$prev" in
                --from)
                    _immutable_overlays
                    ;;
                *)
                    if [ "$COMP_CWORD" -eq 2 ]; then
                        # New overlay name — no completion needed
                        return
                    fi
                    ;;
            esac
            ;;
    esac
}

complete -F _immutable immutable
