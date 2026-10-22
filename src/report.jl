# Multi-page PDF reports, drawn with CairoMakie on a single multi-page Cairo PDF surface.

const MK = CairoMakie

"Page size (A4 landscape, in PDF points)."
const PAGE = (842, 595)

"Report colors: surfaces and inks, categorical slots, emphasis grays and the sequential ramp."
const COLORS = (
    surface="#fcfcfb", text="#0b0b0b", text2="#52514e", muted="#8a8984", grid="#e8e7e3", axis="#c9c8c3",
    nodata="#e8e7e3", series=["#2a78d6", "#eb6834", "#1baf7a"], gray_light="#cfcec9", gray_mid="#9b9a95",
    sequential=["#cde2fb", "#9ec5f4", "#6da7ec", "#3987e5", "#256abf", "#184f95", "#0d366b"],
)

"Indicators shown in the report: column, label, unit and kind of unit scaling."
const INDICATORS = [
    (col=:vol, label="Growing stock", unit="m³", scale=:yes),
    (col=:ha, label="Forest area", unit="ha", scale=:yes),
    (col=:vol_ha, label="Growing stock per hectare", unit="m³/ha", scale=:no),
    (col=:biological_growth, label="Biological growth", unit="m³/yr", scale=:yes),
    (col=:harvested_volumes, label="Harvest", unit="m³/yr", scale=:yes),
    (col=:mortality_volumes, label="Natural mortality", unit="m³/yr", scale=:yes),
    (col=:mortality_pc, label="Mortality rate", unit="%/yr", scale=:no),
    (col=:share_bio_growth_harvested, label="Harvest / growth", unit="ratio", scale=:no),
]

report_colormap() = MK.cgrad(COLORS.sequential)

"Divisor and unit label that keep the values of `x` readable (e.g. million m³)."
function unit_scale(x, unit)
    m = maximum(abs, skipmissing(x); init=0.0)
    m >= 1e6 && return (1e6, "million " * unit)
    m >= 1e4 && return (1e3, "thousand " * unit)
    return (1.0, unit)
end

"Format a number for tables and labels."
function fmt(x; digits=nothing)
    (ismissing(x) || !isfinite(x)) && return "–"
    d = something(digits, abs(x) >= 100 ? 0 : abs(x) >= 10 ? 1 : 2)
    s = @sprintf("%.*f", d, x)
    int, dec = occursin('.', s) ? split(s, '.') : (s, "")
    int = replace(int, r"(?<=\d)(?=(\d{3})+$)" => " ")
    return isempty(dec) ? int : "$int.$dec"
end

"Value of column `col` in year `y` of the yearly table `t` (or `missing`)."
function value_at(t, col, y)
    i = findfirst(==(y), t.year)
    return isnothing(i) ? missing : t[i, col]
end

"""
$(TYPEDSIGNATURES)

Compare the value of `col` in `year` with the previous year and the average of the five
previous years, and measure its temporal variability as the mean absolute year-on-year
relative change over the whole series.
"""
function compare_years(t, col, year)
    cur = value_at(t, col, year)
    prev = value_at(t, col, year - 1)
    past = collect(skipmissing(value_at(t, col, y) for y in year-5:year-1))
    avg = isempty(past) ? missing : mean(past)
    s = sort(dropmissing(select(t, :year, col)), :year)
    v = s[!, col]
    consecutive = [i for i in 2:length(v) if s.year[i] == s.year[i-1] + 1]
    level = isempty(v) ? 0.0 : mean(abs, v)
    variability = isempty(consecutive) || iszero(level) ? missing :
                  mean(abs(v[i] - v[i-1]) for i in consecutive) / level
    return (current=cur, previous=prev, average=avg, n_average=length(past), variability=variability)
end

function report_theme()
    C = COLORS
    MK.Theme(
        fontsize=9, backgroundcolor=C.surface, textcolor=C.text,
        Axis=(backgroundcolor=C.surface, xgridcolor=C.grid, ygridcolor=C.grid, xgridwidth=0.5, ygridwidth=0.5,
            leftspinecolor=C.axis, bottomspinecolor=C.axis, topspinevisible=false, rightspinevisible=false,
            spinewidth=0.5, xtickcolor=C.axis, ytickcolor=C.axis, xticksize=3, yticksize=3,
            xticklabelcolor=C.text2, yticklabelcolor=C.text2, xlabelcolor=C.text2, ylabelcolor=C.text2,
            titlealign=:left, titlesize=10, titlefont=:bold, subtitlecolor=C.text2, subtitlesize=8,
            xticklabelsize=8, yticklabelsize=8),
        Colorbar=(ticklabelsize=7, ticklabelcolor=C.text2, labelcolor=C.text2, labelsize=8, spinewidth=0, ticksize=2,
            tickcolor=C.axis, width=8),
        Legend=(framevisible=false, labelcolor=C.text2, labelsize=8, patchsize=(10, 8)),
    )
end

"Create a report page with a header and a footer; returns the figure and the content layout."
function new_page(ctx, title::AbstractString; subtitle::AbstractString="")
    fig = MK.Figure(size=PAGE, figure_padding=(28, 28, 18, 16))
    header = MK.GridLayout(fig[1, 1])
    MK.Label(header[1, 1], title; fontsize=15, font=:bold, halign=:left, color=COLORS.text, tellwidth=false)
    isempty(subtitle) || MK.Label(header[2, 1], subtitle; fontsize=9, halign=:left, color=COLORS.text2, tellwidth=false)
    MK.rowgap!(header, 2)
    content = MK.GridLayout(fig[2, 1]; valign=:top)
    ctx.page[] += 1
    MK.Label(fig[3, 1], "$(ctx.scope_name) · $(ctx.year) · page $(ctx.page[])"; fontsize=7, halign=:right,
        color=COLORS.muted, tellwidth=false)
    MK.rowgap!(fig.layout, 10)
    MK.rowsize!(fig.layout, 2, MK.Auto(false))
    return fig, content
end

"Height / width ratio of the bounding box of `shapes`."
function map_ratio(shapes)
    xmin, ymin, xmax, ymax = bbox(Iterators.flatten(Iterators.flatten(s.polygons for s in shapes)))
    return min((ymax - ymin) / (xmax - xmin), 1.0)
end

"Axis set up for maps: equal aspect, no decorations."
function map_axis(pos; title="", subtitle="")
    ax = MK.Axis(pos; aspect=MK.DataAspect(), title, subtitle)
    MK.hidedecorations!(ax)
    MK.hidespines!(ax)
    return ax
end

"Draw `shapes` colored by `values` (NaN = no data) and add a colorbar at `cbpos`."
function choropleth!(ax, cbpos, shapes, values; label="", colorrange=nothing, highlight=nothing)
    v = Float64[ismissing(x) ? NaN : x for x in values]
    finite = filter(isfinite, v)
    cr = something(colorrange, isempty(finite) ? (0.0, 1.0) :
                               (minimum(finite) == maximum(finite) ? (0.0, maximum(finite) + 1) : extrema(finite)))
    p = MK.poly!(ax, [to_makie(s) for s in shapes]; color=v, colormap=report_colormap(), colorrange=cr,
        nan_color=COLORS.nodata, strokecolor=COLORS.surface, strokewidth=0.6)
    if !isnothing(highlight)
        MK.poly!(ax, to_makie(highlight); color=:transparent, strokecolor=COLORS.text, strokewidth=1.5)
    end
    MK.Colorbar(cbpos, p; label, vertical=false, flipaxis=false, height=6, width=MK.Relative(0.8))
    return p
end

# ----------------------------------------------------------------------------------------
# Context

"""
Gather everything the report pages need: processed data restricted to the scope, yearly
totals, map units and their values.
"""
function report_context(plugin, sub, year, window)
    df = process_data(; country=country_name(plugin), window)
    years = sort(unique(df.year))
    year in years || throw(ArgumentError("No data for year $year. Available years: $(first(years))–$(last(years))."))
    dir = data_dir(plugin)
    lvl = String(sub.level)
    scope = df[(df.level .== lvl) .& in_subregion(df, sub), :]
    nrow(scope) > 0 || throw(ArgumentError("No inventory data for $(sub.name)."))
    totals = sort!(summarise(scope, [:year]), :year)
    units = admin_units(plugin)

    # map units: the regions of the country, or the departments of the region
    if sub.level == :country
        map_shapes = boundaries(plugin, dir, :region)
        map_rows = df[df.level .== "region", :]
        map_key = :region_code
        highlight = nothing
    else
        codes = units.department_code[units.region .== sub.region]
        map_shapes = filter(s -> s.code in codes, boundaries(plugin, dir, :department))
        map_rows = df[(df.level .== "department") .& coalesce.(df.region .== sub.region, false), :]
        map_key = :department_code
        highlight = sub.level == :department ? only(filter(s -> s.code == sub.code, map_shapes)) : nothing
    end
    dep_shapes = boundaries(plugin, dir, :department)
    scope_codes = sub.level == :country ? units.department_code :
                  sub.level == :region ? units.department_code[units.region .== sub.region] : [sub.code]
    scope_shape_list = filter(s -> s.code in scope_codes, dep_shapes)

    return (plugin=plugin, sub=sub, year=year, window=window, df=df, years=years, scope=scope, totals=totals,
        units=units, dir=dir, map_shapes=map_shapes, map_rows=map_rows, map_key=map_key, highlight=highlight,
        dep_shapes=dep_shapes, scope_shapes=scope_shape_list,
        scope_name=sub.level == :country ? country_name(plugin) : "$(sub.name) ($(country_name(plugin)))",
        page=Ref(0))
end

"Species of the scope in `year`, sorted by decreasing growing stock."
function species_ranking(ctx)
    s = ctx.scope[ctx.scope.year .== ctx.year, :]
    s = summarise(s, [:specie])
    return sort!(filter!(r -> r.vol > 0, s), :vol; rev=true)
end

# ----------------------------------------------------------------------------------------
# Pages

function page_title(ctx)
    fig, g = new_page(ctx, "Forest resources of $(ctx.scope_name), $(ctx.year)";
        subtitle="National forest inventory indicators, generated by ForestDataExplorerExample.jl on $(Dates.today())" *
                 (ctx.window > 1 ? " · estimates pooled over $(ctx.window)-year windows" : ""))
    # locator map
    ax = map_axis(g[1:2, 1]; title="Location")
    country = boundaries(ctx.plugin, ctx.dir, :country)
    MK.poly!(ax, to_makie.(ctx.dep_shapes); color=COLORS.grid, strokecolor=COLORS.surface, strokewidth=0.4)
    MK.poly!(ax, to_makie.(ctx.scope_shapes); color=COLORS.series[1], strokecolor=COLORS.surface, strokewidth=0.4)
    MK.poly!(ax, to_makie.(country); color=:transparent, strokecolor=COLORS.gray_mid, strokewidth=0.6)

    # key figures table
    t = MK.GridLayout(g[1, 2]; tellheight=false, valign=:top)
    MK.Label(t[1, 1:6], "Key figures (all species)"; font=:bold, fontsize=10, halign=:left)
    heads = ["Indicator", "Unit", string(ctx.year), string(ctx.year - 1), "Mean $(ctx.year-5)–$(ctx.year-1)", "Variability"]
    for (j, h) in enumerate(heads)
        MK.Label(t[2, j], h; font=:bold, fontsize=8, color=COLORS.text2, halign=j <= 2 ? :left : :right)
    end
    for (i, ind) in enumerate(INDICATORS)
        c = compare_years(ctx.totals, ind.col, ctx.year)
        div, u = ind.scale == :yes ? unit_scale(ctx.totals[!, ind.col], ind.unit) : (1.0, ind.unit)
        high = !ismissing(c.variability) && c.variability > ctx.cv_threshold
        cells = [ind.label, u, fmt(safe_div(c.current, div)), fmt(safe_div(c.previous, div)),
            fmt(safe_div(c.average, div)), ismissing(c.variability) ? "–" : @sprintf("%.1f %%%s", 100c.variability, high ? " ▲" : "")]
        for (j, cell) in enumerate(cells)
            MK.Label(t[i+2, j], cell; fontsize=8.5, halign=j <= 2 ? :left : :right,
                color=j == 3 ? COLORS.text : COLORS.text2, font=j == 3 ? :bold : :regular)
        end
    end
    MK.rowgap!(t, 5)
    MK.colgap!(t, 12)
    n = nrow(ctx.totals)
    note = "Variability: mean absolute year-on-year change relative to the mean level over $(first(ctx.totals.year))–" *
           "$(last(ctx.totals.year)). ▲ marks the variables above $(round(Int, 100ctx.cv_threshold)) %, " *
           "compared with the previous years in this report.\n" *
           "Harvest and mortality are measured on plots revisited after five years (from 2015). " *
           "Areas come from the land cover map; see the methodology page."
    MK.Label(t[length(INDICATORS)+3, 1:6], note; fontsize=7, color=COLORS.muted, halign=:left, justification=:left,
        word_wrap=true, tellwidth=false)

    # main species
    sp = first(species_ranking(ctx), 6)
    share = 100 .* sp.vol ./ ctx.totals.vol[ctx.totals.year .== ctx.year]
    n = nrow(sp)
    ax2 = MK.Axis(g[2, 2]; title="Main species", subtitle="share of the growing stock in $(ctx.year), %",
        yticks=(1:n, sp.specie), yreversed=true, ygridvisible=false, xticks=MK.WilkinsonTicks(4))
    MK.barplot!(ax2, 1:n, share; direction=:x, color=COLORS.series[1], gap=0.35, strokewidth=0)
    MK.text!(ax2, share, 1:n; text=[" " * fmt(x; digits=1) for x in share], align=(:left, :center), fontsize=8,
        color=COLORS.text2)
    MK.xlims!(ax2, 0, 1.25 * maximum(share; init=1.0))
    MK.rowsize!(g, 2, MK.Relative(0.38))
    MK.colsize!(g, 1, MK.Relative(0.4))
    return fig
end

function page_maps(ctx)
    unitname = ctx.sub.level == :country ? "region" : "department"
    fig, g = new_page(ctx, "Indicators by $unitname, $(ctx.year)";
        subtitle="All species. " * (ctx.sub.level == :department ? "The department of the report is outlined. " : "") *
                 "Grey: no estimate.")
    rows = ctx.map_rows[ctx.map_rows.year .== ctx.year, :]
    vals = summarise(rows, [ctx.map_key])
    vals.growth_ha = safe_div.(vals.biological_growth, vals.ha)
    lookup(col) = [begin
        i = findfirst(==(s.code), vals[!, ctx.map_key])
        isnothing(i) ? missing : vals[i, col]
    end for s in ctx.map_shapes]
    panels = [(:vol_ha, "Growing stock per hectare", "m³/ha"),
        (:growth_ha, "Biological growth per hectare", "m³/ha/yr"),
        (:share_bio_growth_harvested, "Harvest / biological growth", "ratio"),
        (:mortality_pc, "Mortality rate", "% of growing stock per year")]
    for (k, (col, title, unit)) in enumerate(panels)
        cell = MK.GridLayout(g[1, k])
        ax = map_axis(cell[1, 1]; title)
        choropleth!(ax, cell[2, 1], ctx.map_shapes, lookup(col); label=unit, highlight=ctx.highlight)
        MK.rowsize!(cell, 1, MK.Aspect(1, map_ratio(ctx.map_shapes)))
        MK.rowgap!(cell, 4)
    end

    # the same values as a table
    names = Dict(s.code => s.name for s in ctx.map_shapes)
    t = MK.GridLayout(g[2, 1:4]; halign=:left, valign=:top, tellheight=false)
    MK.rowsize!(g, 2, MK.Auto(false))
    MK.rowgap!(g, 24)
    heads = [titlecase(unitname), "Stock (m³/ha)", "Growth (m³/ha/yr)", "Harvest / growth", "Mortality (%/yr)"]
    for (j, h) in enumerate(heads)
        MK.Label(t[1, j], h; font=:bold, fontsize=7.5, color=COLORS.text2, halign=j == 1 ? :left : :right)
    end
    ordered = sort([s.code for s in ctx.map_shapes]; by=c -> names[c])
    ncols = length(ordered) > 7 ? 2 : 1
    perblock = cld(length(ordered), ncols)
    for (i, code) in enumerate(ordered)
        block, row = divrem(i - 1, perblock)
        i0 = findfirst(==(code), vals[!, ctx.map_key])
        cells = [names[code]; isnothing(i0) ? fill("–", 4) : [fmt(vals[i0, c]) for c in (:vol_ha, :growth_ha, :share_bio_growth_harvested, :mortality_pc)]]
        for (j, cell) in enumerate(cells)
            highlight = !isnothing(ctx.highlight) && code == ctx.highlight.code
            MK.Label(t[row+2, j+6block], cell; fontsize=7.5, halign=j == 1 ? :left : :right,
                color=highlight ? COLORS.text : COLORS.text2, font=highlight ? :bold : :regular)
        end
    end
    if ncols == 2
        for (j, h) in enumerate(heads)
            MK.Label(t[1, j+6], h; font=:bold, fontsize=7.5, color=COLORS.text2, halign=j == 1 ? :left : :right)
        end
        MK.colsize!(t, 6, MK.Fixed(30))
    end
    MK.rowgap!(t, 2)
    MK.colgap!(t, 10)
    return fig
end

function page_cover(ctx)
    fig, g = new_page(ctx, "Inventory plots and forest cover";
        subtitle="Left: growing stock per hectare measured on the inventory plots of $(ctx.year) (all species). " *
                 "Right: forest cover from the land cover map.")
    # plot dot map
    obs = cached_plot_observations(ctx.plugin)
    obs = obs[(obs.year .== ctx.year) .& in_subregion(obs, ctx.sub), :]
    cell = MK.GridLayout(g[1, 1]; valign=:top)
    ax = map_axis(cell[1, 1]; title="Inventory plots, $(ctx.year)", subtitle="$(nrow(obs)) forest plots")
    MK.poly!(ax, to_makie.(ctx.scope_shapes); color=COLORS.grid, strokecolor=COLORS.surface, strokewidth=0.6)
    if nrow(obs) > 0
        hi = max(quantile(obs.vol_ha, 0.98), 1.0)
        sc = MK.scatter!(ax, obs.x, obs.y; color=clamp.(obs.vol_ha, 0, hi), colormap=report_colormap(),
            colorrange=(0, hi), markersize=ctx.sub.level == :country ? 3 : 6, strokewidth=0)
        MK.Colorbar(cell[2, 1], sc; label="m³/ha (top 2 % capped)", vertical=false, flipaxis=false, height=6,
            width=MK.Relative(0.8))
    end
    MK.rowsize!(cell, 1, MK.Aspect(1, map_ratio(ctx.scope_shapes)))

    # forest cover share map
    cover = cached_forest_cover(ctx.plugin)
    cover.forest = cover.broadleaved .+ cover.coniferous .+ cover.mixed
    shapes = ctx.sub.level == :country ? ctx.dep_shapes :
             filter(s -> s.code in ctx.units.department_code[ctx.units.region .== ctx.sub.region], ctx.dep_shapes)
    share = [begin
        i = findfirst(==(s.code), cover.department_code)
        isnothing(i) ? missing : 100 * cover.forest[i] / cover.land_area[i]
    end for s in shapes]
    cell2 = MK.GridLayout(g[1, 2]; valign=:top)
    ax2 = map_axis(cell2[1, 1]; title="Forest cover by department")
    choropleth!(ax2, cell2[2, 1], shapes, share; label="% of land area", colorrange=(0, max(maximum(skipmissing(share); init=1.0), 1.0)),
        highlight=ctx.highlight)
    MK.rowsize!(cell2, 1, MK.Aspect(1, map_ratio(shapes)))

    # forest types in scope
    c = cover[in.(cover.department_code, Ref([s.code for s in ctx.scope_shapes])), :]
    types = ["Broadleaved", "Coniferous", "Mixed"]
    areas = [sum(c.broadleaved), sum(c.coniferous), sum(c.mixed)]
    div, u = unit_scale(areas, "ha")
    ax3 = MK.Axis(g[1, 3]; title="Forest area by type", subtitle=ctx.sub.name, xlabel=u, yticks=(1:3, types),
        yreversed=true, ygridvisible=false, height=150, valign=:top, xticks=MK.WilkinsonTicks(3))
    MK.barplot!(ax3, 1:3, areas ./ div; direction=:x, color=COLORS.series, gap=0.35, strokewidth=0)
    total = sum(areas)
    MK.text!(ax3, areas ./ div, 1:3; text=[" $(fmt(a / div)) ($(round(Int, 100a / total)) %)" for a in areas],
        align=(:left, :center), fontsize=8, color=COLORS.text2)
    MK.xlims!(ax3, 0, 1.6 * maximum(areas) / div)
    MK.colsize!(g, 3, MK.Relative(0.22))
    MK.colgap!(g, 24)
    return fig
end

function page_timeseries(ctx)
    fig, g = new_page(ctx, "Trends $(first(ctx.totals.year))–$(last(ctx.totals.year))";
        subtitle="All species. The shaded band marks the five years before $(ctx.year); the dot marks $(ctx.year).")
    cols = [:vol, :vol_ha, :biological_growth, :harvested_volumes, :mortality_pc, :share_bio_growth_harvested]
    t = ctx.totals
    for (k, col) in enumerate(cols)
        ind = only(filter(i -> i.col == col, INDICATORS))
        div, u = ind.scale == :yes ? unit_scale(t[!, col], ind.unit) : (1.0, ind.unit)
        ax = MK.Axis(g[fldmod1(k, 3)...]; title=ind.label, subtitle=u, xticks=MK.WilkinsonTicks(6; k_min=4))
        MK.vspan!(ax, ctx.year - 5.5, ctx.year - 0.5; color=(COLORS.grid, 0.8))
        ok = .!ismissing.(t[!, col])
        x, y = t.year[ok], Float64.(t[ok, col]) ./ div
        isempty(x) && continue
        MK.lines!(ax, x, y; color=COLORS.series[1], linewidth=2)
        cur = value_at(t, col, ctx.year)
        if !ismissing(cur)
            MK.scatter!(ax, [ctx.year], [cur / div]; color=COLORS.series[1], markersize=8, strokecolor=COLORS.surface,
                strokewidth=2)
            MK.text!(ax, ctx.year, cur / div; text=fmt(cur / div), align=(:right, :bottom), offset=(-4, 4), fontsize=8,
                color=COLORS.text)
        end
        lo, hi = extrema(y)
        pad = max(hi - lo, abs(hi) * 0.05, 1e-9) * 0.15
        MK.ylims!(ax, lo - pad, hi + pad)
        MK.xlims!(ax, first(ctx.years) - 0.5, last(ctx.years) + 0.5)
    end
    return fig
end

function page_comparison(ctx)
    fig, g = new_page(ctx, "$(ctx.year) compared with the previous year and the previous five years";
        subtitle="Variables with high temporal variability (mean absolute year-on-year change above " *
                 "$(round(Int, 100ctx.cv_threshold)) %), all species. 5-year mean: $(ctx.year-5)–$(ctx.year-1).")
    flagged = filter(INDICATORS) do ind
        c = compare_years(ctx.totals, ind.col, ctx.year)
        !ismissing(c.variability) && c.variability > ctx.cv_threshold && !ismissing(c.current)
    end
    top = MK.GridLayout(g[1, 1])
    ncols = min(length(flagged), 4)
    labels = ["5-year mean", string(ctx.year - 1), string(ctx.year)]
    colors = [COLORS.gray_mid, COLORS.gray_light, COLORS.series[1]]
    if isempty(flagged)
        MK.Label(top[1, 1], "No variable exceeds the variability threshold."; color=COLORS.text2)
    end
    for (k, ind) in enumerate(flagged)
        c = compare_years(ctx.totals, ind.col, ctx.year)
        div, u = ind.scale == :yes ? unit_scale(ctx.totals[!, ind.col], ind.unit) : (1.0, ind.unit)
        v = [c.average, c.previous, c.current]
        y = [ismissing(x) ? 0.0 : x / div for x in v]
        row, col = fldmod1(k, max(ncols, 1))
        ax = MK.Axis(top[2row-1, col]; title=ind.label, subtitle=u, xticks=(1:3, labels), xgridvisible=false,
            xticklabelsize=7)
        MK.barplot!(ax, 1:3, y; color=colors, gap=0.3, strokewidth=0)
        MK.text!(ax, 1:3, y; text=[ismissing(x) ? "n/a" : fmt(x / div) for x in v], align=(:center, :bottom),
            offset=(0, 2), fontsize=8, color=COLORS.text)
        if !ismissing(c.average) && !iszero(c.average)
            MK.Label(top[2row, col], @sprintf("%+.1f %% vs %d-year mean", 100 * (c.current / c.average - 1), c.n_average);
                fontsize=8, color=COLORS.text2, tellwidth=false)
        end
        MK.ylims!(ax, 0, 1.2 * max(maximum(y), 1e-9))
    end

    # harvest / growth by species: year vs 5-year mean (dumbbell)
    sp = first(species_ranking(ctx), 10)
    rows = ctx.scope[in.(ctx.scope.specie, Ref(sp.specie)), :]
    byyear = summarise(rows, [:specie, :year])
    cur = Float64[]
    avg = Float64[]
    for s in sp.specie
        t = sort(byyear[byyear.specie .== s, :], :year)
        c = compare_years(t, :share_bio_growth_harvested, ctx.year)
        push!(cur, coalesce(c.current, NaN))
        push!(avg, coalesce(c.average, NaN))
    end
    n = length(sp.specie)
    ax = MK.Axis(g[2, 1]; title="Harvest / biological growth of the main species",
        subtitle="Grey: mean $(ctx.year-5)–$(ctx.year-1); blue: $(ctx.year). A ratio above 1 means more volume harvested than grown.",
        yticks=(1:n, sp.specie), yreversed=true, ygridvisible=false)
    MK.vlines!(ax, [1.0]; color=COLORS.axis, linewidth=0.8)
    for i in 1:n
        (isfinite(cur[i]) && isfinite(avg[i])) && MK.lines!(ax, [avg[i], cur[i]], [i, i]; color=COLORS.gray_light, linewidth=2)
    end
    MK.scatter!(ax, avg, 1:n; color=COLORS.gray_mid, markersize=8, strokecolor=COLORS.surface, strokewidth=1.5)
    MK.scatter!(ax, cur, 1:n; color=COLORS.series[1], markersize=9, strokecolor=COLORS.surface, strokewidth=1.5)
    right = [isfinite(c) ? (isfinite(a) ? max(a, c) : c) : NaN for (c, a) in zip(cur, avg)]
    MK.text!(ax, right, 1:n; text=[isfinite(x) ? fmt(x) : "" for x in cur], align=(:left, :center), offset=(8, 0),
        fontsize=7.5, color=COLORS.text)
    MK.xlims!(ax, 0, 1.12 * max(maximum(filter(isfinite, [cur; avg]); init=1.0), 1.0))
    MK.rowsize!(g, 1, MK.Relative(length(flagged) > 4 ? 0.62 : 0.42))
    return fig
end

function page_species(ctx)
    sp = first(species_ranking(ctx), 15)
    fig, g = new_page(ctx, "Species composition, $(ctx.year)"; subtitle="The $(nrow(sp)) species with the largest growing stock.")
    n = nrow(sp)
    sp.growth_rate = 100 .* safe_div.(sp.biological_growth, sp.vol)
    panels = [(:vol, "Growing stock", "m³", true), (:ha, "Forest area", "ha (basal-area share)", true),
        (:vol_ha, "Stock per hectare", "m³/ha", false), (:growth_rate, "Growth rate", "% of stock per year", false)]
    for (k, (col, title, unit, scale)) in enumerate(panels)
        v = Float64[coalesce(x, NaN) for x in sp[!, col]]
        div, u = scale ? unit_scale(v, unit) : (1.0, unit)
        ax = MK.Axis(g[1, k]; title, subtitle=u, yticks=(1:n, k == 1 ? sp.specie : fill("", n)), yreversed=true,
            ygridvisible=false, yticksvisible=k == 1, xticks=MK.WilkinsonTicks(3))
        MK.barplot!(ax, 1:n, v ./ div; direction=:x, color=COLORS.series[1], gap=0.3, strokewidth=0)
        MK.text!(ax, v ./ div, 1:n; text=[" " * fmt(x / div) for x in v], align=(:left, :center), fontsize=7,
            color=COLORS.text2)
        MK.xlims!(ax, 0, 1.4 * maximum(filter(isfinite, v ./ div); init=1.0))
        k > 1 && MK.hideydecorations!(ax; grid=false)
    end
    MK.colsize!(g, 1, MK.Relative(0.37))
    return fig
end

"Fit the growth model of `specie`, falling back to larger areas when data are scarce."
function report_growth_model(ctx, specie)
    candidates = ctx.sub.level == :country ? [""] :
                 ctx.sub.level == :region ? [ctx.sub.name, ""] : [ctx.sub.name, ctx.sub.region, ""]
    for area in candidates
        try
            return estimate_growth(; country=country_name(ctx.plugin), subregion=area, specie, min_obs=30)
        catch err
            err isa ArgumentError || rethrow()
        end
    end
    return nothing
end

function page_growth(ctx)
    sp = first(species_ranking(ctx), 6).specie
    fig, g = new_page(ctx, "Tree growth models of the main species";
        subtitle="Chapman-Richards fit of tree volume on age at 1.30 m, V = a(1 − e^(−b·age))^c, on the trees cored " *
                 "by the inventory (all years). Grey dots: observations; blue line: fitted model.")
    for (k, s) in enumerate(sp)
        m = report_growth_model(ctx, s)
        cell = g[fldmod1(k, 3)...]
        if isnothing(m)
            ax = MK.Axis(cell; title=s, subtitle="not enough aged trees")
            MK.hidedecorations!(ax)
            continue
        end
        area = isempty(m.subregion) ? country_name(ctx.plugin) : m.subregion
        ax = MK.Axis(cell; title=s, subtitle="$area · n = $(m.n) · R² = $(fmt(m.r2))", xlabel="age at 1.30 m (years)",
            ylabel="volume (m³)", titlesize=9)
        maxage = quantile(m.ages, 0.995)
        keep = m.ages .<= maxage
        idx = findall(keep)
        length(idx) > 4000 && (idx = idx[round.(Int, range(1, length(idx); length=4000))])
        MK.scatter!(ax, m.ages[idx], m.values[idx]; color=(COLORS.gray_mid, 0.35), markersize=3, strokewidth=0)
        ages = range(0, maxage; length=200)
        MK.lines!(ax, ages, predict(m, ages); color=COLORS.series[1], linewidth=2)
        a, b, c = m.params
        MK.text!(ax, 0.03, 0.97; space=:relative, align=(:left, :top), fontsize=7.5, color=COLORS.text2,
            text="a = $(fmt(a)), b = $(fmt(b; digits=4)), c = $(fmt(c))\n" * culmination_text(m))
        MK.ylims!(ax, 0, quantile(m.values[keep], 0.995) * 1.1)
        MK.xlims!(ax, 0, maxage)
    end
    return fig
end

function page_table(ctx)
    sp = first(species_ranking(ctx), 22)
    fig, g = new_page(ctx, "Indicators by species, $(ctx.year)"; subtitle="The $(nrow(sp)) species with the largest growing stock. – : not estimable.")
    vdiv, vu = unit_scale(sp.vol, "m³")
    hdiv, hu = unit_scale(sp.ha, "ha")
    fdiv, fu = unit_scale(coalesce.(sp.biological_growth, 0.0), "m³/yr")
    heads = ["Species", "Growing stock\n($vu)", "Area\n($hu)", "Stock/ha\n(m³/ha)", "Growth\n($fu)",
        "Harvest\n($fu)", "Mortality\n(%/yr)", "Harvest /\ngrowth", "Plots\n(n)"]
    for (j, h) in enumerate(heads)
        MK.Label(g[1, j], h; font=:bold, fontsize=8, color=COLORS.text2, halign=j == 1 ? :left : :right,
            justification=j == 1 ? :left : :right)
    end
    for (i, r) in enumerate(eachrow(sp))
        cells = [r.specie, fmt(r.vol / vdiv), fmt(r.ha / hdiv), fmt(r.vol_ha), fmt(safe_div(r.biological_growth, fdiv)),
            fmt(safe_div(r.harvested_volumes, fdiv)), fmt(r.mortality_pc), fmt(r.share_bio_growth_harvested),
            string(r.n_plots)]
        for (j, cell) in enumerate(cells)
            MK.Label(g[i+1, j], cell; fontsize=8, halign=j == 1 ? :left : :right, color=j == 1 ? COLORS.text : COLORS.text2,
                font=j == 1 ? :italic : :regular)
        end
    end
    MK.rowgap!(g, 3)
    MK.colgap!(g, 14)
    return fig
end

"Paragraphs of the methodology page: (heading, text)."
function methodology(ctx)
    pc = round(Int, 100ctx.cv_threshold)
    return [
        ("Growing stock", "Volume over bark of the stems of living trees (diameter at 1.30 m above 7.5 cm, up to a 7 cm top), " *
                          "measured on the inventory plots at their first visit. Plot values per hectare (sum of tree volume × weight) " *
                          "are averaged by department and multiplied by the forest area of the department."),
        ("Forest area", "Area of the forest classes of the land cover map (broadleaved, coniferous and mixed forest), assigned " *
                        "to departments by the centroid of each land cover polygon. The area of a species is the forest area " *
                        "multiplied by the share of the species in the basal area."),
        ("Biological growth", "Annual volume increment of the living trees, derived from the radial increment of the last five " *
                              "years (core samples), assuming that tree volume scales with diameter to a species-specific power " *
                              "estimated from the data. Trees without a measured increment receive the mean relative growth of " *
                              "their campaign, species and diameter class. The recruitment of new trees is not included."),
        ("Harvest and mortality", "Since 2015 every plot is revisited five years after its first visit and the fate of each tree " *
                                  "is recorded. The volume at the first visit of the trees found cut (harvest) or dead, broken or " *
                                  "windthrown (natural mortality) is divided by five to obtain an annual flow, attributed to the " *
                                  "year of the second visit. The mortality rate is the mortality volume divided by the growing stock."),
        ("Regions and country", "Department totals are summed and ratios are recomputed from the sums. Single-year indicators " *
                                "rest on a small sample of plots and carry a sampling error, larger for small areas, minor species " *
                                "and flows; the `window` option of `process_data` pools consecutive campaigns."),
        ("Growth models", "Chapman-Richards curves V(age) = a (1 − exp(−b·age))^c are fitted by nonlinear least squares on " *
                          "the living trees whose age at 1.30 m was measured. When a subregion has fewer than 30 aged trees " *
                          "of a species, the model of the enclosing region or of the country is shown."),
        ("Variability", "A variable is flagged as highly variable when its mean absolute year-on-year change exceeds $pc % of " *
                        "its mean level; for those variables the report compares the year with the previous year and with " *
                        "the mean of the five previous years."),
    ]
end

function page_methods(ctx)
    fig, g = new_page(ctx, "Methodology and data sources")
    paragraphs = methodology(ctx)
    half = cld(length(paragraphs), 2)
    for (col, items) in enumerate((paragraphs[1:half], paragraphs[half+1:end]))
        cell = MK.GridLayout(g[1, col]; valign=:top, tellheight=false)
        for (i, (head, body)) in enumerate(items)
            MK.Label(cell[2i-1, 1], head; font=:bold, fontsize=9, halign=:left, tellwidth=false)
            MK.Label(cell[2i, 1], body; fontsize=8.5, halign=:left, justification=:left, word_wrap=true,
                color=COLORS.text2, tellwidth=false)
        end
        if col == 2
            n = 2length(items)
            MK.Label(cell[n+1, 1], "Data sources"; font=:bold, fontsize=9, halign=:left, tellwidth=false)
            MK.Label(cell[n+2, 1], join("• " .* data_sources(ctx.plugin), "\n"); fontsize=8, halign=:left,
                justification=:left, word_wrap=true, color=COLORS.text2, tellwidth=false)
        end
        MK.rowgap!(cell, 4)
    end
    MK.colgap!(g, 30)
    return fig
end

"Write the figures `figs` as the pages of a single PDF file."
function save_pages(filename::AbstractString, figs)
    surface = Cairo.CairoPDFSurface(filename, PAGE...)
    config = MK.Makie.merge_screen_config(MK.ScreenConfig, Dict{Symbol,Any}(:pt_per_unit => 1.0, :px_per_unit => 1.0, :pdf_version => "1.4"))
    try
        for fig in figs
            MK.Makie.update_state_before_display!(fig)
            screen = MK.Screen(fig.scene, config, surface)
            MK.cairo_draw(screen, fig.scene)
            Cairo.show_page(screen.context)
        end
    finally
        Cairo.finish(surface)
    end
    return filename
end

"""
$(TYPEDSIGNATURES)

Create a multi-page PDF report on the forests of `country` (optionally restricted to a
`subregion`, i.e. a region or a department) for `year`, and save it to `filename`.

The report contains a locator map with the key figures, maps of the indicators by
region or department, a map of the inventory plots and of the forest cover, the trends
of the main indicators, a comparison of the most variable indicators with the previous
year and the average of the five previous years, the species composition, the growth
models ([`estimate_growth`](@ref)) of the main species, a table by species and a
methodology note.

Keyword arguments:
- `window`: passed to [`process_data`](@ref) (1 = single-year estimates);
- `cv_threshold`: variables whose mean absolute year-on-year relative change exceeds this
  value are compared with the previous year and the previous five years (default 5 %).

Returns the path of the created file.

# Example
```julia
create_report(country="France", subregion="Grand Est", year=2023)
```
"""
function create_report(; country::AbstractString, subregion::AbstractString="", year::Integer,
    filename::AbstractString="report_$(country)_$(subregion)_$(year).pdf", window::Integer=1, cv_threshold::Real=0.05)
    plugin = get_country(country)
    sub = resolve_subregion(plugin, subregion)
    ctx = merge(report_context(plugin, sub, year, window), (cv_threshold=cv_threshold,))
    figs = MK.with_theme(report_theme()) do
        [f(ctx) for f in (page_title, page_maps, page_cover, page_timeseries, page_comparison, page_species,
            page_growth, page_table, page_methods)]
    end
    mkpath(dirname(abspath(filename)))
    save_pages(filename, figs)
    @info "Report saved" filename
    return filename
end
