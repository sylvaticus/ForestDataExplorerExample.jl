# A small synthetic dataset with the same files and formats as the real French sources
# (IGN inventory CSVs, Corine Land Cover shapefiles, GeoJSON borders), so that the whole
# pipeline can be tested offline and its results checked against hand computations.
#
# Two departments of Grand Est are modelled as lon/lat rectangles: Vosges (88, south) and
# Meurthe-et-Moselle (54, north). Each campaign 2014–2020 has three first-visit plots per
# department; the plots of 2014 and 2015 are revisited in 2019 and 2020.

using CSV, DataFrames, JSON, Proj, Shapefile, Statistics

const FIX_DEPS = [(code="88", name="Vosges", lat=(48.0, 48.5)), (code="54", name="Meurthe-et-Moselle", lat=(48.5, 49.0))]
const FIX_LON = (6.0, 7.0)
const FIX_CAMPAIGNS = 2014:2020
const FIX_PLOTS = 1:3
"Chapman-Richards parameters used to generate the tree volumes, by IGN species code."
const FIX_GROWTH = Dict("09" => [3.0, 0.03, 3.0], "61" => [4.0, 0.02, 2.5])
"Land cover areas (ha) by department and forest type."
const FIX_COVER = Dict("88" => (broadleaved=1000.0, coniferous=500.0, mixed=0.0),
    "54" => (broadleaved=1000.0, coniferous=0.0, mixed=200.0))

cr(t, p) = p[1] * (1 - exp(-p[2] * t))^p[3]
fix_idp(campaign, k, j) = campaign * 100 + 10k + j
fix_age(campaign, k, j, a) = 15 + mod(37 * (fix_idp(campaign, k, j) + 7a), 140)

"Status at the second visit of the tree `a` of plot `j`."
fix_veget5(j, a) = a == 2 ? ("6", "M", "0")[j] : "0"

rect(lon, lat) = [[lon[1], lat[1]], [lon[2], lat[1]], [lon[2], lat[2]], [lon[1], lat[2]], [lon[1], lat[1]]]
feature(props, lon, lat) = Dict("type" => "Feature", "properties" => props,
    "geometry" => Dict("type" => "Polygon", "coordinates" => [rect(lon, lat)]))

function write_fixture(root::AbstractString)
    dir = mkpath(joinpath(root, "france"))
    inv = mkpath(joinpath(dir, "inventory"))
    lc = mkpath(joinpath(dir, "landcover"))
    bd = mkpath(joinpath(dir, "boundaries"))
    to_l93 = Proj.Transformation("EPSG:4326", "EPSG:2154"; always_xy=true)
    to_laea = Proj.Transformation("EPSG:4326", "EPSG:3035"; always_xy=true)

    # borders
    open(joinpath(bd, "department.geojson"), "w") do io
        JSON.print(io, Dict("type" => "FeatureCollection", "features" =>
            [feature(Dict("code" => d.code, "nom" => d.name), FIX_LON, d.lat) for d in FIX_DEPS]))
    end
    open(joinpath(bd, "region.geojson"), "w") do io
        JSON.print(io, Dict("type" => "FeatureCollection", "features" =>
            [feature(Dict("code" => "44", "nom" => "Grand Est"), FIX_LON, (48.0, 49.0))]))
    end
    open(joinpath(bd, "country.geojson"), "w") do io  # a single Feature, as in the real file
        JSON.print(io, feature(Dict(), FIX_LON, (48.0, 49.0)))
    end

    # land cover: one square polygon per department and forest type, at the department centre
    layers = Dict("broadleaved" => "clc06_c311_fr", "coniferous" => "clc06_c312_fr", "mixed" => "clc06_c313_fr")
    for (cat, layer) in layers
        geoms = Shapefile.Polygon[]
        for d in FIX_DEPS
            ha = getfield(FIX_COVER[d.code], Symbol(cat))
            ha > 0 || continue
            cx, cy = to_laea(mean(FIX_LON), mean(d.lat))
            h = sqrt(ha * 10_000) / 2
            pts = Shapefile.Point.([cx - h, cx - h, cx + h, cx + h, cx - h], [cy - h, cy + h, cy + h, cy - h, cy - h])
            push!(geoms, Shapefile.Polygon(Shapefile.Rect(cx - h, cy - h, cx + h, cy + h), Int32[0], pts))
        end
        Shapefile.write(joinpath(lc, "$layer.shp"), DataFrame(geometry=geoms, code_06=fill(cat, length(geoms))); force=true)
        write(joinpath(lc, "$layer.prj"), "LAEA")
    end

    # inventory
    plots = DataFrame(CAMPAGNE=Int[], IDP=Int[], XL=Float64[], YL=Float64[], VISITE=Int[], DEP=String[], CSA=Union{String,Missing}[])
    trees = DataFrame(CAMPAGNE=Int[], IDP=Int[], A=Int[], ESPAR=Union{String,Missing}[], VEGET=Union{String,Missing}[],
        VEGET5=Union{String,Missing}[], C13=Union{Float64,Missing}[], HTOT=Union{Float64,Missing}[],
        V=Union{Float64,Missing}[], W=Union{Float64,Missing}[], IR5=Union{Float64,Missing}[], AGE13=Union{Int,Missing}[])
    for c in FIX_CAMPAIGNS, (k, d) in enumerate(FIX_DEPS), j in FIX_PLOTS
        idp = fix_idp(c, k, j)
        x, y = to_l93(FIX_LON[1] + 0.25j, mean(d.lat))
        push!(plots, (c, idp, x, y, 1, d.code, "1"))
        for (a, espar, c13, w) in ((1, "09", 1.2, 14.15), (2, "61", 0.9, 39.29))
            age = fix_age(c, k, j, a)
            ir5 = (a == 2 && j == 3) ? missing : 0.004 * a + 0.001j
            push!(trees, (c, idp, a, espar, "0", missing, c13, 20.0, cr(age, FIX_GROWTH[espar]), w, ir5, age))
        end
        # a dead tree and a tree of a species missing from the lookup table
        push!(trees, (c, idp, 3, "09", "5", missing, 1.0, 15.0, 0.8, 14.15, missing, missing))
        push!(trees, (c, idp, 4, "25E3", "0", missing, 0.5, 10.0, 0.1, 88.4, 0.002, missing))
        # second visit, five years later
        if c + 5 in FIX_CAMPAIGNS
            push!(plots, (c + 5, idp, x, y, 2, d.code, missing))
            for a in 1:4
                push!(trees, (c + 5, idp, a, missing, missing, a == 3 ? "M" : fix_veget5(j, a), missing, missing,
                    missing, 14.15, missing, missing))
            end
        end
    end
    CSV.write(joinpath(inv, "PLACETTE.csv"), plots; delim=';')
    CSV.write(joinpath(inv, "ARBRE.csv"), trees; delim=';')
    write(joinpath(inv, "espar-cdref13.csv"),
        "﻿// espar;lib_espar;cd_ref;lib_cdref\n9;Hêtre;97947;Fagus sylvatica\n61;Sapin pectiné;79319;Abies alba\n")
    return dir
end
