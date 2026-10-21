# Generic helpers: cache location, downloads, archives, string matching, arithmetic.

"Environment variable that, when set, overrides the default cache location."
const CACHE_ENV = "FOREST_DATA_EXPLORER_DIR"

"""
$(TYPEDSIGNATURES)

Return the directory where the data of `country` are cached, creating it if needed.

By default this is a [Scratch.jl](https://github.com/JuliaPackaging/Scratch.jl) space
owned by the package. Set the environment variable `FOREST_DATA_EXPLORER_DIR` to use a
different root folder (e.g. a shared network drive or the test fixtures).
"""
function data_dir(country::AbstractString)
    root = get(ENV, CACHE_ENV, "")
    root = isempty(root) ? get_scratch!(@__MODULE__, "data") : root
    return mkpath(joinpath(root, normalize_name(country)))
end

"""
$(TYPEDSIGNATURES)

Download `url` to `dest` atomically (via a temporary file), unless `dest` already exists
and `force` is false. Returns `dest`.
"""
function fetch_file(url::AbstractString, dest::AbstractString; force::Bool=false)
    if isfile(dest) && !force
        @debug "Using cached file" dest
        return dest
    end
    mkpath(dirname(dest))
    @info "Downloading $(basename(dest))" url
    tmp = dest * ".part"
    try
        Downloads.download(url, tmp)
        mv(tmp, dest; force=true)
    finally
        isfile(tmp) && rm(tmp)
    end
    return dest
end

"""
$(TYPEDSIGNATURES)

Extract the entries of the zip archive `zipfile` whose name is in `files` into `dir`.
All entries are extracted when `files` is empty. Returns the vector of extracted paths.
"""
function extract_zip(zipfile::AbstractString, dir::AbstractString; files=String[])
    reader = ZipReader(read(zipfile))
    out = String[]
    for name in zip_names(reader)
        (isempty(files) || basename(name) in files) || continue
        endswith(name, "/") && continue
        dest = joinpath(dir, basename(name))
        write(dest, zip_readentry(reader, name))
        push!(out, dest)
    end
    missing_files = setdiff(files, basename.(out))
    isempty(missing_files) || error("Files not found in $(basename(zipfile)): $(join(missing_files, ", "))")
    return out
end

"""
$(TYPEDSIGNATURES)

Normalise a name for lenient matching: lowercase, accents stripped, and every run of
non-alphanumeric characters replaced by a single space.
"""
function normalize_name(s::AbstractString)
    s = Unicode.normalize(String(s); stripmark=true, casefold=true)
    return strip(replace(s, r"[^a-z0-9]+" => " "))
end

"Divide `a` by `b`, returning `missing` when either is missing or `b` is zero."
safe_div(a, b) = (ismissing(a) || ismissing(b) || iszero(b)) ? missing : a / b

"Sum that skips missing values but returns `missing` when all values are missing."
function sum_skipmissing(x)
    v = collect(skipmissing(x))
    return isempty(v) ? missing : sum(v)
end

"Mean that skips missing values but returns `missing` when all values are missing."
function mean_skipmissing(x)
    v = collect(skipmissing(x))
    return isempty(v) ? missing : mean(v)
end
