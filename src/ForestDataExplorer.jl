"""
    ForestDataExplorer

Download, process and analyse national forest inventory data.

The package exposes a small, country-agnostic API:

- [`download_data`](@ref): download and cache the raw data of a country;
- [`process_data`](@ref): turn the raw data into a tidy table of forest indicators;
- [`estimate_growth`](@ref): fit a sigmoid (Chapman-Richards) growth model;
- [`create_report`](@ref): produce a multi-page PDF report with maps and charts.

Country-specific logic lives in "country plugins" (see [`AbstractCountry`](@ref)).
The only plugin currently shipped is [`France`](@ref ForestDataExplorer.France).
"""
module ForestDataExplorer

using CSV
using DataFrames
using Dates
using DocStringExtensions
using Downloads
using JSON
using LsqFit
using Printf
using Proj
using Scratch
using Shapefile
using Statistics
using TOML
using Unicode
using ZipArchives
import Cairo
import CairoMakie

export download_data, process_data, estimate_growth, create_report
export available_countries, available_regions, available_departments, available_species
export GrowthModel, predict, current_increment, mean_increment, culmination_age
export data_dir, AbstractCountry

include("utils.jl")
include("geometry.jl")
include("plugins.jl")
include("aggregation.jl")
include("api.jl")
include("growth.jl")
include("report.jl")

include("countries/France/France.jl")

function __init__()
    register_country!(France.Plugin())
end

end # module
