# Sigmoid (Chapman-Richards) growth models.

"Units of the variables that can be modelled with [`estimate_growth`](@ref)."
const GROWTH_UNITS = Dict(:volume => "m³", :diameter => "cm", :height => "m")

"""
    chapman_richards(t, p)

Chapman-Richards sigmoid growth function `y(t) = a (1 - exp(-b t))^c` with `p = [a, b, c]`:
`a` is the asymptote, `b` the rate and `c` the shape parameter (the curve is sigmoid, with
an inflection point, when `c > 1`; fits are constrained to `c ≥ 1`).
"""
chapman_richards(t, p) = @. p[1] * (1 - exp(-p[2] * t))^p[3]

"""
$(TYPEDEF)

A Chapman-Richards growth model `y(age) = a (1 - exp(-b age))^c` fitted with
[`estimate_growth`](@ref). The model is callable: `m(age)` returns the predicted value.

$(TYPEDFIELDS)
"""
struct GrowthModel
    "Country of the data."
    country::String
    "Subregion of the data (empty for the whole country)."
    subregion::String
    "Species requested."
    specie::String
    "Taxa (Latin names) included in the fit."
    taxa::Vector{String}
    "Modelled variable (`:volume`, `:diameter` or `:height`)."
    variable::Symbol
    "Parameters `[a, b, c]`."
    params::Vector{Float64}
    "Standard errors of the parameters (`NaN` when not computable)."
    stderrors::Vector{Float64}
    "Number of observations."
    n::Int
    "Root mean squared error of the fit."
    rmse::Float64
    "Coefficient of determination of the fit."
    r2::Float64
    "Observed ages (years at 1.30 m)."
    ages::Vector{Float64}
    "Observed values of `variable`."
    values::Vector{Float64}
end

"""
$(TYPEDSIGNATURES)

Predicted value of the growth model `m` at `age` (scalar or array).
"""
predict(m::GrowthModel, age) = chapman_richards(age, m.params)
(m::GrowthModel)(age) = predict(m, age)

"""
$(TYPEDSIGNATURES)

Current annual increment `dy/dt` of the growth model `m` at `age`.
"""
function current_increment(m::GrowthModel, age)
    a, b, c = m.params
    return @. a * b * c * exp(-b * age) * (1 - exp(-b * age))^(c - 1)
end

"""
$(TYPEDSIGNATURES)

Mean annual increment `y(t) / t` of the growth model `m` at `age`.
"""
mean_increment(m::GrowthModel, age) = predict(m, age) ./ age

"""
$(TYPEDSIGNATURES)

Age at which the mean annual increment culminates (where it equals the current annual
increment), searched between 1 and `maxage` years.
"""
function culmination_age(m::GrowthModel; maxage=500)
    ages = 1:0.5:maxage
    return ages[argmax(mean_increment(m, ages))]
end

"Description of the age of culmination of the mean annual increment of `m`."
function culmination_text(m::GrowthModel; maxage=500)
    age = culmination_age(m; maxage)
    age <= 1 && return "MAI decreasing from the start (no culmination)"
    age >= min(maximum(m.ages), maxage) && return "MAI culmination beyond the observed ages"
    return "MAI culmination ≈ $(round(Int, age)) years"
end

"Unit of the variable modelled by `m`."
unit(m::GrowthModel) = GROWTH_UNITS[m.variable]

function Base.show(io::IO, ::MIME"text/plain", m::GrowthModel)
    a, b, c = m.params
    sa, sb, sc = m.stderrors
    where_ = isempty(m.subregion) ? m.country : "$(m.subregion) ($(m.country))"
    println(io, "Chapman-Richards growth model: $(m.variable) [$(unit(m))] = a·(1 - exp(-b·age))^c")
    println(io, "  species:  $(m.specie)", m.taxa == [m.specie] ? "" : " ($(join(m.taxa, ", ")))")
    println(io, "  area:     $where_")
    @printf(io, "  a = %.4g (± %.2g), b = %.4g (± %.2g), c = %.4g (± %.2g)\n", a, sa, b, sb, c, sc)
    @printf(io, "  n = %d, RMSE = %.4g, R² = %.3f, ", m.n, m.rmse, m.r2)
    print(io, culmination_text(m))
end
Base.show(io::IO, m::GrowthModel) = print(io, "GrowthModel($(m.specie), $(m.variable), a=$(round(m.params[1]; sigdigits=4)), b=$(round(m.params[2]; sigdigits=4)), c=$(round(m.params[3]; sigdigits=4)))")

"""
$(TYPEDSIGNATURES)

Fit a Chapman-Richards curve to the observations `(t, y)` by nonlinear least squares and
return `(params, stderrors, rmse, r2)`. Starting values come from a grid search on the
rate and shape parameters, with the asymptote solved by linear least squares.
"""
function fit_chapman_richards(t::AbstractVector{<:Real}, y::AbstractVector{<:Real})
    t = Float64.(t)
    y = Float64.(y)
    best = (Inf, [maximum(y), 0.02, 2.0])
    for b in exp.(range(log(1e-3), log(0.3); length=25)), c in (1.0, 1.3, 1.6, 2.0, 3.0, 4.0, 6.0)
        f = @. (1 - exp(-b * t))^c
        a = sum(f .* y) / sum(abs2, f)
        sse = sum(abs2, y .- a .* f)
        sse < best[1] && (best = (sse, [a, b, c]))
    end
    p0 = best[2]
    lower = [0.0, 1e-5, 1.0]  # c ≥ 1: sigmoid shape with an inflection point
    upper = [5 * maximum(y), 2.0, 50.0]
    fit = curve_fit(chapman_richards, t, y, clamp.(p0, lower, upper); lower, upper)
    params = fit.param
    se = try
        stderror(fit)
    catch
        fill(NaN, 3)
    end
    res = y .- chapman_richards(t, params)
    rmse = sqrt(mean(abs2, res))
    r2 = 1 - sum(abs2, res) / sum(abs2, y .- mean(y))
    return params, se, rmse, r2
end

"""
$(TYPEDSIGNATURES)

Estimate a sigmoid (Chapman-Richards) growth function `y(age) = a (1 - exp(-b age))^c`
for the species `specie` (Latin name) in `country`, optionally restricted to a
`subregion` (a region or a department, by name or code).

The model is fitted on the living inventory trees whose age at 1.30 m was measured.
`variable` selects the modelled tree attribute: `:volume` (m³, default), `:diameter` (cm)
or `:height` (m). If `specie` is not an exact Latin name, all the taxa starting with it
are pooled (e.g. `"Pinus nigra"` includes its subspecies). An error is thrown when fewer
than `min_obs` observations are available.

Returns a [`GrowthModel`](@ref).

# Example
```julia
m = estimate_growth(country="France", subregion="Grand Est", specie="Fagus sylvatica")
m(100)                 # expected volume of a 100-year-old beech, m³
culmination_age(m)     # age of maximum mean annual increment
```
"""
function estimate_growth(; country::AbstractString, subregion::AbstractString="", specie::AbstractString,
    variable::Symbol=:volume, min_obs::Integer=30)
    haskey(GROWTH_UNITS, variable) || throw(ArgumentError("`variable` must be one of $(collect(keys(GROWTH_UNITS)))"))
    plugin = get_country(country)
    sub = resolve_subregion(plugin, subregion)
    obs = cached_growth_observations(plugin)
    if sub.level != :country
        obs = obs[coalesce.((sub.level == :region ? obs.region : obs.department) .== sub.name, false), :]
    end
    taxa = match_species(obs.specie, specie)
    obs = obs[in(taxa).(obs.specie), :]
    keep = .!ismissing.(obs[!, variable]) .& (obs[!, variable] .> 0) .& (obs.age .> 0)
    t, y = Float64.(obs.age[keep]), Float64.(obs[keep, variable])
    length(t) >= min_obs || throw(ArgumentError(
        "Only $(length(t)) observations of $specie in $(sub.name): at least $min_obs are needed. Try a larger subregion."))
    params, se, rmse, r2 = fit_chapman_richards(t, y)
    return GrowthModel(country_name(plugin), sub.level == :country ? "" : sub.name, specie, taxa, variable,
        params, se, length(t), rmse, r2, t, y)
end
