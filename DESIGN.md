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
- **Location ID**: the identifier of the coarse place that records are attributed
  to (parish, village, facility). In the prototype this is `admin_name`.
- **Narrowed record**: a coarse record for which the entomologist has marked one
  or more candidate cells, possibly with weights, without pinning it to one cell.
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
against MESS on the simulated data), so range status is taken from MESS. Both are
reported per cell, and the modeller can change which one drives the ranking.

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

## Two views

The same data serves two people with different jobs, so the app has two views,
selected by a **role tab** (Modeller / Entomologist) in a single Shiny app. They
share the scoring and storage code but show different things.

The tab is a convenience, not access control: anyone can switch to the Modeller tab.
That is adequate against unconscious drift toward high-value cells, which is the
concern. If hiding value ever had to be enforced, the entomologist view would need
a separate deployment.

| | Modeller view | Entomologist view |
|---|---|---|
| Question | Which records would add the most to the model? | Where did this sample really come from? |
| Controls | Covariate subset, MESS vs SHAPE, reference set rules, how many locations to prioritise | None of the scoring settings |
| Sees | Cell and unit scores, environmental-space diagnostics, ranked table, how the ranking shifts as sites are added, the corrections log with source and confidence | A work list for their area of responsibility, location polygons, the model grid, located sites, and the recall aids below |
| Produces | A prioritised work list of locations | Corrections: one or more cells, with weights, source and confidence |

### Entomologist view: no value information

Entomologists never see the value of a cell to the model: no novelty colours, no
SHAPE or MESS numbers, no cell-level ranking. If they could see it, they would be
drawn, even unconsciously, toward high-value cells, and the location recorded
would reflect what is useful to the model and not where the sample came from. That
would bias the very data the model is fitted to. Their only guide to a location is
what helps them remember it.

The work list is ordered at the level of the location only (that is the purpose of
the prioritisation) and carries no scores. For each location ID it shows what
helps recall:

- the **number of records** attributed to it
- the **time span** of those records as month and year, e.g. "Mar 2018 to Nov
  2021" ("undated" where there is no date, and year only where only a year is known)

The polygon and the model grid are shown for orientation, and so are the sites
that are already located. Showing located sites helps recall, and the hope is that
entomologists notice ones that look wrong. For that to be useful there is a **flag
as possibly wrong** action on a located site (a note is optional). Flags go to the
modeller view, which can exclude flagged sites from the reference set until they are
reviewed, because a misplaced reference site distorts the novelty scores of every
other candidate. A neutral base map (satellite or terrain) is a recall aid and is fine.

### Marking a location

For a record in the list, the entomologist can:

1. **Click one cell**: the record is located at model resolution (`method = "cell"`).
2. **Drop and drag a point**: a precise location (`method = "point"`), from which the
   cell is derived.
3. **Mark several cells** when unsure, and spread a fixed budget of **votes**
   between them (proposed, total to be confirmed). Clicking one cell puts all the
   votes on it, which is the single-cell case; the entomologist then moves votes to
   other marked cells. Every vote must be spent, so a cell's weight is its votes
   divided by the total. Not-spent votes would carry no information after
   normalising, and overall doubt is expressed by the separate confidence field.
   The total is one constant (`VOTES_TOTAL`). 9 splits evenly only three ways
   or nine ways, so two equally likely cells have to read 5 and 4; 12 splits evenly
   in 2, 3, 4 and 6. The vote total caps the number of marked cells, so a wider
   "somewhere in this area" mark needs a separate gesture that is not designed yet.

Each save records a source and a confidence level. A new save for the same record
replaces the earlier one in full; the earlier rows stay in the log.

### What a multi-cell record means for scoring

- **The candidate cells become the marked cells.** A narrowed record is scored over
  only its marked cells, and `mean_novelty` becomes a weighted mean using the
  entomologist's weights. `max_novelty` and `range` are taken over marked cells.
  So marking cells shrinks the polygon-wide uncertainty rather than ignoring it.
- **Narrowed is not located.** A record with several cells is not added to the
  reference set by default, because we do not know which cell's environment it
  represents. The modeller sets the rule for when a narrowed record counts as
  located (for example, one cell holds at least a chosen share of the weight), and
  narrowed records below the rule stay on the work list with their reduced candidate set.
- **The model sees the uncertainty too.** Fitting the model with a record that
  has several weighted cells is a modelling choice (weighted presences, or
  averaging over cells) and is outside this repo, but the corrections file
  provides the cells and weights it needs.

The entomologist sees none of this scoring. They see only that a record is
located, narrowed or still coarse.

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
| `date` | recommended: shown in the entomologist view as month and year; partial dates (year only, or year and month) are accepted |

- `corrections.csv`: append-only log written by the app. One row per marked
  cell, grouped by `action_id` (one save = one action). Columns: `action_id`,
  `record_id`, `cell_id`, `lon`, `lat`, `votes`, `weight` (votes divided by
  `VOTES_TOTAL`), `method` (`cell`, `point` or `cells`), `source`, `confidence`,
  `user`, `timestamp`. A single cell or point has `weight = 1`. The current state of a record is its latest action; the original
  `records.csv` is never modified, so every edit is auditable and reversible.
  **Planned:** the prototype currently writes one row per record with no
  `action_id` or `weight` and cannot yet mark several cells.

- `flags.csv`: append-only log of located sites flagged as possibly wrong:
  `record_id`, `user`, `timestamp`, `note`. Flags never change a record's location;
  the modeller decides what to do with them.

A record counts as **located** when it has one location (a cell or a point) that
falls inside a mask cell. A record with several marked cells is **narrowed** (see
"What a multi-cell record means for scoring"). Names that do not match any polygon
are reported, not silently dropped.

## Simulated data

The first prototype runs on simulated covariates, admin units and records
(`data-raw/simulate_data.R`), so the repo needs no private data. The simulation
deliberately includes a few admin units that cover unusual environmental
conditions, so the ranking has something to find. It does not yet include record
dates, which the entomologist view needs.

## Open questions

1. Is the model mask resolution fixed, or should users change it in the app?
2. Do admin names match a boundary layer cleanly? Facility names usually do not, and
   may need a lookup table with a point and a catchment radius.
3. Should novelty be computed against all covariates in the model, or a chosen subset?
4. Do records from the same unit and date describe one site, or several?
5. What is an acceptable georeferencing precision (cell centre vs. point), and does
   the entomologist's own certainty need to feed the model as uncertainty?
6. How does the work list reach the entomologist: a file the modeller publishes,
   or a live queue that re-ranks itself as sites are located?
7. What should `VOTES_TOTAL` be (9 or 12), and is a wider-area mark needed?
8. What rule should count a narrowed record as located (share of weight on one cell,
   number of marked cells)?
9. If the final model is not niche-based (e.g. a spatial smoother), the value
   metric needs to change (see "Assumed model objective").

## References

- Elith J, Kearney M, Phillips S (2010). The art of modelling range-shifting
  species. *Methods in Ecology and Evolution* 1:330-342.
- Velazco SJE, et al. (2023). SHAPE extrapolation metric. *Ecography*,
  doi:10.1111/ecog.06992 (as cited in the `flexsdm::extra_eval` documentation).
- Velazco SJE, et al. (2022). flexsdm: An R package for supporting a
  comprehensive and flexible species distribution modelling workflow. *Methods in
  Ecology and Evolution*.
