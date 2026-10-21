"""
    ForestDataExplorer.France

Country plugin for metropolitan France.

Data sources (URLs in `sources.toml`, next to this file):

- **Forest inventory**: IGN raw data of the annual campaigns (2005 onwards): plots
  (`PLACETTE.csv`), trees (`ARBRE.csv`) and the species code list (`espar-cdref13.csv`);
- **Land cover**: Corine Land Cover 2006 forest classes 311 (broadleaved), 312
  (coniferous) and 313 (mixed);
- **Administrative borders**: simplified GeoJSON of the country, its 13 regions and 96
  departments.

See the "Methodology" page of the documentation for how indicators are estimated.
"""
module France

using CSV
using DataFrames
using DocStringExtensions
using Proj
using Shapefile
using Statistics
using TOML

import ..ForestDataExplorer as FDE
using ..ForestDataExplorer: AbstractCountry, AdminShape, Pt

include("admin.jl")

"Data sources configuration, read from `sources.toml`."
const SOURCES = TOML.parsefile(joinpath(@__DIR__, "sources.toml"))

"Land cover classes (`CSA`) of the inventory plots considered as forest: closed and open forest, groves and poplar plantations."
const FOREST_CSA = ("1", "2", "3", "5")
"Tree status (`VEGET`) of living standing trees."
const LIVE = "0"
"Tree status at the second visit (`VEGET5`) of harvested trees."
const HARVESTED = ("6", "7")
"Tree status at the second visit (`VEGET5`) of trees dead of natural causes (standing dead, broken, windthrown)."
const DEAD = ("5", "C", "M", "A", "1", "2", "T")
"Years between the first and the second visit of a plot."
const REVISIT_INTERVAL = 5
"""
First campaign where all the trees of revisited plots are re-assessed. In 2010-2014 the
second visit followed a lighter protocol (trees were re-assessed only on a fraction of the
plots), so harvest and mortality are estimated from 2015 onwards.
"""
const FIRST_FULL_REVISIT = 2015

"""
$(TYPEDEF)

The France country plugin, registered under the name `"France"`.
"""
struct Plugin <: AbstractCountry end

FDE.country_name(::Plugin) = "France"
FDE.admin_units(::Plugin) = copy(ADMIN_UNITS)
FDE.data_sources(::Plugin) = [SOURCES[k]["citation"] for k in ("inventory", "landcover", "boundaries")]

inventory_file(dir, name) = joinpath(dir, "inventory", name)
landcover_file(dir, layer, ext="shp") = joinpath(dir, "landcover", "$layer.$ext")
boundaries_file(dir, level) = joinpath(dir, "boundaries", "$level.geojson")

function FDE.download!(::Plugin, dir::AbstractString; force::Bool=false)
    inv = SOURCES["inventory"]
    if force || !all(f -> isfile(inventory_file(dir, f)), inv["files"])
        zip = FDE.fetch_file(inv["url"], inventory_file(dir, "export.zip"); force)
        FDE.extract_zip(zip, dirname(zip); files=inv["files"])
        rm(zip)
    end
    lc = SOURCES["landcover"]
    for layer in values(lc["layers"]), ext in lc["extensions"]
        FDE.fetch_file("$(lc["base_url"])/$layer.$ext", landcover_file(dir, layer, ext); force)
    end
    for level in ("country", "region", "department")
        FDE.fetch_file(SOURCES["boundaries"][level], boundaries_file(dir, level); force)
    end
    return nothing
end

function FDE.boundaries(::Plugin, dir::AbstractString, level::Symbol; crs=SOURCES["maps"]["crs"])
    level in (:country, :region, :department) ||
        throw(ArgumentError("`level` must be :country, :region or :department"))
    shapes = FDE.read_geojson(boundaries_file(dir, level))
    if level == :country
        shapes = [AdminShape("FR", "France", reduce(vcat, [s.polygons for s in shapes]))]
    end
    return FDE.reproject(shapes, SOURCES["boundaries"]["crs"], crs)
end

"Rings of a shapefile polygon, as vectors of points."
function shapefile_rings(geom)
    pts = geom.points
    starts = Int.(geom.parts) .+ 1
    stops = [starts[2:end] .- 1; length(pts)]
    return [[Pt((pts[i].x, pts[i].y)) for i in a:b] for (a, b) in zip(starts, stops)]
end

function FDE.forest_cover(p::Plugin, dir::AbstractString)
    lc = SOURCES["landcover"]
    deps = FDE.boundaries(p, dir, :department)
    to_map = Proj.Transformation(lc["crs"], SOURCES["maps"]["crs"]; always_xy=true)
    out = DataFrame(department_code=[s.code for s in deps])
    for (category, layer) in sort(collect(lc["layers"]))
        @info "Computing forest area by department from land cover layer $layer"
        areas = Float64[]
        points = Pt[]
        for geom in Shapefile.shapes(Shapefile.Table(landcover_file(dir, layer)))
            ismissing(geom) && continue
            rings = shapefile_rings(geom)
            # outer rings and holes have opposite orientations, so the signed sum is the net area
            push!(areas, abs(sum(FDE.signed_area, rings)))
            outer = rings[argmax([abs(FDE.signed_area(r)) for r in rings])]
            push!(points, Pt(to_map(FDE.ring_centroid(outer)...)))
        end
        idx = FDE.assign_points(points, deps)
        ha = zeros(length(deps))
        for (k, a) in zip(idx, areas)
            k > 0 && (ha[k] += a / 10_000)
        end
        out[!, Symbol(category)] = ha
    end
    # land area computed in an equal-area projection
    deps_ea = FDE.boundaries(p, dir, :department; crs=lc["crs"])
    out.land_area = [FDE.shape_area(s) / 10_000 for s in deps_ea]
    return out
end

# ----------------------------------------------------------------------------------------
# Inventory

"Species lookup table: IGN `ESPAR` code => Latin name (TAXREF)."
function species_lookup(dir::AbstractString)
    t = CSV.read(inventory_file(dir, "espar-cdref13.csv"), DataFrame; delim=';', skipto=2,
        header=["espar", "lib_espar", "cd_ref", "lib_cdref"], types=String)
    return Dict(zip(t.espar, t.lib_cdref))
end

"Normalise an IGN species code: the tree table pads one-digit codes with a zero (`\"09\"`), the lookup table does not (`\"9\"`)."
normalize_espar(code::AbstractString) = length(code) == 2 && code[1] == '0' ? code[2:2] : String(code)

"Latin name of an IGN species code."
species_name(lookup, code::AbstractString) = get(lookup, normalize_espar(code), "Unidentified (IGN code $code)")

"""
$(TYPEDSIGNATURES)

Load the inventory plots and trees, keeping the columns used by the package.
Plots are restricted to the departments of the administrative table and annotated with
their region and department names.
"""
function load_inventory(dir::AbstractString)
    @info "Reading the French forest inventory"
    plots = CSV.read(inventory_file(dir, "PLACETTE.csv"), DataFrame; delim=';',
        select=[:CAMPAGNE, :IDP, :XL, :YL, :VISITE, :DEP, :CSA],
        types=Dict(:DEP => String, :CSA => String), validate=false)
    rename!(plots, :DEP => :department_code)
    plots = innerjoin(plots, ADMIN_UNITS; on=:department_code)
    trees = CSV.read(inventory_file(dir, "ARBRE.csv"), DataFrame; delim=';',
        select=[:CAMPAGNE, :IDP, :A, :ESPAR, :VEGET, :VEGET5, :C13, :HTOT, :V, :W, :IR5, :AGE13],
        types=Dict(:ESPAR => String, :VEGET => String, :VEGET5 => String), validate=false)
    lookup = species_lookup(dir)
    trees.specie = [ismissing(c) ? missing : species_name(lookup, c) for c in trees.ESPAR]
    return plots, trees
end

"Forest plots at their first visit."
first_visit_plots(plots) =
    select(filter(r -> r.VISITE == 1 && coalesce(r.CSA, "") in FOREST_CSA, plots),
        :CAMPAGNE, :IDP, :XL, :YL, :region_code, :region, :department_code, :department)

"Living trees measured at the first visit of forest plots, with their size."
function live_trees(trees, p1)
    t = innerjoin(trees, select(p1, :CAMPAGNE, :IDP); on=[:CAMPAGNE, :IDP])
    filter!(r -> coalesce(r.VEGET, "") == LIVE && !ismissing(r.V) && !ismissing(r.W) &&
                 !ismissing(r.C13) && r.C13 > 0, t)
    t.D = t.C13 ./ π                       # diameter at breast height (m)
    t.vol = t.W .* t.V                     # m³/ha
    t.ba = t.W .* t.C13 .^ 2 ./ (4π)       # m²/ha
    return t
end

"""
$(TYPEDSIGNATURES)

Elasticity of tree volume to diameter by species, from a log-log regression of `V` on
`D` (all years pooled). Species with fewer than 50 trees use the pooled estimate.
"""
function volume_exponents(t)
    ok = (t.V .> 0) .& (t.D .> 0)
    slope(x, y) = cov(x, y) / var(x)
    pooled = slope(log.(t.D[ok]), log.(t.V[ok]))
    g = combine(groupby(t[ok, :], :specie), nrow => :n,
        [:D, :V] => ((d, v) -> length(d) > 2 ? slope(log.(d), log.(v)) : NaN) => :beta)
    return Dict(r.specie => clamp(r.n >= 50 && isfinite(r.beta) ? r.beta : pooled, 1.5, 3.5) for r in eachrow(g))
end

"""
$(TYPEDSIGNATURES)

Add to the living trees `t` their annual relative volume growth `g` and their annual
volume growth per hectare `growth` (m³/ha/year).

The 5-year radial increment `IR5` gives the diameter five years ago, `D5 = D - 2 IR5`;
volume growth is derived assuming `V ∝ D^β`, with a species-specific `β`
([`volume_exponents`](@ref)). Trees whose increment was not measured get the mean
relative growth of the trees of the same campaign, species and 10-cm diameter class
(falling back to campaign and species, then campaign).
"""
function add_growth!(t)
    β = volume_exponents(t)
    t.g = [ismissing(ir) ? missing : (1 - max(1 - 2ir / d, 0.0)^β[s]) / REVISIT_INTERVAL
           for (ir, d, s) in zip(t.IR5, t.D, t.specie)]
    t.dclass = floor.(Int, t.D .* 10)
    for (i, keys) in enumerate(([:CAMPAGNE, :specie, :dclass], [:CAMPAGNE, :specie], [:CAMPAGNE]))
        transform!(groupby(t, keys), :g => FDE.mean_skipmissing => Symbol(:g_, i))
    end
    t.g = coalesce.(t.g, t.g_1, t.g_2, t.g_3, 0.0)
    t.growth = t.vol .* t.g
    select!(t, Not([:g_1, :g_2, :g_3, :dclass]))
    return t
end

"""
$(TYPEDSIGNATURES)

Annual harvest and natural mortality (m³/ha/year) of the trees of revisited plots, by
campaign of the second visit, plot and species. Trees are identified with their first
visit record, five years earlier, which provides their volume and weight.
"""
function revisit_flows(trees, p2, live)
    t = innerjoin(select(trees, :CAMPAGNE, :IDP, :A, :VEGET5), select(p2, :CAMPAGNE, :IDP); on=[:CAMPAGNE, :IDP])
    filter!(r -> !ismissing(r.VEGET5), t)
    t.first_campaign = t.CAMPAGNE .- REVISIT_INTERVAL
    first = select(live, :CAMPAGNE => :first_campaign, :IDP, :A, :specie, :vol)
    t = innerjoin(t, first; on=[:first_campaign, :IDP, :A])
    t.harvest = ifelse.(in.(t.VEGET5, Ref(HARVESTED)), t.vol ./ REVISIT_INTERVAL, 0.0)
    t.mortality = ifelse.(in.(t.VEGET5, Ref(DEAD)), t.vol ./ REVISIT_INTERVAL, 0.0)
    return combine(groupby(t, [:CAMPAGNE, :IDP, :specie]), :harvest => sum => :harvest, :mortality => sum => :mortality)
end

"""
Duplicate the rows of a campaign-level table so that each campaign also contributes to the
`window - 1` following years (column `year`), up to `lastyear`.
"""
function expand_window(df, window, lastyear)
    out = vcat([transform(df, :CAMPAGNE => (c -> c .+ k) => :year) for k in 0:window-1]...)
    return filter!(r -> r.year <= lastyear, out)
end

function FDE.process(p::Plugin, dir::AbstractString; window::Integer=1)
    plots, trees = load_inventory(dir)
    cover = FDE.cached_forest_cover(p)
    area = Dict(r.department_code => r.broadleaved + r.coniferous + r.mixed for r in eachrow(cover))
    lastyear = maximum(plots.CAMPAGNE)

    @info "Estimating stocks and growth"
    p1 = first_visit_plots(plots)
    live = add_growth!(live_trees(trees, p1))
    stock = combine(groupby(live, [:CAMPAGNE, :IDP, :specie]),
        :vol => sum => :vol, :ba => sum => :ba, :growth => sum => :growth)

    @info "Estimating harvest and mortality"
    p2 = select(filter(r -> r.VISITE == 2, plots), :CAMPAGNE, :IDP, :department_code)
    p2.first_campaign = p2.CAMPAGNE .- REVISIT_INTERVAL
    p2 = semijoin(p2, select(p1, :CAMPAGNE => :first_campaign, :IDP); on=[:first_campaign, :IDP])
    filter!(r -> r.CAMPAGNE >= FIRST_FULL_REVISIT, p2)
    flows = revisit_flows(trees, p2, live)

    # pool campaigns into windows and attach departments
    dep_of(df, plots_df) = innerjoin(df, select(plots_df, :CAMPAGNE, :IDP, :department_code); on=[:CAMPAGNE, :IDP])
    p1w = expand_window(p1, window, lastyear)
    p2w = expand_window(p2, window, lastyear)
    stockw = expand_window(dep_of(stock, p1), window, lastyear)
    flowsw = expand_window(dep_of(flows, p2), window, lastyear)

    # sample sizes by year and department
    n1 = combine(groupby(p1w, [:year, :department_code]), nrow => :n1)
    n2 = combine(groupby(p2w, [:year, :department_code]), nrow => :n2)

    st = combine(groupby(stockw, [:year, :department_code, :specie]),
        :vol => sum => :vol, :ba => sum => :ba, :growth => sum => :growth, nrow => :n_plots)
    fl =combine(groupby(flowsw, [:year, :department_code, :specie]),
        :harvest => sum => :harvest, :mortality => sum => :mortality)

    d = outerjoin(st, fl; on=[:year, :department_code, :specie])
    d = innerjoin(d, n1; on=[:year, :department_code])          # departments with plots that year
    d = leftjoin(d, n2; on=[:year, :department_code])
    for c in (:vol, :ba, :growth, :n_plots, :harvest, :mortality, :n2)
        d[!, c] = coalesce.(d[!, c], 0)
    end
    transform!(groupby(d, [:year, :department_code]), :ba => sum => :ba_total)

    A = [get(area, c, 0.0) for c in d.department_code]
    d.vol = d.vol ./ d.n1 .* A
    d.ha = FDE.safe_div.(d.ba, d.ba_total) .* A
    d.biological_growth = d.growth ./ d.n1 .* A
    d.harvested_volumes = [n > 0 ? h / n * a : missing for (h, n, a) in zip(d.harvest, d.n2, A)]
    d.mortality_volumes = [n > 0 ? m / n * a : missing for (m, n, a) in zip(d.mortality, d.n2, A)]
    d.ha = coalesce.(d.ha, 0.0)
    d = innerjoin(d, ADMIN_UNITS; on=:department_code)
    return select(d, :year, :region_code, :region, :department_code, :department, :specie,
        :vol, :ha, :harvested_volumes, :mortality_volumes, :biological_growth, :n_plots)
end

function FDE.growth_observations(::Plugin, dir::AbstractString)
    plots, trees = load_inventory(dir)
    p1 = first_visit_plots(plots)
    t = live_trees(trees, p1)
    filter!(r -> !ismissing(r.AGE13) && r.AGE13 > 0, t)
    t = innerjoin(t, select(p1, :CAMPAGNE, :IDP, :region, :department); on=[:CAMPAGNE, :IDP])
    return select(t, :CAMPAGNE => :year, :region, :department, :specie, :AGE13 => :age,
        :V => :volume, :D => (d -> d .* 100) => :diameter, :HTOT => :height)
end

function FDE.plot_observations(::Plugin, dir::AbstractString)
    plots, trees = load_inventory(dir)
    p1 = first_visit_plots(plots)
    t = live_trees(trees, p1)
    v = combine(groupby(t, [:CAMPAGNE, :IDP]), :vol => sum => :vol_ha)
    out = leftjoin(p1, v; on=[:CAMPAGNE, :IDP])
    out.vol_ha = coalesce.(out.vol_ha, 0.0)
    return select(out, :CAMPAGNE => :year, :XL => :x, :YL => :y, :region, :department, :vol_ha)
end

end # module France
