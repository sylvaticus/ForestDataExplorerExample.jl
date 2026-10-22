# # Example: the forests of Grand Est
#
# This example walks through the whole workflow on the real French data: download,
# processing, a few analyses of the indicator table, a growth model and a PDF report.
#
# The first run downloads about 210 MB (inventory, land cover and borders) and processes
# them, which takes a few minutes; afterwards everything is read from the cache.

using ForestDataExplorerExample
using DataFrames
using CairoMakie

# ## Download and process the data
#
# `download_data` fetches and caches the raw data; `process_data` turns them into a tidy
# table of indicators by year, administrative level, unit and species.

download_data(country="France")
df = process_data(country="France")
first(df, 5)

# The table holds department rows plus their region and country aggregates:

combine(groupby(df, :level), nrow => :rows, :year => minimum => :first_year, :year => maximum => :last_year)

# ## National trends
#
# Ratios must never be summed: to get all-species values, sum the totals and recompute
# the ratios, which is what `ForestDataExplorerExample.summarise` does.

national = ForestDataExplorerExample.summarise(filter(r -> r.level == "country", df), [:year])
select(national, :year, :vol, :vol_ha, :biological_growth, :harvested_volumes, :mortality_pc,
    :share_bio_growth_harvested)

# Harvest and growth share the same unit, so they can share one axis:

flows = dropmissing(national, :harvested_volumes)
fig = Figure(size=(700, 340))
ax = Axis(fig[1, 1]; title="France: biological growth and harvest", ylabel="million m³/yr",
    xgridvisible=false)
lines!(ax, flows.year, flows.biological_growth ./ 1e6; color="#2a78d6", linewidth=2, label="Biological growth")
lines!(ax, flows.year, flows.harvested_volumes ./ 1e6; color="#eb6834", linewidth=2, label="Harvest")
text!(ax, last(flows.year), last(flows.biological_growth) / 1e6; text=" growth", align=(:left, :center), fontsize=11)
text!(ax, last(flows.year), last(flows.harvested_volumes) / 1e6; text=" harvest", align=(:left, :center), fontsize=11)
ylims!(ax, 0, nothing)
xlims!(ax, first(flows.year) - 0.5, last(flows.year) + 1.5)
axislegend(ax; position=:lb, framevisible=false)
fig

# ## Species of a region
#
# The main species of Grand Est in 2023, with their growth and harvest rates:

ge = filter(r -> r.level == "region" && r.region == "Grand Est" && r.year == 2023, df)
ge = sort(ge, :vol; rev=true)
select(first(ge, 10), :specie, :vol, :ha, :vol_ha, :biological_growth, :harvested_volumes,
    :mortality_pc, :share_bio_growth_harvested)

# Single-year estimates of small units are noisy. Pooling five campaigns, as the official
# IGN statistics do, smooths them:

df5 = process_data(country="France", window=5)
spruce = filter(r -> r.level == "region" && r.region == "Grand Est" && r.specie == "Picea abies subsp. abies", df5)
select(spruce, :year, :vol, :harvested_volumes, :mortality_pc)

# ## Growth model
#
# A Chapman-Richards curve of tree volume on age, for beech in Grand Est:

m = estimate_growth(country="France", subregion="Grand Est", specie="Fagus sylvatica")

# The model is callable and provides increments:

(volume_at_100=m(100), cai_at_100=current_increment(m, 100), mai_culmination=culmination_age(m))

#-

fig = Figure(size=(700, 360))
ax = Axis(fig[1, 1]; title="Fagus sylvatica, Grand Est", xlabel="age at 1.30 m (years)", ylabel="volume (m³)")
scatter!(ax, m.ages, m.values; color=("#9b9a95", 0.3), markersize=3)
lines!(ax, 0:250, m(0:250); color="#2a78d6", linewidth=2)
xlims!(ax, 0, 250)
ylims!(ax, 0, 8)
fig

# Species names are matched leniently: a binomial selects all its subspecies.

estimate_growth(country="France", specie="Pinus nigra").taxa

# ## Report
#
# Finally, a multi-page PDF report for the region:

create_report(country="France", subregion="Grand Est", year=2023, filename="report_grand_est_2023.pdf")

# The generated report: [report\_grand\_est\_2023.pdf](report_grand_est_2023.pdf).
