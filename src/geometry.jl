# A deliberately small geometry layer: enough to read administrative borders, reproject
# them, compute areas, assign points to polygons and draw maps.

"A 2D point (x, y) or (lon, lat)."
const Pt = NTuple{2,Float64}
"A closed ring of points (first point not repeated at the end)."
const Ring = Vector{Pt}
"A polygon: its first ring is the exterior, the following ones are holes."
const Poly = Vector{Ring}

"""
$(TYPEDEF)

An administrative unit (country, region or department) with its geometry.

$(TYPEDFIELDS)
"""
struct AdminShape
    "Official code of the unit (e.g. `\"88\"` for the Vosges department)."
    code::String
    "Name of the unit."
    name::String
    "Polygons composing the unit, in the plugin's map coordinate reference system."
    polygons::Vector{Poly}
end

"""
$(TYPEDSIGNATURES)

Read the features of a GeoJSON file as [`AdminShape`](@ref)s, using the properties
`codekey` and `namekey` for the code and the name of each feature.
"""
function read_geojson(path::AbstractString; codekey="code", namekey="nom")
    js = JSON.parsefile(path)
    features = js["type"] == "FeatureCollection" ? js["features"] : [js]
    shapes = AdminShape[]
    for f in features
        props = something(get(f, "properties", nothing), Dict{String,Any}())
        code = string(get(props, codekey, ""))
        name = string(get(props, namekey, code))
        g = f["geometry"]
        coords = g["type"] == "Polygon" ? [g["coordinates"]] : g["coordinates"]
        polys = [[[(Float64(p[1]), Float64(p[2])) for p in ring[1:end-1]] for ring in poly] for poly in coords]
        push!(shapes, AdminShape(code, name, polys))
    end
    return shapes
end

"""
$(TYPEDSIGNATURES)

Reproject all the coordinates of `shapes` from the CRS `from` to the CRS `to`
(any string understood by PROJ, e.g. `"EPSG:4326"`).
"""
function reproject(shapes::Vector{AdminShape}, from::AbstractString, to::AbstractString)
    trans = Proj.Transformation(from, to; always_xy=true)
    return [AdminShape(s.code, s.name, [[[Pt(trans(p...)) for p in ring] for ring in poly] for poly in s.polygons])
            for s in shapes]
end

"Signed area of a ring with the shoelace formula (positive when counter-clockwise)."
function signed_area(ring::AbstractVector)
    n = length(ring)
    a = 0.0
    @inbounds for i in 1:n
        x1, y1 = ring[i]
        x2, y2 = ring[mod1(i + 1, n)]
        a += x1 * y2 - x2 * y1
    end
    return a / 2
end

"Area of a polygon (exterior ring minus holes), in squared CRS units."
polygon_area(poly::Poly) = abs(signed_area(poly[1])) - sum((abs(signed_area(r)) for r in poly[2:end]); init=0.0)

"Total area of an [`AdminShape`](@ref), in squared CRS units."
shape_area(s::AdminShape) = sum(polygon_area, s.polygons; init=0.0)

"Area-weighted centroid of a ring."
function ring_centroid(ring::AbstractVector)
    a = signed_area(ring)
    iszero(a) && return Pt((mean(first.(ring)), mean(last.(ring))))
    n = length(ring)
    cx = cy = 0.0
    @inbounds for i in 1:n
        x1, y1 = ring[i]
        x2, y2 = ring[mod1(i + 1, n)]
        f = x1 * y2 - x2 * y1
        cx += (x1 + x2) * f
        cy += (y1 + y2) * f
    end
    return Pt((cx / (6a), cy / (6a)))
end

"Bounding box `(xmin, ymin, xmax, ymax)` of a collection of rings."
function bbox(rings)
    xmin = ymin = Inf
    xmax = ymax = -Inf
    for ring in rings, (x, y) in ring
        xmin = min(xmin, x); xmax = max(xmax, x)
        ymin = min(ymin, y); ymax = max(ymax, y)
    end
    return (xmin, ymin, xmax, ymax)
end
bbox(s::AdminShape) = bbox(Iterators.flatten(s.polygons))

"Ray-casting test of whether point `p` lies inside `ring`."
function in_ring(p, ring::AbstractVector)
    x, y = p
    inside = false
    n = length(ring)
    j = n
    @inbounds for i in 1:n
        xi, yi = ring[i]
        xj, yj = ring[j]
        if (yi > y) != (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi
            inside = !inside
        end
        j = i
    end
    return inside
end

"Whether point `p` lies inside polygon `poly` (inside the exterior ring and outside all holes)."
in_polygon(p, poly::Poly) = in_ring(p, poly[1]) && !any(r -> in_ring(p, r), @view poly[2:end])

"Whether point `p` lies inside the [`AdminShape`](@ref) `s`."
in_shape(p, s::AdminShape) = any(poly -> in_polygon(p, poly), s.polygons)

"""
$(TYPEDSIGNATURES)

Return, for each point of `points`, the index in `shapes` of the shape containing it.
Points falling outside every shape (e.g. because of simplified coastlines) are assigned
to the shape with the nearest vertex when it is closer than `maxdist` CRS units, and to
`0` otherwise.
"""
function assign_points(points::AbstractVector, shapes::Vector{AdminShape}; maxdist=20_000.0)
    boxes = bbox.(shapes)
    out = zeros(Int, length(points))
    Threads.@threads for i in eachindex(points)
        p = points[i]
        for (k, (s, b)) in enumerate(zip(shapes, boxes))
            (b[1] <= p[1] <= b[3] && b[2] <= p[2] <= b[4]) || continue
            if in_shape(p, s)
                out[i] = k
                break
            end
        end
        if out[i] == 0
            best, bestd = 0, maxdist^2
            for (k, s) in enumerate(shapes), poly in s.polygons, q in poly[1]
                d = (q[1] - p[1])^2 + (q[2] - p[2])^2
                d < bestd && ((best, bestd) = (k, d))
            end
            out[i] = best
        end
    end
    return out
end

"Convert an [`AdminShape`](@ref) to a `GeometryBasics.MultiPolygon` for plotting with Makie."
function to_makie(s::AdminShape)
    GB = CairoMakie.GeometryBasics
    polys = map(s.polygons) do poly
        ext = [CairoMakie.Point2f(p...) for p in poly[1]]
        holes = [[CairoMakie.Point2f(p...) for p in r] for r in poly[2:end]]
        GB.Polygon(ext, holes)
    end
    return GB.MultiPolygon(polys)
end
