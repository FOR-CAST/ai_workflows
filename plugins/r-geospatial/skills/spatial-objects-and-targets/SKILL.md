---
name: spatial-objects-and-targets
description: How terra and sf objects must cross process, session and pipeline boundaries -- SpatRaster/SpatVector are external pointers that do not survive serialisation, so use geotargets tar_terra_* or format="file" and pass filenames. Also covers the one-project-CRS rule, GDAL config for extensionless stores, and GPKG over shapefile.
when_to_use: Writing a target that returns a SpatRaster, SpatVector or sf object; passing spatial data to a crew/callr/parallel worker; saving spatial data; seeing "NULL value passed as symbol address" or an empty/invalid spatial object; setting up a project CRS.
paths:
  - "**/_targets.R"
  - "**/R/targets_*.R"
  - "**/*.R"
---

# Spatial objects across boundaries

## The external-pointer trap

`terra` `SpatRaster` and `SpatVector` hold their data behind an **external
pointer**. It does not survive serialisation, and nothing warns you:

> `load_nbac_polys()` returns a terra SpatVector, whose data live behind an
> external pointer that does not survive serialisation. A plain `tar_target`
> stores the dead pointer without complaint, so the failure surfaces only in the
> **consumer** ... errored with `NULL value passed as symbol address` ... four
> minutes into the run and before any container started.

Note where it fails: in the *consumer*, not the producer, and long after the fact.
The same applies to any `parallel`/`future`/`crew` worker and to a saved `.rds`.

**A stale pointer also does not survive a session.** A `tar_read()` of a
file-backed geotarget returns an object pointing at a file: re-read it, never
reuse a pointer carried over from a previous session.

## The fix: files are the currency

Do not reach for `terra::wrap()`/`unwrap()`. Design so it is never needed:

```r
geotargets::tar_terra_rast(dem, make_dem(...))      # SpatRaster -> .tif
geotargets::tar_terra_vect(aoi, make_aoi(...))      # SpatVector -> .gpkg
tar_target(big_layer, write_layer(...), format = "file")   # returns a PATH
```

What crosses the worker boundary is then always a file. The standing rules:

- **Rasters on disk, not in RAM.** Pass filenames across target, stage and phase
  boundaries. Never retain an in-memory `SpatRaster` across a boundary.
- **Heavy or spatial output is never a plain `tar_target()`.** Use
  `tar_terra_rast` / `tar_terra_vect` / `format = "file"`.
- A function backing a `format = "file"` target **returns the path it wrote**.

```r
write_layer <- function(x, path) {
  terra::writeRaster(x, filename = path, overwrite = TRUE, datatype = "INT1U")
  path
}
```

Register the factories with the tarborist extension so it can still discover the
targets, in `.vscode/settings.json`:

```json
{ "tarborist.additionalSingleTargetFactories":
  ["tar_terra_rast", "tar_terra_vect", "tar_terra_sprc", "tar_terra_tiles"] }
```

## A stable path is not a stable value

A `format = "file"` target whose *path* never changes will not invalidate its
consumers when the contents behind it change. If a target returns a directory root
or a `list.files()` scan, add a `*_manifest` companion carrying path/size/mtime
fingerprints and have consumers depend on that. See `targets-staleness` in the
`r-targets` plugin.

## GDAL config for extensionless stores

`geotargets` stores `SpatVector` targets at extensionless object paths, and GDAL's
GPKG driver refuses them by default:

```r
Sys.setenv(OGR_SQLITE_ALLOW_ANY_EXTENSION = "YES")
```

Set it in `.Rprofile` **so crew workers inherit it**, and repeat it in `_targets.R`
for interactive use -- one of the few duplications worth making, with the reason
written down at both sites.

Related: GDAL stamps `gpkg_contents.last_change` on write, so a byte-identical
re-write re-hashes under `format = "file"` and cascades downstream rebuilds. Pin
`OGR_CURRENT_DATE` when writing GPKGs from a pipeline.

## One declared project CRS

Declare the target CRS and resolution **once**, in the project's definition-time
config, and build everything to match:

```r
local$crs <- "EPSG:3978"    ## NAD83 Canada Atlas Lambert
local$res <- 250L
```

The alternative -- every layer following whatever raster it meets -- produces the
footgun of needing a separately pre-transformed study area for one dataset:

```r
tar_target(roads, get_roads(studyArea_LCC, LCC))   ## NOTE: different studyArea CRS needed
```

A single declared project CRS removes that entirely.

Two CRS details that bite:

- **Server-side bbox filters usually want lon/lat.** Project for the query only:
  ```r
  bb <- terra::ext(terra::project(sa, "EPSG:4326"))
  ```
- **A `.prj` may name a projection with no authority code.** Stamping and
  reprojecting are different operations; choose deliberately, verify the parameters
  match, and fail loudly when neither is possible:
  ```r
  if (!is.na(row$crs_override)) {
    terra::crs(v) <- row$crs_override        ## stamp: params verified identical
  }
  if (is.na(terra::crs(v, describe = TRUE)$code) && is.na(row$crs_override)) {
    stop("no resolvable CRS and no override for ", row$layer_key, call. = FALSE)
  }
  ```

## GPKG, not shapefile

A standing rule in these projects. Shapefiles lose long field names, have a 2 GB
limit, and split across sidecar files -- and a fetch that drops the `.shx` fails
in a way that looks like a corrupt download. Single-file `.gpkg` avoids all of it.

Where a columnar format genuinely pays -- millions of features read repeatedly,
column-wise -- use **geoarrow** (0.4.4, released 2026-09-16), not `sfarrow`, whose
last CRAN release was 2021-10-27. And if you reach for a raster data cube:
**gdalcubes was archived from CRAN on 2026-09-16**, so build the time series from
terra and a targets pattern instead of adding an archived dependency.

## Fetch and filter server-side

Push the filter to the server rather than downloading a province and cropping:

```r
polys <- bcdata::bcdc_query_geodata(id) |>
  dplyr::filter(INTERSECTS(studyArea)) |>
  dplyr::select(dplyr::any_of(select_cols)) |>
  dplyr::collect() |>
  sf::st_intersection(studyArea)
suppressWarnings({ sf::st_transform(polys, terra::crs(rasterToMatch)) })
```

Note the narrowed `suppressWarnings()` -- it wraps only the transform, so real
warnings elsewhere in the chain still surface. Never wrap a whole pipeline in it.

The same principle applies to any reprojection: **crop in the source CRS first,
then reproject.** A helper that reprojected a country-wide layer before cropping
took >50 minutes where crop-then-project took ~1.4 seconds.
