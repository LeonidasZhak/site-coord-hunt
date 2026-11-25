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

Needs R with `shiny`, `leaflet`, `terra`, `sf`, `DT` and `flexsdm`.

```r
source("data-raw/simulate_data.R")  # once; writes simulated data/ files
shiny::runApp()
```

To use real data, put `covariates.tif`, `admin.gpkg` and `records.csv` in a
folder (formats in DESIGN.md) and run
`options(sch.data_dir = "path/to/folder"); shiny::runApp()`.
Geolocations are appended to `corrections.csv` in that folder; the original
`records.csv` is never modified.

## Tests

```bash
Rscript tests/test_scoring.R
Rscript tests/test_data_io.R
```

## Status

The prototype runs on simulated data. It is currently a single combined view that
shows value scores to everyone and places one cell or point per record.

| Built | Designed, not built |
|---|---|
| MESS and SHAPE scoring against located sites | Role tab and the entomologist view |
| Per-unit ranking (max, mean, range) | Record dates and the time-span display |
| Click-a-cell and drag-a-point location | Multi-cell marking with weights |
| Append-only corrections log | Flagging located sites |
| Recompute after each save | Sequential "next best" selection |
| Simulated data and tests | Habitat restriction, facility or point-and-radius records, multi-user storage |

The map's basemap tiles need internet access.
