# Vendored from Main_MiSTer

`megacdd.cpp`, `megacd.h` and `cd.h` are byte-identical copies, for the golden trace of `sim/cdd` only. They are not built into the core.

- Repository: https://github.com/MiSTer-devel/Main_MiSTer
- Commit: `7912f7693a2328ef5b53ac83be74d5c99b932a47` (2026-11-02)
- Paths there: `support/megacd/megacdd.cpp`, `support/megacd/megacd.h`, `cd.h`
- Licence: the files carry no notice of their own. The repository's `LICENSE` is the full text of the GNU GPL, version 3.

`sim/cdd/prepare.py` copies them into the directory layout their includes expect.
