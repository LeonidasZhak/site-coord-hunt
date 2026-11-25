# site-coord-hunt

Identifying high-value sites for geolocation.

Surveillance records located only to a parish, village or facility are often
larger than the model's cell size. Re-locating all of them is expensive. This repo
holds a Shiny app that ranks those coarse records by how much novel environmental
space a precise location would add to the set of sites already located (MESS and
SHAPE), and lets an entomologist record the location quickly.

## Concept

One app with a role tab and two views:

- **Modeller**: scoring settings, cell and unit scores, and the prioritised work
  list. The modeller also decides which flagged sites to keep in the reference set.
- **Entomologist**: the work list and the location tools. They see **no value
  information**, so the location they record is not drawn toward cells that are
  useful to the model. For each location they see the number of records and the
  month-and-year time span, to help recall. They also see the sites already located,
  and can flag one as possibly wrong.

A location can be one cell, a dragged point, or several cells with an even split or
manual percentage weights when the entomologist is unsure.

The tab is a convenience, not access control.

## Documents

- [DECISIONS.md](DECISIONS.md): what has been decided and why. Start here.
- [DESIGN.md](DESIGN.md): the detail: metrics, scoring of multi-cell records, data formats and open questions.

## Run the prototype

Needs R with `shiny`, `leaflet`, `terra`, `sf`, `DT` and `flexsdm`. The app opens on the
Entomologist tab; switch to Modeller with the tab at the top.

```r
source("data-raw/simulate_data.R")  # once; writes simulated data/ files
shiny::runApp()
```

To use real data, put `covariates.tif`, `admin.gpkg` and `records.csv` in a
folder (formats in DESIGN.md) and run
`options(sch.data_dir = "path/to/folder"); shiny::runApp()`.
Geolocations are appended to `corrections.csv` and flags to `flags.csv` in that folder;
the original `records.csv` is never modified. Dates in `records.csv` may be a full date,
a month (`2019-04`), a year (`2019`) or blank.

## Tests

```bash
Rscript tests/test_dates.R
Rscript tests/test_scoring.R
Rscript tests/test_data_io.R
```

## Status

The prototype runs on simulated data.

| Built | Designed, not built |
|---|---|
| Role tab with Modeller and Entomologist views | Limiting each entomologist's list to their own area |
| MESS and SHAPE scoring against located sites, with a choice of covariates | Sequential "next best" selection |
| Work list by location with record count and month-and-year span | Re-locating a flagged site |
| Click a cell, drag a point, or mark several cells (even split or manual percentages) | Habitat restriction of candidate cells |
| Scoring of narrowed records over their marked cells | Facility or point-and-radius records |
| Located sites shown to entomologists, flagging, modeller review | Multi-user storage |
| Append-only corrections and flags logs; recompute after each save | |
| Simulated data (with dates) and tests | |

The map's basemap tiles need internet access.
