# Country plugins.
#
# Everything that depends on the data sources of a given country is implemented by a
# "plugin": a singleton subtype of `AbstractCountry` that adds methods to the interface
# functions below. The public API (`download_data`, `process_data`, ...) only talks to
# plugins through this interface, so supporting a new country means writing a new plugin
# (today a submodule, in the future possibly a package extension) and registering it.

"""
$(TYPEDEF)

Supertype of the country plugins.

A plugin `P <: AbstractCountry` must implement the following methods
(`dir` is the cache folder returned by [`data_dir`](@ref)):

| Method | Returns |
|:-------|:--------|
| `country_name(::P)` | the display name of the country, e.g. `"France"` |
| `download!(::P, dir; force)` | nothing; downloads raw inventory, borders and land cover into `dir` |
| `admin_units(::P)` | `DataFrame` with columns `region_code, region, department_code, department` |
| `process(::P, dir; window)` | department-level `DataFrame` of totals (see [`process_data`](@ref)) |
| `growth_observations(::P, dir)` | `DataFrame` with columns `region, department, specie, age, volume, diameter, height` |
| `plot_observations(::P, dir)` | `DataFrame` with columns `year, x, y, region, department, vol_ha` (map CRS) |
| `boundaries(::P, dir, level)` | `Vector{AdminShape}` for `level` in `(:country, :region, :department)` |
| `forest_cover(::P, dir)` | `DataFrame` with columns `department_code, broadleaved, coniferous, mixed, land_area` (ha) |
| `data_sources(::P)` | `Vector{String}` of citations to print in reports |

Plugins are made available by name with [`register_country!`](@ref).
"""
abstract type AbstractCountry end

"Display name of a country plugin."
function country_name end
"Download the raw data of a country plugin into a folder."
function download! end
"Administrative units (regions and departments) of a country plugin."
function admin_units end
"Compute the department-level table of totals of a country plugin."
function process end
"Tree-level observations (age and size) used to fit growth models."
function growth_observations end
"Plot-level observations used to draw dot maps."
function plot_observations end
"Administrative borders of a country plugin at a given level."
function boundaries end
"Forest cover (land-cover based) by department."
function forest_cover end
"Citations of the data sources used by a country plugin."
function data_sources end

const COUNTRIES = Dict{String,AbstractCountry}()

"""
$(TYPEDSIGNATURES)

Register a country plugin so that it can be selected by name (case- and
accent-insensitive) in the public API.
"""
function register_country!(plugin::AbstractCountry)
    COUNTRIES[normalize_name(country_name(plugin))] = plugin
    return plugin
end

"""
$(TYPEDSIGNATURES)

Names of the countries for which a plugin is available.
"""
available_countries() = sort!([country_name(p) for p in values(COUNTRIES)])

"""
$(TYPEDSIGNATURES)

Return the plugin registered for `country`, or throw an informative error.
"""
function get_country(country::AbstractString)
    key = normalize_name(country)
    haskey(COUNTRIES, key) && return COUNTRIES[key]
    throw(ArgumentError("No plugin available for country \"$country\". Available countries: $(join(available_countries(), ", "))."))
end
get_country(plugin::AbstractCountry) = plugin

"Cache folder of a plugin."
data_dir(plugin::AbstractCountry) = data_dir(country_name(plugin))
