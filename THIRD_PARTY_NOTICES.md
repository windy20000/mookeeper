# Third-Party Notices

Provenance of code bundled in this repository, and its license boundaries. This file documents
**obligations and risks**, not thanks — material we only consulted for facts, ideas, or ABI
numbers (which carry no copyright) is not attributed; what we actually distribute is described honestly.

## Apple SMC access — `Sources/SMC.c` / `Sources/SMC.h`

`SMC.c`/`SMC.h` (~122 lines, read access to the Apple SMC over the public IOKit `AppleSMC`
user-client: temperatures, fan RPM, power draw) are an **independent implementation of a public
kernel ABI**. They are **not** derived from the 2006 "AppleSMC Tool" by *devnull*, which is
**GPL-2.0+** and is the header you will find copied across most public smc.c/smc.h projects
(osx-cpu-temp, fan-control's smc-command, and many mirrors). That matters: GPL is copyleft —
pasting even a few lines of that family's expression into this MIT-licensed repo would infect
the whole distribution. **Before copying any SMC snippet from the internet into `SMC.c`, stop here.**

What our file shares with that family is the kernel ABI *facts* only, and facts are not
copyrightable expression:

- 80-byte message struct layout, payload at offset 48 (enforced by our `_Static_assert`s);
- `IOConnectCallStructMethod` selector `2`; sub-commands `5`/`8`/`9` (read key / key-by-index / key info);
- key strings (`TC0P`, `PDTR`, `F0Ac`, …) and SMC data-type encodings (`flt `, `fpe2`, `sp78`/`sp87`,
  `ui8`/`ui16`/`ui32`) — the numeric formats are public spec (e.g.
  https://stackoverflow.com/questions/22160746/fpe2-and-sp78-data-types).

Expression-level divergence is deliberate: our key is assembled via a `fourcc()` shift helper and
indexed numerically (`input.key`, `input.command`), unlike the devnull family's
`SPCStructVersion` / nested key unions — no header text, helper, or identifier from that (or any
GPL) source is in our file.

Shape-consulted references (MIT, **no code taken** — listed as provenance context, not an
attribution duty): Apple's APSL-licensed `PowerManagement` `PrivateLib.c`/`SMCUserClient.h`
(ABI origin), `beltex/SMCKit` (reader flow and type decoding), `GabrielZZZ/WattLite`
(power-key cross-check).

If you modify `SMC.c`/`SMC.h`, keep the pointer comment in `SMC.h` and this file accurate.
