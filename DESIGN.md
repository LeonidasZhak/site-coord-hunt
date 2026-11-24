# Design: prioritising coarse records for geolocation

Status: draft for discussion between spatial modellers and entomologists.

## Problem

Surveillance records are often located only to a parish, village, health
facility or other admin unit. Many of these units are larger than the cell size
of the model, so a record cannot be assigned to a single cell. Re-locating
every record is expensive. We want to rank the coarse records by how much a
precise location would help the model, and then make the re-location itself
quick.

## Assumed model objective

An environmental-niche / species distribution model fitted at the resolution of
a raster mask. For this objective the most valuable new site is one that adds
**novel environmental space** relative to the sites that are already located at
model resolution. A record in a conditions-poor corner of covariate space
constrains the response curves more than one that duplicates conditions we
already have. If the objective changes (e.g. spatial prediction error, range
edge delineation), the value metric changes and this document should be revisited.

## Definitions

- **Reference set**: records geolocated at model resolution (a cell, or a point
  that falls in one). Covariates are extracted at these cells.
- **Coarse record**: a record with only an admin unit (or similar) location. Its
  candidate cells are the mask cells that fall inside that unit's polygon.
- **Novelty of a cell**: how far the covariates of that cell lie outside the
  reference set.

## Value metrics

Two complementary extrapolation metrics, both computed per cell against the
reference set:

1. **MESS** (Elith et al. 2010, Multivariate Environmental Similarity Surface).
   Univariate: for each covariate, how far a value is outside the range of the
   reference set, then the minimum across covariates. Negative = at least one
   covariate is outside the reference range. It cannot see unusual
   *combinations* of covariates that are individually in range.
2. **SHAPE** (Velazco et al. 2023, via `flexsdm::extra_eval()`). Distance-based
   (Mahalanobis by default): the distance from a cell to its nearest reference
   site, as a percentage of the mean distance of reference sites to their own
   centroid. 0 means the cell matches a reference site; it is unbounded, and
   values above 100 are farther from any reference site than the reference
   cloud's typical spread. Because it is distance-based it can flag unusual
   combinations of covariates that are each within range.

We show both and do not merge them into one score by default. The app uses
SHAPE as the primary ranking value and MESS (< 0) as the flag for "outside the
observed range of at least one covariate". We do not use flexsdm's `univar_comb`
layer: in flexsdm 1.4.2 its codes are the reverse of its help text (checked
against MESS on the simulated data), so range status is taken from MESS. Both are reported per cell, and the user can
change which one drives the map and ranking.

## From cells to records

A coarse record spans many cells, and we do not know which one is right. For
every coarse record we score each candidate cell in its polygon, then report:

- `max_novelty`: best-case payoff, i.e. if the true location is the most novel cell
- `mean_novelty`: expected payoff if all cells are equally likely
- `range`: how much the answer depends on where the record really is
  (`max - min`)
- `n_cells`: number of candidate cells
- `n_records`: number of records sharing the unit (geolocating the unit once helps
  all of them if they are from the same site; flagged separately)

Default ranking is by `max_novelty`; records with a large range are the ones
where a good location helps most and a wrong guess hurts most. Where
records carry a **plausible-habitat constraint** (e.g. a land-cover mask) the
candidate cells can be restricted, which narrows the range.

## Sequential selection

Novelty is relative to the reference set, so every site that is geolocated
changes the scores of all other candidates. The app therefore:

- recomputes scores whenever the reference set changes, and
- offers a "next best" ranking in which a candidate unit that is similar in
  covariate space to an already-selected one is down-weighted (greedy
  selection that adds each chosen record's best cell to a *working* reference set
  and rescores).

This avoids sending effort to ten adjacent parishes that are all novel in the
same way.

## App

R Shiny, `leaflet` map at the scale of the entomologist's area of responsibility.

| Layer | Content |
|---|---|
| Grid | The model mask raster drawn as cell outlines/fill, switchable to show SHAPE or MESS |
| Located sites | Reference set points/cells, one colour |
| Coarse records | Admin polygons coloured by chosen value metric, with a ranked table |

Interaction to geolocate a record:

1. Select a coarse record from the table (or click its polygon). Candidate cells
   are highlighted with their novelty.
2. Either **click a cell** (record is assigned at model resolution; the cell centre
   is stored as the point and `method = "cell"`), or **drop a point** and drag it
   to a precise place (`method = "point"`).
3. The user records a source and a confidence level, then saves. The record moves to
   the reference set, scores are recomputed, and the ranking updates.

Corrections are never written over the original data; see the next section.

## Data

All inputs are plain files so the repo runs without a database. The storage layer
(`R/data_io.R`) is the only code that touches files, so it can be swapped for a
database later.

- `mask.tif`: covariate stack (multi-layer GeoTIFF), `NA` = outside the mask. The
  grid is the cell structure of this raster.
- `admin.gpkg`: admin polygons with `admin_id` and `admin_name`.
- `records.csv`: one row per record.

| Column | Meaning |
|---|---|
| `record_id` | unique id |
| `admin_name` | name of the coarse unit, joined to the polygon layer |
| `lon`, `lat` | precise coordinates; blank if not yet located |
| `n_specimens` | optional, count |
| `date` | optional |

- `corrections.csv`: append-only log written by the app. One row per
  geolocation action with `record_id`, `lon`, `lat`, `cell_id`, `method`
  (`cell` or `point`), `source`, `confidence`, `user`, `timestamp`. The current
  state of the data is the original `records.csv` with corrections applied, so
  every edit is auditable and reversible.

A record counts as **located** when it has coordinates that fall inside a mask
cell. Names that do not match any polygon are reported, not silently dropped.

## Simulated data

The first prototype runs on simulated covariates, admin units and records
(`data-raw/simulate_data.R`), so the repo needs no private data. The simulation
deliberately includes a few admin units that cover unusual environmental
conditions, so the ranking has something to find.

## Open questions

1. Is the model mask resolution fixed, or should users change it in the app?
2. Do admin names match a boundary layer cleanly? Facility names usually do not, and
   may need a lookup table with a point and a catchment radius.
3. Should novelty be computed against all covariates in the model, or a chosen subset?
4. Do records from the same unit and date describe one site, or several?
5. What is an acceptable georeferencing precision (cell centre vs. point), and does
   the entomologist's own certainty need to feed the model as uncertainty?
6. If the final model is not niche-based (e.g. a spatial smoother), the value
   metric needs to change (see "Assumed model objective").

## References

- Elith J, Kearney M, Phillips S (2010). The art of modelling range-shifting
  species. *Methods in Ecology and Evolution* 1:330-342.
- Velazco SJE, et al. (2023). SHAPE extrapolation metric. *Ecography*,
  doi:10.1111/ecog.06992 (as cited in the `flexsdm::extra_eval` documentation).
- Velazco SJE, et al. (2022). flexsdm: An R package for supporting a
  comprehensive and flexible species distribution modelling workflow. *Methods in
  Ecology and Evolution*.
