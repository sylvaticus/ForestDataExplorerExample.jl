using ForestDataExplorerExample
using ForestDataExplorerExample: France
using DataFrames
using Statistics
using Test

const FDE = ForestDataExplorerExample

include("fixture.jl")

# All tests run on the synthetic fixture: point the cache to a temporary folder.
const FIXTURE_ROOT = mktempdir()
write_fixture(FIXTURE_ROOT)
ENV[FDE.CACHE_ENV] = FIXTURE_ROOT

@testset "ForestDataExplorerExample.jl" begin

    @testset "Utilities" begin
        @test FDE.normalize_name("Provence-Alpes-Côte d'Azur") == "provence alpes cote d azur"
        @test FDE.normalize_name("  ÎLE-de-France ") == "ile de france"
        @test FDE.safe_div(1, 2) == 0.5
        @test ismissing(FDE.safe_div(1, 0))
        @test ismissing(FDE.safe_div(missing, 2))
        @test ismissing(FDE.sum_skipmissing([missing, missing]))
        @test FDE.sum_skipmissing([1, missing, 2]) == 3
        @test FDE.fmt(1234567.0) == "1 234 567"
        @test FDE.fmt(12.345) == "12.3"
        @test FDE.fmt(missing) == "–"
        @test FDE.unit_scale([2.5e6], "m³") == (1e6, "million m³")
        @test FDE.unit_scale([500.0], "ha") == (1.0, "ha")
    end

    @testset "Geometry" begin
        sq = [(0.0, 0.0), (2.0, 0.0), (2.0, 2.0), (0.0, 2.0)]
        hole = [(0.5, 0.5), (0.5, 1.0), (1.0, 1.0), (1.0, 0.5)]
        @test FDE.signed_area(sq) == 4.0
        @test FDE.signed_area(reverse(sq)) == -4.0
        @test FDE.polygon_area([sq, hole]) == 3.75
        @test FDE.ring_centroid(sq) == (1.0, 1.0)
        @test FDE.in_polygon((1.5, 1.5), [sq, hole])
        @test !FDE.in_polygon((0.75, 0.75), [sq, hole])
        @test !FDE.in_polygon((3.0, 1.0), [sq])
        shapes = [FDE.AdminShape("A", "a", [[sq]]), FDE.AdminShape("B", "b", [[[(x + 10, y) for (x, y) in sq]]])]
        @test FDE.assign_points([(1.0, 1.0), (11.0, 1.0), (2.5, 2.2), (100.0, 100.0)], shapes; maxdist=1.0) == [1, 2, 1, 0]
    end

    @testset "Plugin registry and administrative units" begin
        @test "France" in available_countries()
        @test FDE.get_country("france") isa France.Plugin
        @test_throws ArgumentError FDE.get_country("Atlantis")
        regs = available_regions(country="France")
        deps = available_departments(country="France")
        @test nrow(regs) == 13
        @test nrow(deps) == 96
        @test allunique(deps.department_code)
        p = FDE.get_country("France")
        @test FDE.resolve_subregion(p, "") == (level=:country, code="", name="France", region="")
        @test FDE.resolve_subregion(p, "grand est").level == :region
        r = FDE.resolve_subregion(p, "88")
        @test (r.level, r.name, r.region) == (:department, "Vosges", "Grand Est")
        @test FDE.resolve_subregion(p, "Cote d'Or").code == "21"
        @test_throws ArgumentError FDE.resolve_subregion(p, "Narnia")
    end

    @testset "Species codes and matching" begin
        lookup = Dict("9" => "Fagus sylvatica")
        @test France.normalize_espar("09") == "9"
        @test France.normalize_espar("29MI") == "29MI"
        @test France.species_name(lookup, "09") == "Fagus sylvatica"
        @test France.species_name(lookup, "25E3") == "Unidentified (IGN code 25E3)"
        taxa = ["Pinus nigra subsp. nigra", "Pinus nigra var. corsicana", "Pinus pinaster", "Fagus sylvatica"]
        @test FDE.match_species(taxa, "fagus sylvatica") == ["Fagus sylvatica"]
        @test FDE.match_species(taxa, "Pinus nigra") == ["Pinus nigra subsp. nigra", "Pinus nigra var. corsicana"]
        @test_throws ArgumentError FDE.match_species(taxa, "Pinus sylvestris")
    end

    @testset "Download (cached files are reused)" begin
        dir = download_data(country="France")
        @test dir == joinpath(FIXTURE_ROOT, "france")
        @test isfile(joinpath(dir, "inventory", "ARBRE.csv"))
    end

    @testset "Download validation and mirrors" begin
        d = mktempdir()
        html = joinpath(d, "maintenance.html")
        write(html, "﻿<!DOCTYPE HTML>\n<html><body>Site en maintenance</body></html>")
        zip = joinpath(d, "good.zip")
        write(zip, b"PK\x03\x04 rest of a zip")
        url(path) = "file://" * replace(path, "\\" => "/")
        @test FDE.is_html(html) && !FDE.is_zip(html)
        @test FDE.is_zip(zip) && !FDE.is_html(zip)

        # an HTML answer is rejected and nothing is cached
        dest = joinpath(d, "out", "export.zip")
        @test_throws ErrorException FDE.fetch_file(url(html), dest; validate=FDE.is_zip)
        @test !isfile(dest) && !isfile(dest * ".part")
        # the mirrors are tried in order
        @test FDE.fetch_file([url(html), url(joinpath(d, "missing.zip")), url(zip)], dest; validate=FDE.is_zip) == dest
        @test read(dest) == read(zip)
        # an invalid cached file (e.g. a maintenance page saved by an older version) is replaced
        cp(html, dest; force=true)
        FDE.fetch_file(url(zip), dest; validate=FDE.is_zip)
        @test FDE.is_zip(dest)
    end

    @testset "Forest cover" begin
        cover = FDE.cached_forest_cover(FDE.get_country("France"))
        for d in FIX_DEPS
            r = only(eachrow(cover[cover.department_code .== d.code, :]))
            exp = FIX_COVER[d.code]
            @test r.broadleaved ≈ exp.broadleaved rtol = 1e-6
            @test r.coniferous ≈ exp.coniferous rtol = 1e-6
            @test r.mixed ≈ exp.mixed rtol = 1e-6
            @test r.land_area > 300_000   # a 1° × 0.5° rectangle is ~ 400 000 ha
        end
    end

    df = process_data(country="France")
    forest = Dict(d.code => sum(values(FIX_COVER[d.code])) for d in FIX_DEPS)

    @testset "Processed table" begin
        @test names(df) == string.(FDE.OUTPUT_COLS)
        @test sort(unique(df.level)) == ["country", "department", "region"]
        @test sort(unique(df.year)) == collect(FIX_CAMPAIGNS)
        @test Set(df.specie) == Set(["Fagus sylvatica", "Abies alba", "Unidentified (IGN code 25E3)"])
        @test all(df.country .== "France")
        @test all(df.vol .>= 0) && all(df.ha .>= 0)
    end

    sel(level, year, specie; dep=missing) = only(eachrow(filter(r -> r.level == level && r.year == year &&
                                                                          r.specie == specie && isequal(r.department_code, dep), df)))

    @testset "Stock and area" begin
        for (k, d) in enumerate(FIX_DEPS), c in (2014, 2020)
            r = sel("department", c, "Fagus sylvatica"; dep=d.code)
            plot_vol = [14.15 * cr(fix_age(c, k, j, 1), FIX_GROWTH["09"]) for j in FIX_PLOTS]
            @test r.vol ≈ forest[d.code] * mean(plot_vol)
            ba(w, c13) = w * c13^2 / 4π
            share = ba(14.15, 1.2) / (ba(14.15, 1.2) + ba(39.29, 0.9) + ba(88.4, 0.5))
            @test r.ha ≈ forest[d.code] * share
            @test r.vol_ha ≈ r.vol / r.ha
            @test r.n_plots == length(FIX_PLOTS)
            @test r.biological_growth > 0
        end
        # species areas add up to the forest area
        d88 = filter(r -> r.level == "department" && r.year == 2016 && r.department_code == "88", df)
        @test sum(d88.ha) ≈ forest["88"]
    end

    @testset "Harvest and mortality" begin
        for (k, d) in enumerate(FIX_DEPS), y in (2019, 2020)
            c = y - 5
            vol1(j) = 39.29 * cr(fix_age(c, k, j, 2), FIX_GROWTH["61"]) / 5
            r = sel("department", y, "Abies alba"; dep=d.code)
            @test r.harvested_volumes ≈ forest[d.code] * vol1(1) / length(FIX_PLOTS)
            @test r.mortality_volumes ≈ forest[d.code] * vol1(2) / length(FIX_PLOTS)
            @test r.mortality_pc ≈ 100 * r.mortality_volumes / r.vol
            @test r.share_bio_growth_harvested ≈ r.harvested_volumes / r.biological_growth
            f = sel("department", y, "Fagus sylvatica"; dep=d.code)
            @test f.harvested_volumes == 0 && f.mortality_volumes == 0   # dead-at-first-visit tree is ignored
        end
        # no revisits before 2019 in the fixture
        @test all(ismissing, filter(r -> r.year < 2019, df).harvested_volumes)
        @test all(ismissing, filter(r -> r.year < 2019, df).mortality_pc)
    end

    @testset "Aggregation" begin
        for y in FIX_CAMPAIGNS, s in ("Fagus sylvatica", "Abies alba")
            deps = filter(r -> r.level == "department" && r.year == y && r.specie == s, df)
            reg = filter(r -> r.level == "region" && r.year == y && r.specie == s, df)
            ctry = sel("country", y, s)
            @test only(reg.region) == "Grand Est"
            @test only(reg.vol) ≈ sum(deps.vol)
            @test ctry.vol ≈ sum(deps.vol)
            @test ctry.ha ≈ sum(deps.ha)
            @test ctry.vol_ha ≈ ctry.vol / ctry.ha
            @test ctry.n_plots == sum(deps.n_plots)
            if y >= 2019
                @test ctry.harvested_volumes ≈ sum(deps.harvested_volumes)
            end
        end
        tot = FDE.summarise(filter(r -> r.level == "country", df), [:year])
        @test nrow(tot) == length(FIX_CAMPAIGNS)
    end

    @testset "Pooling window" begin
        w = process_data(country="France", window=2)
        r1 = sel("department", 2016, "Fagus sylvatica"; dep="88")
        r0 = sel("department", 2015, "Fagus sylvatica"; dep="88")
        rw = only(eachrow(filter(r -> r.level == "department" && r.year == 2016 && r.specie == "Fagus sylvatica" &&
                                     r.department_code == "88", w)))
        @test rw.vol ≈ (r0.vol + r1.vol) / 2
        @test_throws ArgumentError process_data(country="France", window=0)
    end

    @testset "Available species" begin
        sp = available_species(country="France")
        @test first(sp.specie) in ("Fagus sylvatica", "Abies alba")
        @test "Abies alba" in sp.specie
    end

    @testset "Growth model" begin
        t = collect(10.0:10:200)
        p = [3.0, 0.03, 3.0]
        params, se, rmse, r2 = FDE.fit_chapman_richards(t, FDE.chapman_richards(t, p))
        @test params ≈ p rtol = 1e-3
        @test r2 > 0.999

        m = estimate_growth(country="France", specie="Fagus sylvatica")
        @test m isa GrowthModel
        @test m.params ≈ FIX_GROWTH["09"] rtol = 1e-3
        @test m.n == length(FIX_CAMPAIGNS) * length(FIX_DEPS) * length(FIX_PLOTS)
        @test m(50) ≈ cr(50, FIX_GROWTH["09"]) rtol = 1e-3
        @test predict(m, [50, 100]) ≈ cr.([50, 100], Ref(FIX_GROWTH["09"])) rtol = 1e-3
        # the current increment is the derivative of the curve
        @test current_increment(m, 60) ≈ (m(60.001) - m(59.999)) / 0.002 rtol = 1e-4
        # at the culmination of the mean annual increment, MAI equals CAI
        a = culmination_age(m)
        @test mean_increment(m, a) ≈ current_increment(m, a) rtol = 0.02
        @test occursin("Chapman-Richards", sprint(show, MIME("text/plain"), m))

        m2 = estimate_growth(country="France", subregion="Grand Est", specie="abies alba", variable=:diameter)
        @test m2.variable == :diameter
        @test m2.params[1] > 0
        @test_throws ArgumentError estimate_growth(country="France", subregion="Vosges", specie="Abies alba")  # < 30 trees
        @test_throws ArgumentError estimate_growth(country="France", specie="Abies alba", variable=:weight)
        @test_throws ArgumentError estimate_growth(country="France", specie="Quercus robur")
    end

    @testset "Report" begin
        c = FDE.compare_years(DataFrame(year=2015:2020, x=[1.0, 2, 3, 4, 5, 6]), :x, 2020)
        @test (c.current, c.previous, c.average, c.n_average) == (6.0, 5.0, 3.0, 5)
        @test c.variability ≈ 1 / 3.5

        for sub in ("", "Grand Est", "Vosges")
            file = joinpath(mktempdir(), "report.pdf")
            @test create_report(country="France", subregion=sub, year=2020, filename=file) == file
            pdf = read(file, String)
            @test startswith(pdf, "%PDF")
            @test count(r"/Type\s*/Page\b", pdf) == 9
        end
        @test_throws ArgumentError create_report(country="France", year=1990, filename=tempname() * ".pdf")
    end
end

# Optional end-to-end test on the real data (large download): FDE_TEST_REAL_DATA=true
if get(ENV, "FDE_TEST_REAL_DATA", "false") == "true"
    @testset "Real data (France)" begin
        ENV[FDE.CACHE_ENV] = get(ENV, "FDE_REAL_DATA_DIR", mktempdir())
        df = process_data(country="France")
        tot = FDE.summarise(filter(r -> r.level == "country", df), [:year])
        @test all(100 .< tot.vol_ha .< 250)
        @test nrow(filter(r -> r.level == "department", df)) > 0
        @test estimate_growth(country="France", specie="Fagus sylvatica").r2 > 0.1
    end
end
