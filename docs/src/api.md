# API

```@docs
ForestDataExplorer
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
Modules = [ForestDataExplorer, ForestDataExplorer.France]
Public = false
Filter = t -> !(t in (ForestDataExplorer.register_country!, ForestDataExplorer.France,
                      ForestDataExplorer.chapman_richards, ForestDataExplorer.fit_chapman_richards))
```
