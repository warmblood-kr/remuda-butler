# Invoke awk with a hard deadline. exec keeps the Perl alarm attached to awk's
# PID, so a stuck awk is terminated instead of surviving as an orphan.
bounded_awk() { perl -e 'alarm 15; exec @ARGV' awk "$@"; }
