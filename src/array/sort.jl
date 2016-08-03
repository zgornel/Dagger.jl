using Compat
import Compat: view

immutable Sort <: Computation
    input::LazyArray
    kwargs::Dict
end

Base.sort(x::LazyArray; kwargs...) =
    Sort(x, Dict(kwargs))

size(x::LazyArray) = size(x.input)

function compute(ctx, s::Sort)
    inp = cached_stage(ctx, s.input)
    ps = parts(inp)

    sorted_parts = map(p->Thunk(x->sort(x; s.kwargs...), (p,)), ps)
    blockwise_sorted = compute(ctx,
        Cat(Any, domain(inp),
        sorted_parts))
    persist!(blockwise_sorted)

    ls = map(length, parts(domain(inp)))
    splitter_ranks = cumsum(ls)[1:end-1]

    splitters = select(blockwise_sorted, splitter_ranks)
end

function mappart_eager(f, ctx, xs)
    thunks = [Thunk(f(i), (x,))
                 for (i, x) in enumerate(parts(xs))]

    gather(ctx, Thunk((xs...)->[xs...], (thunks...)))
end

function broadcast1(f, xs::Cat, m)
    ps = parts(xs)
    @assert size(m, 1) == length(ps)
    ctx = Context()
    mappart_eager(ctx, xs) do i
        inp = vec(m[i,:])
        function (p)
            map(x->f(p, x), inp)
        end
    end |> matrixize |> transpose
end

function broadcast2(f, xs::Cat, m,v)
    ps = parts(xs)
    @assert size(m, 1) == length(ps)
    ctx = Context()
    mappart_eager(ctx, xs) do i
        inp = vec(m[i,:])
        function (p)
            map((x,y)->f(p, x, y), inp, vec(v))
        end
    end |> matrixize |> transpose
end

function select(A, ranks, c=10^9)
    ks = copy(ranks)
    lengths = map(length, parts(domain(A)))
    n = sum(lengths)
    p = length(parts(A))
    init_ranges = map(x->1:x, lengths)
    active_ranges = matrixize([init_ranges for i=1:length(ks)])

    Ns = map(_->n, ks)
    iter=0
    result = Tuple[]
    while any(x->x>0, Ns)
        iter+=1
        # find medians
        ms = broadcast1(submedian, A, active_ranges)
        ls = map(length, active_ranges)
        Ms = sum(ms .* ls, 1) ./ sum(ls, 1)
        # scatter weighted
        dists = broadcast2(dist, A, active_ranges, Ms)
        D = reducedim((xs, x) -> map(+, xs, x), dists, 1, (0,0,0))
        L,E,G = map(x->x[1], D), map(x->x[2], D), map(x->x[3], D)
        # scatter L,E,G
        found = Int[]
        for i=1:length(ks)
            l,e,g,k = L[i], E[i], G[i], ks[i]
            if l < k && k <= l+e
                foundat = map(active_ranges[:,i], dists[:,i]) do rng, d
                    l,e,g=d
                    fst = first(rng)+l
                    lst = fst+e-1
                    fst:lst
                end
                push!(result, (Ms[i], foundat))
                push!(found, i)
            elseif k <= l
                # discard elements less than M
                active_ranges[:,i] = keep_lessthan(dists[:,i], active_ranges[:,i])
                Ns[i] = l
            elseif k > l + e
                # discard elements more than M
                active_ranges[:,i] = keep_morethan(dists[:,i], active_ranges[:,i])
                Ns[i] = g
                ks[i] = k - (l + e)
            end
        end
        found_mask = [!(x in found) for x in 1:length(ks)]
        active_ranges = active_ranges[:, found_mask]
        Ns = Ns[found_mask]
        ks = ks[found_mask]
    end
    return result
end

function submedian(xs, r)
    xs1 = view(xs, r)
    m = isempty(xs1) ? 0.0 : median(xs1)
end

function keep_lessthan(dists, active_ranges)
    map(dists, active_ranges) do d, r
        l = d[1]
        first(r):(first(r)+l-1)
    end
end

function keep_morethan(dists, active_ranges)
    map(dists, active_ranges) do d, r
        g = d[2]+d[1]
        (first(r)+g):last(r)
    end
end

function dist(X, r, s)
    # compute l, e, g
    X1 = view(X, r)
    rng = searchsorted(X1, s)
    l = first(rng) - 1
    e = length(rng)
    g = length(X1) - l - e
    l,e,g
end

function matrixize(xs)
    l = isempty(xs) ? 0 : length(xs[1])
    [xs[i][j] for j=1:l, i=1:length(xs)]
end

