# Country-agnostic public API.

"Version of the processed-data cache format; bump it when the processing changes."
const CACHE_VERSION = 1

"Column types to enforce when reading cached tables back from CSV."
const CACHE_TYPES = Dict(:region_code => String, :region => String, :department_code => String,
    :department => String, :specie => String, :level => String, :country => String)

"""
$(TYPEDSIGNATURES)

Return the table stored at `path`, computing it with `f()` and caching it first when the
file does not exist or `force` is true.
"""
function cached_table(f, path::AbstractString; force::Bool=false)
    if isfile(path) && !force
        return CSV.read(path, DataFrame; types=(i, name) -> get(CACHE_TYPES, name, nothing), validate=false)
    end
    df = f()
    CSV.write(path, df)
    return df
end

"""
$(TYPEDSIGNATURES)

Download and cache the raw data needed to analyse the forests of `country`:
the national forest inventory, the administrative borders (national, regional and
departmental) and the land cover (forest categories).

Files already in the cache are not downloaded again unless `force=true`.
Returns the cache folder (see [`data_dir`](@ref)).

# Example
```julia
download_data(country="France")
```
"""
function download_data(; country::AbstractString, force::Bool=false)
    plugin = get_country(country)
    dir = data_dir(plugin)
    download!(plugin, dir; force)
    return dir
end

"""
$(TYPEDSIGNATURES)

Process the data of `country` previously fetched with [`download_data`](@ref) (they are
downloaded automatically if missing) and return a table of forest indicators by year,
administrative unit and species.

The table has one row per `year`, `level` (`"country"`, `"region"` or `"department"`),
administrative unit and `specie` (Latin name), with the columns:

| Column | Unit | Description |
|:-------|:-----|:------------|
| `vol` | m³ | standing volume of living trees |
| `ha` | ha | forest area attributed to the species (basal-area share of the forest area) |
| `vol_ha` | m³/ha | `vol / ha` |
| `harvested_volumes` | m³/year | volume of the trees harvested |
| `mortality_volumes` | m³/year | volume of the trees dead of natural causes |
| `mortality_pc` | %/year | `100 * mortality_volumes / vol` |
| `biological_growth` | m³/year | gross biological volume increment of living trees |
| `share_bio_growth_harvested` | – | `harvested_volumes / biological_growth` |
| `n_plots` | – | number of inventory plots where the species was found alive |

Flows that cannot be estimated for a year (e.g. before the first re-measurements) are
`missing`. Ratio columns are recomputed from totals at every aggregation level, so to
obtain all-species values sum the total columns and recompute the ratios
(see `ForestDataExplorer.summarise`).

`window` pools the inventory campaigns `year-window+1:year` to reduce sampling noise
(the official IGN statistics use 5-year windows). The result is cached; use
`force=true` to recompute it.

# Example
```julia
df = process_data(country="France")
filter(r -> r.level == "region" && r.region == "Grand Est" && r.year == 2023, df)
```
"""
function process_data(; country::AbstractString, window::Integer=1, force::Bool=false)
    window >= 1 || throw(ArgumentError("`window` must be ≥ 1"))
    plugin = get_country(country)
    dir = data_dir(plugin)
    path = joinpath(dir, "processed_v$(CACHE_VERSION)_w$(window).csv")
    return cached_table(path; force) do
        download!(plugin, dir; force=false)
        aggregate_levels(process(plugin, dir; window), country_name(plugin))
    end
end

"""
$(TYPEDSIGNATURES)

Regions of `country` that can be used as `subregion`, as a table with columns
`region_code` and `region`.
"""
available_regions(; country::AbstractString) =
    unique(select(admin_units(get_country(country)), :region_code, :region))

"""
$(TYPEDSIGNATURES)

Departments (second-level administrative units) of `country` that can be used as
`subregion`, as a table with columns `department_code`, `department` and `region`.
"""
available_departments(; country::AbstractString) =
    select(admin_units(get_country(country)), :department_code, :department, :region)

"""
$(TYPEDSIGNATURES)

Species (Latin names) found alive in the inventory of `country`, with the number of plots
where they were observed and their national standing volume in the latest year, sorted
by decreasing volume. Requires the processed data (see [`process_data`](@ref)).
"""
function available_species(; country::AbstractString)
    df = filter(r -> r.level == "country", process_data(; country))
    last = maximum(df.year)
    out = combine(groupby(df, :specie),
        :n_plots => sum => :n_plots,
        [:year, :vol] => ((y, v) -> sum_skipmissing(v[y .== last])) => :vol_last_year)
    out.vol_last_year = coalesce.(out.vol_last_year, 0.0)
    filter!(r -> r.n_plots > 0, out)
    return sort!(out, :vol_last_year; rev=true)
end

"""
$(TYPEDSIGNATURES)

Resolve a `subregion` name or code (case- and accent-insensitive) into a named tuple
`(level, code, name, region)`, where `level` is `:country`, `:region` or `:department`.
An empty string denotes the whole country.
"""
function resolve_subregion(plugin::AbstractCountry, subregion::AbstractString)
    isempty(strip(subregion)) && return (level=:country, code="", name=country_name(plugin), region="")
    key = normalize_name(subregion)
    units = admin_units(plugin)
    for r in eachrow(unique(units, :region_code))
        key in (normalize_name(r.region), normalize_name(r.region_code)) &&
            return (level=:region, code=r.region_code, name=r.region, region=r.region)
    end
    for r in eachrow(units)
        key in (normalize_name(r.department), normalize_name(r.department_code)) &&
            return (level=:department, code=r.department_code, name=r.department, region=r.region)
    end
    throw(ArgumentError("Unknown subregion \"$subregion\" for $(country_name(plugin)). " *
                        "See `available_regions` and `available_departments`."))
end

"Rows of the processed table `df` belonging to the resolved subregion `sub` (all levels)."
function in_subregion(df::AbstractDataFrame, sub)
    sub.level == :country && return trues(nrow(df))
    col = sub.level == :region ? df.region : df.department
    return coalesce.(col .== sub.name, false)
end

"""
$(TYPEDSIGNATURES)

Return the species of `available` matching `specie`: the exact (case-insensitive) Latin
name if present, otherwise all the taxa whose name starts with `specie` (so that, e.g.,
`"Pinus nigra"` selects all its subspecies and varieties).
"""
function match_species(available, specie::AbstractString)
    key = normalize_name(specie)
    names = unique(available)
    exact = filter(s -> normalize_name(s) == key, names)
    isempty(exact) || return exact
    prefix = filter(s -> startswith(normalize_name(s), key * " "), names)
    isempty(prefix) || return sort(prefix)
    genus = first(split(key))
    hint = filter(s -> startswith(normalize_name(s), genus), names)
    throw(ArgumentError("Unknown species \"$specie\"." *
                        (isempty(hint) ? "" : " Did you mean one of: $(join(sort(hint), ", "))?") *
                        " See `available_species`."))
end

"Cached tree-level growth observations of a plugin."
function cached_growth_observations(plugin::AbstractCountry; force::Bool=false)
    dir = data_dir(plugin)
    return cached_table(joinpath(dir, "growth_obs_v$(CACHE_VERSION).csv"); force) do
        download!(plugin, dir; force=false)
        growth_observations(plugin, dir)
    end
end

"Cached plot-level observations of a plugin."
function cached_plot_observations(plugin::AbstractCountry; force::Bool=false)
    dir = data_dir(plugin)
    return cached_table(joinpath(dir, "plot_obs_v$(CACHE_VERSION).csv"); force) do
        download!(plugin, dir; force=false)
        plot_observations(plugin, dir)
    end
end

"Cached forest cover of a plugin."
function cached_forest_cover(plugin::AbstractCountry; force::Bool=false)
    dir = data_dir(plugin)
    return cached_table(joinpath(dir, "forest_cover_v$(CACHE_VERSION).csv"); force) do
        download!(plugin, dir; force=false)
        forest_cover(plugin, dir)
    end
end
