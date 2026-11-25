# site-coord-hunt

Identifying high-value sites for geolocation.

Surveillance records located only to a parish, village or facility are often
larger than the model's cell size. This repo holds a Shiny app that ranks those
coarse records by how much environmental novelty they would add to the set of
precisely located sites (MESS and SHAPE), and lets an entomologist geolocate them
by clicking a cell or dragging a point.

The concept is one app with a role tab and two views (see DESIGN.md, "Two views"):

- **Modeller view**: scoring settings, cell and unit scores, and the prioritised
  work list.
- **Entomologist view**: the work list and the geolocation tools, with no value
  information, so that the location they record is not drawn toward cells that are
  useful to the model. It shows the number of records and the month-and-year time
  span for each location to help recall, and lets the entomologist mark several
  cells and spread a fixed vote budget between them when unsure; it can also flag
  an already-located site as possibly wrong.

The current prototype is a single combined app that shows value scores to
everyone and places one cell or point per record. The two-view split, date
display and multi-cell weighting are designed but not built.

Read [DESIGN.md](DESIGN.md) first: it sets out the objective, metrics, data
format and open questions for modellers and entomologists to discuss.

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

Prototype on simulated data. Not yet done: the modeller/entomologist split,
record dates and the time-span display, multi-cell marking with weights, sequential ("next best") selection,
restricting candidate cells by habitat, facility/point-radius records,
multi-user storage. The map's basemap tiles need internet access.
