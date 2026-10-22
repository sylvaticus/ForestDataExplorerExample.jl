# API

```@docs
ForestDataExplorerExample
```

## Main functions

```@docs
download_data
process_data
estimate_growth
create_report
```

## Available names

```@docs
available_countries
available_regions
available_departments
available_species
data_dir
```

## Growth models

```@docs
GrowthModel
predict
current_increment
mean_increment
culmination_age
ForestDataExplorer.chapman_richards
ForestDataExplorer.fit_chapman_richards
```

## Internals

```@autodocs
Modules = [ForestDataExplorerExample, ForestDataExplorerExample.France]
Public = false
Filter = t -> !(t in (ForestDataExplorerExample.register_country!, ForestDataExplorerExample.France,
                      ForestDataExplorerExample.chapman_richards, ForestDataExplorerExample.fit_chapman_richards))
```
