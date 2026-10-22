# Country plugins

Everything that depends on the data of a country lives in a *plugin*: a singleton subtype
of [`AbstractCountry`](@ref) adding methods to a small set of interface functions. The
public API ([`download_data`](@ref), [`process_data`](@ref), [`estimate_growth`](@ref),
[`create_report`](@ref)) only talks to plugins through this interface, and takes care of
caching, aggregation to regions and country, subregion and species matching, growth
models and reports.

The France plugin is the submodule `ForestDataExplorerExample.France`
(`src/countries/France/`). Its data sources are configured in `sources.toml`, so URLs can
be updated without touching the code.

## Adding a country

1. Create `src/countries/<Country>/<Country>.jl` with a submodule defining
   `struct Plugin <: AbstractCountry end`.
2. Implement the interface methods listed in the docstring of [`AbstractCountry`](@ref):
   `country_name`, `download!`, `admin_units`, `process`, `growth_observations`,
   `plot_observations`, `boundaries`, `forest_cover` and `data_sources`.
   `process` must return additive totals at the department (second administrative) level
   with the columns `year, region_code, region, department_code, department, specie, vol,
   ha, harvested_volumes, mortality_volumes, biological_growth, n_plots`.
3. Include the file in `src/ForestDataExplorerExample.jl` and register the plugin in `__init__`
   with `register_country!(<Country>.Plugin())`.

In a future version plugins may become package extensions, loaded when the user
installs a country-specific package; the interface would stay the same.

```@docs
AbstractCountry
ForestDataExplorerExample.register_country!
ForestDataExplorerExample.France
```
