# Flux adds the short name flux for flux-cli. The directory is at the end of
# PATH, so another flux command, such as the one of fluxcd, comes first.
case ":$PATH:" in
*:@BINDIR@:*) ;;
*) PATH="${PATH:+$PATH:}@BINDIR@" ;;
esac
