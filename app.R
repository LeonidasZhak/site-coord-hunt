# Shiny app: prioritise coarse surveillance records for geolocation.
# Run from the repo root:  shiny::runApp()
# Data directory can be overridden:  options(sch.data_dir = "path/to/data")

suppressPackageStartupMessages({
  library(shiny)
  library(leaflet)
  library(terra)
  library(sf)
  library(DT)
})
source("R/scoring.R")
source("R/data_io.R")

DATA_DIR <- getOption("sch.data_dir", "data")
inputs   <- load_inputs(DATA_DIR)
covs     <- inputs$covs
admin    <- inputs$admin
cell_size <- res(covs)

ui <- fluidPage(
  titlePanel("Where should we geolocate next?"),
  sidebarLayout(
    sidebarPanel(
      width = 4,
      radioButtons("metric", "Colour map and units by",
                   c("SHAPE (distance to nearest located site)" = "shape",
                     "MESS (outside observed range)" = "mess"),
                   selected = "shape"),
      checkboxInput("show_grid", "Show model grid", TRUE),
      uiOutput("status"),
      hr(),
      h4("Units with unlocated records"),
      DTOutput("unit_table"),
      hr(),
      h4("Geolocate"),
      uiOutput("record_picker"),
      helpText("Click a cell to assign at model resolution, or press 'Drop point' ",
               "and drag the marker to a precise place."),
      actionButton("drop_point", "Drop point at map centre"),
      selectInput("source", "Source of location",
                  c("field notes", "collector contacted", "GPS", "map / gazetteer", "other")),
      selectInput("confidence", "Confidence", c("high", "medium", "low")),
      textInput("user", "Your name"),
      uiOutput("pending"),
      actionButton("save", "Save location", class = "btn-primary")
    ),
    mainPanel(width = 8, leafletOutput("map", height = 700))
  )
)

server <- function(input, output, session) {
  corrections <- reactiveVal(read_corrections(DATA_DIR))
  pending     <- reactiveVal(NULL)   # list(lon, lat, method)

  recs <- reactive(apply_corrections(inputs$records, corrections(), covs))

  scores <- reactive({
    ref <- recs()[recs()$located, c("lon", "lat")]
    tryCatch(score_cells(covs, ref), error = function(e) e)
  })

  units <- reactive({
    s <- scores()
    req(!inherits(s, "error"))
    u <- summarise_units(admin, s, recs())
    if (nrow(u)) u[order(-u[[if (input$metric == "shape") "max_shape" else "pct_outside"]]), ] else u
  })

  output$status <- renderUI({
    s <- scores(); r <- recs()
    um <- unmatched_names(r, admin)
    tagList(
      p(sprintf("%d located, %d coarse records.", sum(r$located), sum(!r$located))),
      if (inherits(s, "error")) div(class = "text-danger", conditionMessage(s)),
      if (length(um)) div(class = "text-warning",
                          paste("Names with no matching polygon:", toString(um)))
    )
  })

  output$unit_table <- renderDT({
    u <- units()
    req(nrow(u) > 0)
    u[, c("admin_name", "n_records", "n_cells", "max_shape", "mean_shape",
          "range_shape", "pct_outside")] |>
      datatable(selection = "single", rownames = FALSE,
                options = list(pageLength = 8, dom = "tp", scrollX = TRUE)) |>
      formatRound(c("max_shape", "mean_shape", "range_shape", "pct_outside"), 1)
  })

  selected_unit <- reactive({
    i <- input$unit_table_rows_selected
    if (is.null(i)) NULL else units()$admin_name[i]
  })

  output$record_picker <- renderUI({
    u <- selected_unit()
    if (is.null(u)) return(helpText("Select a unit in the table."))
    r <- recs()
    ids <- r$record_id[!r$located & r$admin_name %in% u]
    selectInput("record", sprintf("Record in %s", u), ids)
  })

  # ---- map ------------------------------------------------------------------
  output$map <- renderLeaflet({
    e <- as.vector(ext(covs))   # xmin, xmax, ymin, ymax
    leaflet() |> addProviderTiles("CartoDB.Positron") |>
      fitBounds(e[["xmin"]], e[["ymin"]], e[["xmax"]], e[["ymax"]])
  })

  observe({
    s <- scores(); req(!inherits(s, "error"))
    lyr <- s[[input$metric]]
    v <- values(lyr, mat = FALSE)
    if (input$metric == "shape") {
      # SHAPE is unbounded; colour to the 98th percentile so cells within a unit
      # stay distinguishable instead of saturating.
      # ceiling(): leaflet projects the raster to float32, which can nudge the
      # capped maximum a hair above an unrounded limit and trigger NA colours.
      lo <- 0; hi <- ceiling(unname(quantile(v, 0.98, na.rm = TRUE)))
      ttl <- sprintf("SHAPE (%% ; capped at %.0f)", hi)
      pal <- colorNumeric("YlOrRd", c(lo, hi), na.color = "transparent")
    } else {
      lo <- -100; hi <- 100
      ttl <- "MESS (capped at +/-100)"
      pal <- colorNumeric("RdYlBu", c(lo, hi), na.color = "transparent")
    }
    lyr <- setValues(lyr, pmin(pmax(v, lo), hi))
    leafletProxy("map") |>
      clearGroup("score") |>
      addRasterImage(lyr, colors = pal, opacity = 0.6, group = "score", project = TRUE) |>
      clearControls() |>
      addLegend("bottomright", pal = pal, values = c(lo, hi), title = ttl)
  })

  observe({
    p <- leafletProxy("map") |> clearGroup("grid")
    if (isTRUE(input$show_grid)) {
      g <- st_as_sf(as.polygons(covs[[1]] * 0 + 1, dissolve = FALSE)) # one polygon per non-NA cell
      p |> addPolygons(data = g, group = "grid", fill = FALSE, color = "#555", weight = 0.4)
    }
  })

  observe({
    r <- recs(); u <- units()
    pts <- r[r$located, ]
    p <- leafletProxy("map") |> clearGroup("sites") |> clearGroup("units")
    if (nrow(pts)) {
      p <- p |> addCircleMarkers(data = pts, lng = ~lon, lat = ~lat, radius = 3, group = "sites",
                                 color = "#08519c", fillOpacity = 1, stroke = FALSE,
                                 label = ~record_id)
    }
    if (nrow(u)) {
      a <- merge(admin, u, by = "admin_name")
      p |> addPolygons(data = a, group = "units", fill = FALSE, color = "#d95f02", weight = 2,
                       label = ~sprintf("%s: %d unlocated, max SHAPE %.0f", admin_name, n_records, max_shape),
                       layerId = ~paste0("unit_", admin_name))
    }
  })

  # Zoom to the selected unit.
  observeEvent(selected_unit(), {
    u <- selected_unit(); req(u)
    b <- st_bbox(admin[admin$admin_name == u, ])
    leafletProxy("map") |> fitBounds(b[["xmin"]], b[["ymin"]], b[["xmax"]], b[["ymax"]])
    pending(NULL)
    leafletProxy("map") |> clearGroup("pending")
  })

  # ---- geolocating ------------------------------------------------------------
  snap_to_cell <- function(lon, lat) {
    cell <- cellFromXY(covs[[1]], cbind(lon, lat))
    if (is.na(cell) || is.na(covs[[1]][cell][[1]])) return(NULL)
    xy <- xyFromCell(covs[[1]], cell)
    list(lon = xy[1], lat = xy[2], cell = cell)
  }

  observeEvent(input$map_click, {
    req(input$record)
    c <- input$map_click
    sn <- snap_to_cell(c$lng, c$lat)
    if (is.null(sn)) {
      showNotification("That click is outside the model mask.", type = "warning")
      return()
    }
    pending(list(lon = sn$lon, lat = sn$lat, method = "cell"))
    half <- cell_size / 2
    leafletProxy("map") |> clearGroup("pending") |>
      addRectangles(sn$lon - half[1], sn$lat - half[2], sn$lon + half[1], sn$lat + half[2],
                    group = "pending", color = "#e41a1c", weight = 2, fillOpacity = 0.2)
  })

  observeEvent(input$drop_point, {
    req(input$record)
    ctr <- input$map_center
    pending(list(lon = ctr$lng, lat = ctr$lat, method = "point"))
    leafletProxy("map") |> clearGroup("pending") |>
      addMarkers(lng = ctr$lng, lat = ctr$lat, group = "pending", layerId = "dragpoint",
                 options = markerOptions(draggable = TRUE))
  })

  observeEvent(input$map_marker_dragend, {
    d <- input$map_marker_dragend
    if (identical(d$id, "dragpoint")) pending(list(lon = d$lng, lat = d$lat, method = "point"))
  })

  output$pending <- renderUI({
    p <- pending()
    if (is.null(p)) return(helpText("No location chosen yet."))
    sn <- snap_to_cell(p$lon, p$lat)
    if (is.null(sn)) return(div(class = "text-danger", "Point is outside the model mask."))
    msg <- helpText(sprintf("%s: %.4f, %.4f (cell %d)", p$method, p$lon, p$lat, sn$cell))
    u <- inputs$records$admin_name[match(input$record, inputs$records$record_id)]
    poly <- admin[admin$admin_name %in% u, ]
    inside <- nrow(poly) == 0 ||
      any(lengths(st_intersects(poly, st_sfc(st_point(c(p$lon, p$lat)), crs = st_crs(admin)))) > 0)
    if (inside) msg else tagList(msg, div(class = "text-warning",
      sprintf("This location is outside %s, the unit recorded for %s. Save only if the original name was wrong.",
              u, input$record)))
  })

  observeEvent(input$save, {
    p <- pending(); req(p, input$record)
    sn <- snap_to_cell(p$lon, p$lat)
    if (is.null(sn)) {
      showNotification("Cannot save: location is outside the model mask.", type = "error")
      return()
    }
    if (!nzchar(trimws(input$user))) {
      showNotification("Enter your name so the edit is attributed.", type = "warning")
      return()
    }
    row <- data.frame(record_id = input$record,
                      lon = if (p$method == "cell") sn$lon else p$lon,
                      lat = if (p$method == "cell") sn$lat else p$lat,
                      cell_id = sn$cell, method = p$method,
                      source = input$source, confidence = input$confidence,
                      user = input$user, timestamp = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"))
    append_correction(row, DATA_DIR)
    corrections(read_corrections(DATA_DIR))
    pending(NULL)
    leafletProxy("map") |> clearGroup("pending")
    showNotification(sprintf("Saved %s.", input$record), type = "message")
  })
}

shinyApp(ui, server)
