# Aggregation of totals across administrative levels and species.
#
# Plugins return additive totals at the department level. Ratios (per-hectare values,
# rates, shares) are never summed: they are always recomputed from aggregated totals.

"Additive columns of the processed table."
const TOTAL_COLS = [:vol, :ha, :harvested_volumes, :mortality_volumes, :biological_growth, :n_plots]

"Columns of the processed table, in output order."
const OUTPUT_COLS = [:year, :level, :country, :region_code, :region, :department_code, :department, :specie,
    :vol, :ha, :vol_ha, :harvested_volumes, :mortality_volumes, :mortality_pc,
    :biological_growth, :share_bio_growth_harvested, :n_plots]

"""
$(TYPEDSIGNATURES)

(Re)compute the ratio columns of `df` from its total columns:
`vol_ha = vol / ha`, `mortality_pc = 100 * mortality_volumes / vol` and
`share_bio_growth_harvested = harvested_volumes / biological_growth`.
"""
function add_ratios!(df::AbstractDataFrame)
    df.vol_ha = safe_div.(df.vol, df.ha)
    df.mortality_pc = safe_div.(100 .* df.mortality_volumes, df.vol)
    df.share_bio_growth_harvested = safe_div.(df.harvested_volumes, df.biological_growth)
    return df
end

"""
$(TYPEDSIGNATURES)

Sum the total columns of `df` by the columns `by` and recompute the ratios.
Typically used to obtain all-species totals, e.g. `summarise(df, [:year])`.
"""
function summarise(df::AbstractDataFrame, by)
    out = combine(groupby(df, by), (c => sum_skipmissing => c for c in TOTAL_COLS)...)
    return add_ratios!(out)
end

"""
$(TYPEDSIGNATURES)

Build the full processed table from department-level totals `dep` (as returned by a
plugin's `process` method): department rows plus region and country aggregates, with a
`level` column taking the values `"department"`, `"region"` and `"country"`.
"""
function aggregate_levels(dep::AbstractDataFrame, country::AbstractString)
    d = copy(dep)
    d.level .= "department"
    r = summarise(d, [:year, :region_code, :region, :specie])
    r.level .= "region"
    r.department_code .= missing
    r.department .= missing
    c = summarise(d, [:year, :specie])
    c.level .= "country"
    for col in (:region_code, :region, :department_code, :department)
        c[!, col] .= missing
    end
    add_ratios!(d)
    out = vcat(d, r, c; cols=:union)
    out.country .= country
    select!(out, OUTPUT_COLS)
    sort!(out, [:year, order(:level; by=l -> findfirst(==(l), ("country", "region", "department"))),
        :region, :department, :specie])
    return out
end
