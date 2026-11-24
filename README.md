# site-coord-hunt

Identifying high-value sites for geolocation.

Surveillance records located only to a parish, village or facility are often
larger than the model's cell size. This repo holds a Shiny app that ranks those
coarse records by how much environmental novelty they would add to the set of
precisely located sites (MESS and SHAPE), and lets an entomologist geolocate them
by clicking a cell or dragging a point.

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

Prototype on simulated data. Not yet done: sequential ("next best") selection,
restricting candidate cells by habitat, facility/point-radius records,
multi-user storage. The map's basemap tiles need internet access.
