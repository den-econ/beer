# API Setup Plan (draft, 2026-10-01)

Status: planning only, nothing has been set up yet. Continue from "Next steps".

General API catalog and key-setup conventions: `C:\Users\imedk\github\dotfiles\docs\economic-data-apis.md`. This file covers only BEER.

## Current state

Existing keys are Windows **User** environment variables (not Machine, not `.Renviron`, not `~/.claude/settings.json`):

- `BPS_API_KEY`: BPS Indonesia (stadata / bpsr)
- `COMTRADE_API_KEY`: UN COMTRADE
- `FRED_API_KEY`: FRED

BEER data currently comes from CEIC through an Excel refresh link (`data_mod_rupiah.xlsx`, `Sheet3`). `IDR_beer_model.R` reads sheet `data_clean`: `xr, infl_diff, tot, nfa, ir_diff, cds` (monthly, 2010-01 onward).

## BEER variables: API replacements

| Var | Current | API replacement | Key? |
|---|---|---|---|
| `xr` | BI / Bloomberg | BIS exchange rates (`WS_XRU`, monthly average and end of period) | No |
| `infl_diff` | BI + BLS | BPS core CPI + FRED `CPILFESL` | Already have both |
| `tot` | CEIC unit values | BPS export/import value and volume (build unit values yourself); alternative: IMF commodity terms-of-trade index | BPS: have. IMF: no key for downloads (unsure about the new API portal) |
| `nfa` | CEIC M2 NFA | IMF monetary statistics / IIP via the IMF data portal or DBnomics. BI SEKI is Excel only | No |
| `ir_diff` | BI + Fed | BIS central bank policy rates (`WS_CBPOL`): Indonesia and US in one call | No |
| `cds` | Bloomberg | No free API. See below | — |

Most of BEER needs **no new keys**: BIS, IMF and DBnomics are open, and BPS and FRED are already set up.

Options for `cds`:

1. **Bloomberg** through `Rblpapi` / `blpapi`. Works only on a machine with a terminal logged in; no key involved.
2. **CEIC API** (`ceic_api_client`). Paid add-on; check whether DEN's subscription includes it. Could replace the whole Excel workflow.
3. **Free proxy:** Indonesia 10-year yield minus US 10-year. Possibly FRED `IRLTLT01IDM156N` (OECD); not sure it's still updated. A yield spread is a different concept from CDS, so it must be flagged in the paper.

## Keys to register (all free)

| Variable name | Source | Use |
|---|---|---|
| `EIA_API_KEY` | eia.gov/opendata | Energy prices (coal, oil, LNG) for the terms of trade |
| `CENSUS_API_KEY` | api.census.gov/data/key_signup | US imports by HS code (Indonesia–US ART) |
| `USITC_API_KEY` | dataweb.usitc.gov | US tariffs and duties collected |
| `WTO_API_KEY` | apiportal.wto.org | MFN and bound tariffs |
| `CEIC_*` / Bloomberg | institutional | Only if DEN has access |

Other useful open APIs that need no key: DBnomics, BIS, ILOSTAT, ECB, Eurostat, FAOSTAT, UNCTADstat (check), Satu Data Indonesia (CKAN).

## How to set keys

Never paste keys into a Claude chat. Set each one yourself in PowerShell:

```powershell
[Environment]::SetEnvironmentVariable('EIA_API_KEY', '<paste-here>', 'User')
```

Then restart Claude Code and the IDE (RStudio or VS Code) so they pick up the new variables.

Conventions:

- **Naming:** `<SOURCE>_API_KEY`.
- **Per repo:** add a `.env.example` and a "Required environment variables" table to the README. Code reads only with `Sys.getenv("X")` / `os.environ["X"]` and fails with a clear error if a key is missing. Never commit real values.
- **Paid credentials (CEIC, Bloomberg):** use the OS credential store through `keyring` (R and Python), not plain User environment variables. User variables are stored as plain text in the registry; that's fine for free keys only.
- **Avoid** putting keys in the `"env"` block of `~/.claude/settings.json`: it's plain text and is easy to sync by accident, for example through the dotfiles repo.

## Reproducible BEER pipeline (proposed)

Replace the CEIC Excel with `R/fetch_data.R`:

1. Pull each series from the APIs above.
2. Save the raw pulls to `data/raw/`, stamped with the download date.
3. Build `data_clean` the same way the current sheet does.

`IDR_beer_model.R` then reads the script's output instead of `data_mod_rupiah.xlsx`. The publication lag for `tot` and `nfa` remains (the carry-forward caveat in the paper), but it becomes explicit in the code.

## Next steps

1. [ ] Find out whether DEN has CEIC API or Bloomberg terminal access. This decides the CDS question and possibly the whole pipeline.
2. [ ] Register EIA, Census, USITC and WTO keys and set them as above.
3. [ ] Claude writes `R/fetch_data.R` for BEER (BIS, IMF/DBnomics, BPS, FRED).
4. [ ] Validate the API series against the current CEIC `data_clean`, then switch `IDR_beer_model.R` over.
