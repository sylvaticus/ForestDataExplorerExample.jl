# Methodology

This page describes how the France plugin turns the raw inventory into the indicators
returned by [`process_data`](@ref). All estimates are computed by year and department and
then summed to regions and the country; ratios are always recomputed from the summed totals.

## Data

| Source | Content used |
|:-------|:-------------|
| IGN inventory, `PLACETTE.csv` | plots: campaign, identifier, coordinates (Lambert-93), visit (1st or 2nd), department, land cover class |
| IGN inventory, `ARBRE.csv` | trees: species code, status at the 1st and 2nd visit, circumference, height, volume, weight, 5-year radial increment, age at 1.30 m |
| IGN inventory, `espar-cdref13.csv` | species codes → Latin names (TAXREF v13) |
| Corine Land Cover 2006 | forest classes 311 (broadleaved), 312 (coniferous), 313 (mixed) |
| france-geojson | simplified borders of the country, regions and departments |

Inventory plots are kept when their land cover class is forest (closed or open forest,
groves, poplar plantations).

## Forest area

The polygons of the three forest classes are assigned to departments by the centroid of
their largest ring, and their areas are summed. Areas are exact because Corine Land Cover
is distributed in an equal-area projection (ETRS89-LAEA). The resulting forest area
(about 14 Mha) is smaller than the IGN estimate (about 17 Mha), mainly because the land
cover map does not include open forests and transitional woodland; all the totals of the
package are expressed on this land cover basis.

The area of a species (`ha`) is the forest area multiplied by the share of the species in
the basal area of the department, so that species areas add up to the forest area.

## Growing stock

For each plot at its first visit, the volume per hectare of a species is the sum over its
living trees of `V × W` (tree volume × weight, i.e. the number of trees per hectare that
the tree represents). Plot values are averaged over all the forest plots of the
department (plots without the species count as zero) and multiplied by the forest area:

```math
\mathrm{vol}_{d,s} = A_d \cdot \frac{1}{n_d} \sum_{p \in d} \sum_{i \in p,\, s} V_i W_i
```

## Biological growth

The 5-year radial increment `IR5` gives the diameter five years earlier,
``D_5 = D - 2\,IR5``. Assuming ``V \propto D^{\beta}``, the annual relative volume growth
of a tree is

```math
g = \frac{1 - (D_5 / D)^{\beta}}{5}
```

where ``\beta`` is estimated for each species by a log-log regression of volume on
diameter. Since 2014 the increment is measured on a subsample of trees: the other trees
get the mean `g` of their campaign, species and 10-cm diameter class. Biological growth is
then estimated like the growing stock, from ``g\,V W``. The recruitment of trees crossing
the 7.5 cm threshold is not included, so growth is slightly underestimated.

## Harvest and mortality

Plots are revisited five years after their first visit and the status of each tree is
recorded. Trees found cut (codes 6, 7) give the harvest; trees found dead, broken or
windthrown (codes 5, C, M, A, 1, 2, T) give the natural mortality. Their volume at the
first visit, divided by five, is an annual flow attributed to the campaign of the second
visit, and estimated per hectare over all the revisited plots of the department.

Between 2010 and 2014 the second visit followed a lighter protocol (trees were re-assessed
on a fraction of the plots only), so **harvest and mortality are available from 2015**.

- `mortality_pc = 100 × mortality_volumes / vol` (% of the growing stock per year);
- `share_bio_growth_harvested = harvested_volumes / biological_growth`.

## Sampling error and pooling

A department has about 50–150 forest plots per campaign, and a few dozen revisited plots.
Single-year estimates for small areas, minor species and flows are therefore noisy. The
`window` argument of [`process_data`](@ref) pools consecutive campaigns (the official IGN
results use 5-year windows).

## Growth models

[`estimate_growth`](@ref) fits the Chapman-Richards function

```math
y(t) = a \left(1 - e^{-b t}\right)^{c}, \qquad c \ge 1
```

by nonlinear least squares (LsqFit.jl) on the living trees whose age at 1.30 m was
measured (about 10 000 trees per year since 2006). `y` is the tree volume (default), the
diameter or the height. Starting values come from a grid search on `b` and `c` with `a`
solved by linear least squares. When the observed ages do not reach the asymptote (young
plantations, slow-growing species), `a` is poorly identified and the curve should only be
read within the observed ages.

## Report

[`create_report`](@ref) uses the indicators of the selected scope. A variable is flagged as
highly variable when its mean absolute year-on-year change exceeds `cv_threshold` (5 %) of
its mean level; for those variables, the report compares the year with the previous year
and with the mean of the five previous years.
