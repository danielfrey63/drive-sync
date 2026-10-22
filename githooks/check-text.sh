#!/bin/sh
# Pre-commit check: staged text files must carry the line endings
# .gitattributes pins for them (CRLF, LF for shell scripts) in the WORKING
# TREE, and no control characters.
#
# Why the working tree and not the index: this clone lives inside the Drive
# corpus. Drive carries the working-tree bytes to the second machine, git
# carries the normalised blob, and a fresh checkout there gets the pinned
# endings. A file that deviates here therefore differs byte-wise from the
# P16's checkout, and bisync parks one side as .conflictN - on 2026-10-09 that
# took two watcher modules away. On 2026-10-22 an LF file and a backspace byte
# (a "\b" mangled by a heredoc) each reached a staged file before a test
# caught them.
#
# Installed by install-git-hook.ps1 as one line of .git/hooks/pre-commit,
# next to the ai-toolbox line.

list="${TMPDIR:-/tmp}/drive-sync-check-text.$$"
trap 'rm -f "$list"' EXIT

# one "path<TAB>eol" line per staged text file that is not marked binary
git diff --cached --name-only --diff-filter=ACMR -z |
    xargs -0 -r git check-attr -z text binary eol -- |
    perl -0 -ne '
        # check-attr -z emits path NUL attr NUL value NUL triples
        chop; push @f, $_; next if @f < 3;
        my ($path, $attr, $val) = @f; @f = ();
        $a{$path}{$attr} = $val;
        END {
            for my $p (sort keys %a) {
                next if $a{$p}{binary} eq "set" || $a{$p}{text} eq "unset";
                printf "%s\t%s\n", $p, ($a{$p}{eol} eq "lf" ? "lf" : "crlf");
            }
        }
    ' > "$list"

fail=0
while IFS="$(printf '\t')" read -r f eol; do
    [ -f "$f" ] || continue
    # what git itself would call binary (NUL in the first 8000 bytes) is skipped
    head -c 8000 "$f" | perl -ne 'exit 1 if /\x00/' || continue
    msg=$(EOL="$eol" perl -ne '
        if ($ENV{EOL} eq "lf") { $bad++ if /\r\n\z/ } else { $bad++ if /(?<!\r)\n\z/ }
        $cc++ if /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/;
        END {
            my @m;
            push @m, ($ENV{EOL} eq "lf" ? "CRLF" : "LF-only") . " line endings ($bad lines, expected $ENV{EOL})" if $bad;
            push @m, "control characters ($cc lines)" if $cc;
            print join("; ", @m);
        }' "$f")
    if [ -n "$msg" ]; then
        echo "check-text: $f: $msg" >&2
        fail=1
    fi
done < "$list"

if [ $fail -ne 0 ]; then
    echo "check-text: fix the files above and stage again" >&2
    exit 1
fi
exit 0
