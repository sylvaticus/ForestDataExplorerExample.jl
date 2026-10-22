# Generic helpers: cache location, downloads, archives, string matching, arithmetic.

"Environment variable that, when set, overrides the default cache location."
const CACHE_ENV = "FOREST_DATA_EXPLORER_EXAMPLE_DIR"

"""
$(TYPEDSIGNATURES)

Return the directory where the data of `country` are cached, creating it if needed.

By default this is a [Scratch.jl](https://github.com/JuliaPackaging/Scratch.jl) space
owned by the package. Set the environment variable `FOREST_DATA_EXPLORER_EXAMPLE_DIR` to use a
different root folder (e.g. a shared network drive or the test fixtures).
"""
function data_dir(country::AbstractString)
    root = get(ENV, CACHE_ENV, "")
    root = isempty(root) ? get_scratch!(@__MODULE__, "data") : root
    return mkpath(joinpath(root, normalize_name(country)))
end

"Whether the file at `path` starts like a zip archive."
is_zip(path::AbstractString) = open(io -> read(io, 4) == b"PK\x03\x04", path)

"Whether the file at `path` looks like an HTML page (e.g. an error or maintenance page)."
function is_html(path::AbstractString)
    # files can be binary: lowercase the ASCII letters byte by byte, without decoding
    head = String(map(b -> UInt8('A') <= b <= UInt8('Z') ? b + 0x20 : b, open(io -> read(io, 512), path)))
    return occursin("<!doctype html", head) || occursin("<html", head)
end

"""
$(TYPEDSIGNATURES)

Download `url` to `dest` atomically (via a temporary file), unless `dest` already exists
and `force` is false. Returns `dest`.

`url` can be a vector of URLs (a source and its mirrors), tried in order until one
succeeds. A download is rejected when it is an HTML page (servers in maintenance often
answer with one) or when `validate(path)` returns false; a cached file failing these
checks is downloaded again.
"""
function fetch_file(url, dest::AbstractString; force::Bool=false, validate=Returns(true))
    valid(path) = !is_html(path) && validate(path)
    if isfile(dest) && !force
        valid(dest) && return dest
        @warn "Cached file $(basename(dest)) is not valid, downloading it again"
    end
    mkpath(dirname(dest))
    tmp = dest * ".part"
    errors = String[]
    for u in (url isa AbstractString ? [url] : url)
        @info "Downloading $(basename(dest))" url = u
        try
            Downloads.download(u, tmp)
            if valid(tmp)
                mv(tmp, dest; force=true)
                return dest
            end
            push!(errors, "$u: the server did not return the expected file (it may be in maintenance)")
        catch err
            push!(errors, "$u: $(sprint(showerror, err))")
        finally
            isfile(tmp) && rm(tmp)
        end
    end
    error("Could not download $(basename(dest)):\n  " * join(errors, "\n  "))
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
