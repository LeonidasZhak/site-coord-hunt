# Shiny app: prioritise coarse surveillance records for geolocation.
# Run from the repo root:  shiny::runApp()
# Data directory can be overridden:  options(sch.data_dir = "path/to/data")
#
# One app, two views selected by the role tab. The Entomologist view never shows
# the value of a cell to the model, so the location they record is not drawn
# toward high-value cells. The tab is a convenience, not access control.

suppressPackageStartupMessages({
  library(shiny)
  library(leaflet)
  library(terra)
  library(sf)
  library(DT)
})
source("R/dates.R")
source("R/scoring.R")
source("R/data_io.R")

DATA_DIR  <- getOption("sch.data_dir", "data")
inputs    <- load_inputs(DATA_DIR)
covs      <- inputs$covs
admin     <- inputs$admin
cell_size <- res(covs)
grid_sf   <- st_as_sf(as.polygons(covs[[1]] * 0 + 1, dissolve = FALSE))  # one polygon per mask cell
ext_v     <- as.vector(ext(covs))                                          # xmin, xmax, ymin, ymax

# A map on a hidden tab has no size, so when its tab is first shown the map must
# re-measure itself and fit the study area. Done in JS, after the pane is visible.
fit_on_show <- sprintf("function(el, x) {
  var map = this, fitted = el.offsetWidth > 0;
  $(document).on('shown.bs.tab', function() {
    setTimeout(function() {
      map.invalidateSize();
      if (!fitted && el.offsetWidth > 0) { map.fitBounds([[%f, %f], [%f, %f]]); fitted = true; }
    }, 80);
  });
}", ext_v[["ymin"]], ext_v[["xmin"]], ext_v[["ymax"]], ext_v[["xmax"]])

base_map <- function() {
  leaflet() |>
    addProviderTiles("CartoDB.Positron", group = "Map") |>
    addProviderTiles("Esri.WorldImagery", group = "Satellite") |>
    addLayersControl(baseGroups = c("Map", "Satellite")) |>
    fitBounds(ext_v[["xmin"]], ext_v[["ymin"]], ext_v[["xmax"]], ext_v[["ymax"]]) |>
    htmlwidgets::onRender(fit_on_show)
}

SITE_BLUE <- "#08519c"; FLAG_ORANGE <- "#d95f02"; MARK_RED <- "#e41a1c"; NARROW_PURPLE <- "#6a3d9a"

# ---- UI ---------------------------------------------------------------------

ui <- navbarPage(
  "Where should we geolocate next?", id = "role", selected = "ento",

  tabPanel("Entomologist", value = "ento", sidebarLayout(
    sidebarPanel(
      width = 4,
      h4("Locations to work on"),
      uiOutput("status_e"),
      DTOutput("unit_table_e"),
      hr(),
      uiOutput("record_picker_e"),
      radioButtons("mode_e", "How well do you know where it was?",
                   c("I know the cell" = "cell",
                     "I know the exact spot" = "point",
                     "It could be one of several cells" = "cells")),
      uiOutput("mode_help_e"),
      conditionalPanel(
        "input.mode_e == 'cells'",
        radioButtons("wmode_e", "Spread your belief across the cells",
                     c("Evenly" = "even", "Manual percentages" = "manual"), inline = TRUE),
        uiOutput("weight_ui_e")),
      selectInput("source_e", "Source of location",
                  c("field notes", "collector contacted", "GPS", "map / gazetteer", "other")),
      selectInput("confidence_e", "How confident are you overall?", c("high", "medium", "low")),
      textInput("user_e", "Your name"),
      uiOutput("pending_e"),
      actionButton("save_e", "Save location", class = "btn-primary"),
      actionButton("clear_e", "Clear marks"),
      hr(),
      h4("Check a located site"),
      uiOutput("flag_ui_e")
    ),
    mainPanel(width = 8, leafletOutput("map_e", height = 760))
  )),

  tabPanel("Modeller", value = "model", sidebarLayout(
    sidebarPanel(
      width = 4,
      h4("Scoring"),
      checkboxGroupInput("layers", "Covariates used", names(covs), selected = names(covs)),
      radioButtons("metric", "Rank and colour by",
                   c("SHAPE (distance to nearest located site)" = "shape",
                     "MESS (outside observed range)" = "mess")),
      h4("Reference set"),
      checkboxInput("exclude_flagged", "Leave flagged sites out until reviewed", TRUE),
      sliderInput("located_share",
                  "A record with several cells counts as located when one cell holds at least",
                  min = 50, max = 100, value = 80, step = 5, post = "%"),
      checkboxInput("show_grid_m", "Show model grid", TRUE),
      uiOutput("status_m"),
      hr(),
      h4("Locations with unlocated records"),
      DTOutput("unit_table_m")
    ),
    mainPanel(
      width = 8,
      leafletOutput("map_m", height = 520),
      tabsetPanel(
        tabPanel("Flagged sites",
                 br(), DTOutput("flag_table_m"),
                 textInput("user_m", "Your name"),
                 actionButton("dismiss_m", "Dismiss selected flag")),
        tabPanel("Corrections log", br(), DTOutput("corrections_table_m"))
      )
    )
  ))
)

# ---- server -----------------------------------------------------------------

server <- function(input, output, session) {

  # ---- shared state ---------------------------------------------------------
  corrections <- reactiveVal(read_corrections(DATA_DIR))
  flags       <- reactiveVal(read_flags(DATA_DIR))
  flagged_ids <- reactive(current_flags(flags()))
  states      <- reactive(record_states(inputs$records, corrections(), covs,
                                        located_share = input$located_share / 100))

  scores <- reactive({
    lyrs <- input$layers
    if (length(lyrs) < 2) return(simpleError("Choose at least two covariates."))
    ref <- reference_xy(states(), flagged_ids(), isTRUE(input$exclude_flagged))
    tryCatch(score_cells(covs[[lyrs]], ref), error = function(e) e)
  })
  rec_sum <- reactive({ s <- scores(); req(!inherits(s, "error")); record_summary(admin, s, states()) })
  units <- reactive({
    u <- unit_summary(rec_sum(), states()$records)
    if (!nrow(u)) return(u)
    key <- if (input$metric == "shape") u$max_shape else u$pct_outside
    u[order(-key, -u$max_shape, u$admin_name), , drop = FALSE]
  })

  # The entomologist's work list. Its order comes from the modeller's scores, but
  # it carries no scores. If scoring is not possible it falls back to A-Z so
  # fieldwork is never blocked by a modelling problem.
  worklist <- reactive({
    if (!inherits(scores(), "error")) return(units())
    r <- states()$records; r <- r[r$status != "located" & !is.na(r$admin_name), , drop = FALSE]
    if (!nrow(r)) return(data.frame())
    u <- sort(unique(r$admin_name))
    data.frame(admin_name = u,
               n_records  = vapply(u, function(x) sum(r$admin_name == x), 1L),
               n_narrowed = vapply(u, function(x) sum(r$admin_name == x & r$status == "narrowed"), 1L),
               dates      = vapply(u, function(x) date_span_label(r$date[r$admin_name == x]), ""),
               stringsAsFactors = FALSE)
  })

  snap_to_cell <- function(lon, lat) {
    cell <- cellFromXY(covs[[1]], cbind(lon, lat))
    if (is.na(cell) || is.na(covs[[1]][cell][[1]])) return(NULL)
    xy <- xyFromCell(covs[[1]], cell)
    list(lon = xy[1], lat = xy[2], cell = cell)
  }
  cell_df <- function(sn) data.frame(cell_id = sn$cell, lon = sn$lon, lat = sn$lat)
  no_cells <- function() data.frame(cell_id = numeric(), lon = numeric(), lat = numeric())

  # ===========================================================================
  # Entomologist view. Nothing in here shows a score or a cell's value.
  # ===========================================================================
  current_unit  <- reactiveVal(NULL)
  pend_cells    <- reactiveVal(no_cells())
  pend_point    <- reactiveVal(NULL)       # c(lon, lat) in "exact spot" mode
  preload_w     <- reactiveVal(NULL)       # saved percentages, to pre-fill manual weights
  selected_site <- reactiveVal(NULL)       # located site picked for checking

  unit_now <- reactive({
    u <- current_unit()
    w <- worklist()
    if (!is.null(u) && nrow(w) && u %in% w$admin_name) u else NULL
  })

  output$status_e <- renderUI({
    s <- scores(); w <- worklist()
    tagList(
      if (inherits(s, "error"))
        div(class = "text-warning", "Locations are listed A to Z because ranking is not available right now."),
      if (nrow(w) == 0) p("No records are waiting for a location. Thank you."))
  })

  output$unit_table_e <- renderDT({
    w <- worklist(); req(nrow(w) > 0)
    # Keep the chosen location selected when the list re-renders after a save.
    cu <- isolate(current_unit())
    sel <- if (is.null(cu)) NA_integer_ else match(cu, w$admin_name)
    selection <- list(mode = "single")
    if (!is.na(sel)) selection$selected <- sel
    data.frame(Location = w$admin_name, Records = w$n_records,
               Dates = w$dates, Narrowed = w$n_narrowed) |>
      datatable(selection = selection, rownames = FALSE,
                options = list(pageLength = 8, dom = "tp", ordering = FALSE, scrollX = TRUE))
  })
  observeEvent(input$unit_table_e_rows_selected, {
    i <- input$unit_table_e_rows_selected
    w <- worklist()
    if (!is.null(i) && i <= nrow(w)) current_unit(w$admin_name[i])
  })

  output$record_picker_e <- renderUI({
    u <- unit_now()
    if (is.null(u)) return(helpText("Select a location in the list."))
    r <- states()$records; r <- r[r$status != "located" & r$admin_name %in% u, , drop = FALSE]
    lab <- sprintf("%s (%s%s)", r$record_id, unname(vapply(r$date, date_span_label, "")),
                   ifelse(r$status == "narrowed", ", narrowed", ""))
    selectInput("record_e", sprintf("Record at %s", u), setNames(r$record_id, lab),
                selected = isolate(input$record_e))
  })

  # Choosing a record clears any half-made marks and reloads its saved ones.
  observeEvent(input$record_e, {
    pend_point(NULL); preload_w(NULL)
    cc <- states()$cells; cc <- cc[cc$record_id == input$record_e, , drop = FALSE]
    if (nrow(cc)) {
      pend_cells(cc[, c("cell_id", "lon", "lat")])
      pct <- round(cc$weight * 100)
      preload_w(pct)
      updateRadioButtons(session, "mode_e", selected = "cells")
      updateRadioButtons(session, "wmode_e", selected = if (length(unique(pct)) == 1) "even" else "manual")
    } else {
      pend_cells(no_cells())
    }
  })

  # Refit only when the chosen location changes. Keying this on unit_now() would
  # also refit after every save or flag (scores change, so the reactive re-runs),
  # throwing away wherever the user had zoomed to.
  observeEvent(current_unit(), {
    u <- current_unit(); req(u)
    b <- st_bbox(admin[admin$admin_name == u, ])
    leafletProxy("map_e") |> fitBounds(b[["xmin"]], b[["ymin"]], b[["xmax"]], b[["ymax"]])
  })

  output$mode_help_e <- renderUI(helpText(switch(
    input$mode_e,
    cell  = "Click the cell on the map.",
    point = "Click the map to drop a marker, then drag it to the exact spot.",
    cells = "Click each possible cell. Click a marked cell again to remove it.")))

  # ---- weights for several cells ---------------------------------------------
  weights <- reactive({
    n <- nrow(pend_cells())
    if (n == 0) return(numeric(0))
    if (n == 1) return(1)
    if (input$wmode_e == "even") return(rep(1 / n, n))
    vals <- vapply(seq_len(n - 1), function(i) {
      v <- input[[sprintf("w_%d_%d", n, i)]]
      if (is.null(v) || is.na(v)) NA_real_ else round(v)
    }, 0)
    c(vals, 100 - sum(vals)) / 100          # the last cell takes the remainder
  })

  output$weight_ui_e <- renderUI({
    n <- nrow(pend_cells())
    if (n < 2) return(helpText("Click the possible cells on the map."))
    if (input$wmode_e == "even")
      return(helpText(sprintf("Each of the %d cells counts equally (%s%% each).", n, format(round(100 / n, 1)))))
    pw <- isolate(preload_w())
    base <- floor(100 / n)
    defaults <- if (!is.null(pw) && length(pw) == n) pw else c(rep(base, n - 1), 100 - base * (n - 1))
    tagList(
      lapply(seq_len(n - 1), function(i)
        numericInput(sprintf("w_%d_%d", n, i), sprintf("Cell #%d (%%)", i),
                     value = defaults[i], min = 1, max = 99, step = 1)),
      textOutput("weight_last_e"))
  })
  output$weight_last_e <- renderText({
    w <- weights(); n <- length(w)
    req(n >= 2)
    sprintf("Cell #%d takes the remainder: %s%%", n, if (is.na(w[n])) "?" else round(w[n] * 100))
  })

  # ---- one place that decides whether the marks can be saved -----------------
  pending_check <- reactive({
    bad <- function(msg) list(ok = FALSE, msg = msg)
    if (is.null(input$record_e)) return(bad("Select a location and a record."))
    mode <- input$mode_e; pc <- pend_cells()
    if (mode == "cell") {
      if (nrow(pc) != 1) return(bad("Click the cell on the map."))
    } else if (mode == "point") {
      if (is.null(pend_point())) return(bad("Click the map to drop a marker."))
      if (nrow(pc) != 1) return(bad("That spot is outside the model mask."))
    } else {
      if (nrow(pc) < 2) return(bad("Click at least two cells, or choose 'I know the cell'."))
      w <- weights()
      if (input$wmode_e == "manual" && (anyNA(w) || any(w < 0.01 - 1e-9)))
        return(bad("Each cell needs at least 1%. The other cells must leave something for the last one."))
    }
    list(ok = TRUE, msg = "")
  })

  output$pending_e <- renderUI({
    chk <- pending_check(); pc <- pend_cells()
    if (!chk$ok) return(helpText(chk$msg))
    u <- inputs$records$admin_name[match(input$record_e, inputs$records$record_id)]
    poly <- admin[admin$admin_name %in% u, ]
    pts <- if (input$mode_e == "point" && !is.null(pend_point())) matrix(pend_point(), 1) else as.matrix(pc[, c("lon", "lat")])
    inside <- nrow(poly) == 0 || all(vapply(seq_len(nrow(pts)), function(i)
      length(st_intersects(poly, st_sfc(st_point(pts[i, ]), crs = st_crs(admin)))[[1]]) > 0, TRUE))
    tagList(
      helpText(sprintf("Ready to save %d cell%s.", nrow(pc), if (nrow(pc) == 1) "" else "s")),
      if (!inside) div(class = "text-warning",
                       sprintf("Part of this is outside %s, the location recorded for %s. Save only if that name was wrong.",
                               u, input$record_e)))
  })

  # ---- map ------------------------------------------------------------------
  # Shiny does not render outputs on a hidden tab, and drawing commands sent to a
  # map that does not exist yet are lost, so both maps are built at start.
  output$map_e <- renderLeaflet(base_map())
  outputOptions(output, "map_e", suspendWhenHidden = FALSE)

  observe({   # grid: orientation only
    leafletProxy("map_e") |> clearGroup("grid") |>
      addPolygons(data = grid_sf, group = "grid", fill = FALSE, color = "#555", weight = 0.4,
                  options = pathOptions(interactive = FALSE))
  })

  observe({   # location outlines, the selected one emphasised
    u <- unit_now()
    p <- leafletProxy("map_e") |> clearGroup("units") |>
      addPolygons(data = admin, group = "units", fill = FALSE, color = "#888", weight = 1,
                  label = ~admin_name, options = pathOptions(interactive = FALSE))
    if (!is.null(u))
      p |> addPolygons(data = admin[admin$admin_name == u, ], group = "units", fill = FALSE,
                       color = FLAG_ORANGE, weight = 3, options = pathOptions(interactive = FALSE))
  })

  observe({   # sites that are already located
    r <- states()$records; r <- r[r$status == "located", , drop = FALSE]
    fl <- flagged_ids()
    p <- leafletProxy("map_e") |> clearGroup("sites")
    if (nrow(r))
      p |> addCircleMarkers(data = r, lng = ~lon, lat = ~lat, radius = 4, group = "sites",
                            layerId = ~record_id, stroke = TRUE, weight = 2, fillOpacity = 1,
                            color = ifelse(r$record_id %in% fl, FLAG_ORANGE, SITE_BLUE),
                            fillColor = ifelse(r$record_id %in% fl, FLAG_ORANGE, SITE_BLUE),
                            label = ~sprintf("%s (%s)", record_id, admin_name),
                            options = pathOptions(bubblingMouseEvents = FALSE))
  })

  observe({   # marks already saved for the chosen record
    cc <- states()$cells; id <- input$record_e
    p <- leafletProxy("map_e") |> clearGroup("saved")
    cc <- if (is.null(id)) cc[0, ] else cc[cc$record_id == id, , drop = FALSE]
    if (nrow(cc)) {
      half <- cell_size / 2
      p |> addRectangles(cc$lon - half[1], cc$lat - half[2], cc$lon + half[1], cc$lat + half[2],
                         group = "saved", color = NARROW_PURPLE, weight = 2, dashArray = "4", fillOpacity = 0.1,
                         options = pathOptions(interactive = FALSE))
    }
  })

  observe({   # marks being made now
    pc <- pend_cells(); pp <- pend_point(); w <- weights()
    p <- leafletProxy("map_e") |> clearGroup("pending")
    if (nrow(pc)) {
      half <- cell_size / 2
      lab <- if (nrow(pc) > 1) sprintf("#%d: %s", seq_len(nrow(pc)), ifelse(is.na(w), "?", paste0(round(w * 100), "%"))) else ""
      p <- p |> addRectangles(pc$lon - half[1], pc$lat - half[2], pc$lon + half[1], pc$lat + half[2],
                              group = "pending", color = MARK_RED, weight = 2, fillOpacity = 0.25,
                              label = lab,
                              labelOptions = labelOptions(noHide = nrow(pc) > 1, direction = "center", textOnly = TRUE),
                              options = pathOptions(interactive = FALSE))
    }
    if (!is.null(pp))
      p |> addMarkers(lng = pp[1], lat = pp[2], group = "pending", layerId = "dragpoint",
                      options = markerOptions(draggable = TRUE))
  })

  observeEvent(input$map_e_click, {
    req(input$record_e)
    cl <- input$map_e_click
    sn <- snap_to_cell(cl$lng, cl$lat)
    if (is.null(sn) && input$mode_e != "point") {
      showNotification("That click is outside the model mask.", type = "warning")
      return()
    }
    switch(input$mode_e,
      cell  = { pend_cells(cell_df(sn)); pend_point(NULL) },
      point = { pend_point(c(cl$lng, cl$lat)); pend_cells(if (is.null(sn)) no_cells() else cell_df(sn)) },
      cells = {
        pc <- pend_cells(); pend_point(NULL)
        hit <- which(pc$cell_id == sn$cell)
        pend_cells(if (length(hit)) pc[-hit, , drop = FALSE] else rbind(pc, cell_df(sn)))
      })
  })

  observeEvent(input$map_e_marker_dragend, {
    d <- input$map_e_marker_dragend
    if (!identical(d$id, "dragpoint")) return()
    sn <- snap_to_cell(d$lng, d$lat)
    pend_point(c(d$lng, d$lat))
    pend_cells(if (is.null(sn)) no_cells() else cell_df(sn))
  })

  observeEvent(input$clear_e, { pend_cells(no_cells()); pend_point(NULL) })

  # ---- saving ---------------------------------------------------------------
  observeEvent(input$save_e, {
    chk <- pending_check()
    if (!chk$ok) { showNotification(chk$msg, type = "warning"); return() }
    if (!nzchar(trimws(input$user_e))) {
      showNotification("Enter your name so the edit is attributed.", type = "warning")
      return()
    }
    mode <- input$mode_e; pc <- pend_cells()
    lon <- pc$lon; lat <- pc$lat
    if (mode == "point") { lon <- pend_point()[1]; lat <- pend_point()[2] }
    rows <- data.frame(
      action_id = new_action_id(), record_id = input$record_e, cell_id = pc$cell_id,
      lon = lon, lat = lat,
      weight = if (mode == "cells") weights() else 1,
      weight_mode = if (mode == "cells") input$wmode_e else "even",
      method = switch(mode, cell = "cell", point = "point", cells = "cells"),
      source = input$source_e, confidence = input$confidence_e, user = input$user_e,
      timestamp = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"))
    append_correction(rows, DATA_DIR)
    corrections(read_corrections(DATA_DIR))
    pend_cells(no_cells()); pend_point(NULL)
    showNotification(sprintf("Saved %s.", input$record_e), type = "message")
  })

  # ---- checking located sites -------------------------------------------------
  observeEvent(input$map_e_marker_click, {
    id <- input$map_e_marker_click$id
    if (!is.null(id) && id %in% inputs$records$record_id) selected_site(id)
  })

  output$flag_ui_e <- renderUI({
    id <- selected_site()
    if (is.null(id)) return(helpText("Click a located site (blue) on the map to check it. Orange sites have been flagged."))
    r <- states()$records[states()$records$record_id == id, ]
    head <- p(strong(id), sprintf("at %s, %s", r$admin_name, date_span_label(r$date)))
    if (id %in% flagged_ids())
      return(tagList(head, div(class = "text-warning", "Flagged as possibly wrong.")))
    tagList(head,
            textInput("flag_note", "Why does it look wrong? (optional)"),
            actionButton("flag_e", "Flag as possibly wrong"))
  })

  observeEvent(input$flag_e, {
    id <- selected_site(); req(id)
    if (!nzchar(trimws(input$user_e))) {
      showNotification("Enter your name (above) so the flag is attributed.", type = "warning")
      return()
    }
    append_flag(data.frame(action = "flag", record_id = id, user = input$user_e,
                           timestamp = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
                           note = input$flag_note %||% ""), DATA_DIR)
    flags(read_flags(DATA_DIR))
    showNotification(sprintf("Flagged %s. The modeller will review it.", id), type = "message")
  })

  # ===========================================================================
  # Modeller view: scores, ranking, reference set, flags.
  # ===========================================================================
  output$status_m <- renderUI({
    s <- scores(); r <- states()$records; um <- unmatched_names(r, admin)
    ref <- reference_xy(states(), flagged_ids(), isTRUE(input$exclude_flagged))
    tagList(
      p(sprintf("%d located, %d narrowed, %d coarse. %d in the reference set; %d flagged.",
                sum(r$status == "located"), sum(r$status == "narrowed"), sum(r$status == "coarse"),
                nrow(ref), length(flagged_ids()))),
      if (inherits(s, "error")) div(class = "text-danger", conditionMessage(s)),
      if (length(um)) div(class = "text-warning", paste("Names with no matching polygon:", toString(um))))
  })

  output$unit_table_m <- renderDT({
    u <- units(); req(nrow(u) > 0)
    u[, c("admin_name", "n_records", "n_narrowed", "dates", "max_shape", "mean_shape",
          "range_shape", "pct_outside")] |>
      datatable(selection = "single", rownames = FALSE,
                colnames = c("Location", "Records", "Narrowed", "Dates", "Max SHAPE", "Mean SHAPE",
                             "SHAPE range", "% outside range"),
                options = list(pageLength = 8, dom = "tp", scrollX = TRUE)) |>
      formatRound(c("max_shape", "mean_shape", "range_shape", "pct_outside"), 1)
  })
  current_unit_m <- reactiveVal(NULL)
  observeEvent(input$unit_table_m_rows_selected, {
    i <- input$unit_table_m_rows_selected; u <- units()
    if (!is.null(i) && i <= nrow(u)) current_unit_m(u$admin_name[i])
  })

  output$map_m <- renderLeaflet(base_map())
  outputOptions(output, "map_m", suspendWhenHidden = FALSE)

  observe({
    s <- scores(); req(!inherits(s, "error"))
    lyr <- s[[input$metric]]
    v <- values(lyr, mat = FALSE)
    if (input$metric == "shape") {
      # SHAPE is unbounded; colour to the 98th percentile so cells within a unit
      # stay distinguishable. ceiling(): leaflet projects the raster to float32,
      # which can nudge the capped maximum above an unrounded limit.
      lo <- 0; hi <- ceiling(unname(quantile(v, 0.98, na.rm = TRUE)))
      ttl <- sprintf("SHAPE (%% ; capped at %.0f)", hi)
      pal <- colorNumeric("YlOrRd", c(lo, hi), na.color = "transparent")
    } else {
      lo <- -100; hi <- 100
      ttl <- "MESS (capped at +/-100)"
      pal <- colorNumeric("RdYlBu", c(lo, hi), na.color = "transparent")
    }
    lyr <- setValues(lyr, pmin(pmax(v, lo), hi))
    leafletProxy("map_m") |>
      clearGroup("score") |> removeControl("legend") |>
      addRasterImage(lyr, colors = pal, opacity = 0.6, group = "score", project = TRUE) |>
      addLegend("bottomright", pal = pal, values = c(lo, hi), title = ttl, layerId = "legend")
  })

  observe({
    p <- leafletProxy("map_m") |> clearGroup("grid")
    if (isTRUE(input$show_grid_m))
      p |> addPolygons(data = grid_sf, group = "grid", fill = FALSE, color = "#555", weight = 0.4,
                       options = pathOptions(interactive = FALSE))
  })

  observe({
    st <- states(); u <- units(); fl <- flagged_ids()
    loc <- st$records[st$records$status == "located", , drop = FALSE]
    p <- leafletProxy("map_m") |> clearGroup("sites") |> clearGroup("units")
    if (nrow(loc))
      p <- p |> addCircleMarkers(data = loc, lng = ~lon, lat = ~lat, radius = 3, group = "sites",
                                 stroke = FALSE, fillOpacity = 1,
                                 fillColor = ifelse(loc$record_id %in% fl, FLAG_ORANGE, SITE_BLUE),
                                 label = ~sprintf("%s%s", record_id, ifelse(record_id %in% fl, " (flagged)", "")))
    if (nrow(st$cells))
      p <- p |> addCircleMarkers(data = st$cells, lng = ~lon, lat = ~lat, radius = 3, group = "sites",
                                 stroke = FALSE, fillOpacity = 0.9, fillColor = NARROW_PURPLE,
                                 label = ~sprintf("%s: marked cell, weight %.0f%%", record_id, weight * 100))
    if (nrow(u)) {
      a <- merge(admin, u, by = "admin_name")
      p |> addPolygons(data = a, group = "units", fill = FALSE, color = FLAG_ORANGE, weight = 2,
                       label = ~sprintf("%s: %d unlocated, max SHAPE %.0f", admin_name, n_records, max_shape))
    }
  })

  observeEvent(current_unit_m(), {
    u <- current_unit_m(); req(u)
    b <- st_bbox(admin[admin$admin_name == u, ])
    leafletProxy("map_m") |> fitBounds(b[["xmin"]], b[["ymin"]], b[["xmax"]], b[["ymax"]])
  })

  flag_rows <- reactive({
    f <- flags(); ids <- flagged_ids()
    f <- f[f$action == "flag" & f$record_id %in% ids, , drop = FALSE]
    f <- f[!duplicated(f$record_id, fromLast = TRUE), , drop = FALSE]
    f$location <- inputs$records$admin_name[match(f$record_id, inputs$records$record_id)]
    f
  })
  output$flag_table_m <- renderDT({
    f <- flag_rows()
    datatable(f[, c("record_id", "location", "user", "timestamp", "note")],
              selection = "single", rownames = FALSE,
              colnames = c("Record", "Location", "Flagged by", "When", "Note"),
              options = list(pageLength = 5, dom = "tp", scrollX = TRUE),
              caption = if (nrow(f) == 0) "No flagged sites." else NULL)
  })
  observeEvent(input$dismiss_m, {
    i <- input$flag_table_m_rows_selected
    if (is.null(i)) { showNotification("Select a flag first.", type = "warning"); return() }
    if (!nzchar(trimws(input$user_m))) { showNotification("Enter your name.", type = "warning"); return() }
    id <- flag_rows()$record_id[i]
    append_flag(data.frame(action = "dismiss", record_id = id, user = input$user_m,
                           timestamp = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"), note = ""), DATA_DIR)
    flags(read_flags(DATA_DIR))
    showNotification(sprintf("Dismissed the flag on %s.", id), type = "message")
  })

  output$corrections_table_m <- renderDT({
    d <- corrections(); d <- d[rev(seq_len(nrow(d))), , drop = FALSE]
    datatable(d, rownames = FALSE, options = list(pageLength = 8, dom = "tp", scrollX = TRUE))
  })
}

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a

shinyApp(ui, server)
