
module Stat

require("Distributions.jl")
import Distributions.Uniform

require("Iterators.jl")
import Iterators.chain

import Gadfly
import Gadfly.Scale
using DataFrames

# Apply a series of statistics.
#
# Args:
#   stats: Statistics to apply in order.
#   aes: A Aesthetics instance.
#   trans: Map of variables to the transform applied to it.
#
# Returns:
#   Nothing, modifies aes.
#
function apply_statistics(stats::Vector{Gadfly.StatisticElement},
                          aes::Gadfly.Aesthetics)
    for stat in stats
        apply_statistic(stat, aes)
    end
    nothing
end

type Nil <: Gadfly.StatisticElement
end

const nil = Nil()

type Identity <: Gadfly.StatisticElement
end

function apply_statistic(stat::Identity, aes::Gadfly.Aesthetics)
    nothing
end

const identity = Identity()


type HistogramStatistic <: Gadfly.StatisticElement
end

const histogram = HistogramStatistic()


# Compute the cross validation risk for a histogram.
#
# This method was taken from "All of Statistics", by Larry Wasserman, but was
# developed first in "Emperical Choice of Histograms and Kernel Density
# Estimators" by Mats Rudemo.
#
# Args:
#   xs: Data the histogram will represent, sorted in ascending order.
#   m: Number of bins.
#
# Returns:
#   A risk value that should be minimized.
#
function cross_val_risk(xs::Vector{Float64}, m::Int)
    (x_min, x_max) = (xs[1], xs[end])

    # bandwidth
    h = (x_max - x_min) / m

    # current bin's upper bound
    b = x_min + h

    i = 1
    n = length(xs)
    r = 0
    for j in 1:m
        p = 0
        while i < n && xs[i] <= b
            p += 1
            i += 1
        end

        p /= n
        r += p^2
        b += h
    end

    r *= (n + 1) / ((n - 1) * h)
    r = (2 / ((n - 1) * h)) - r
    r
end


# Estimate the optimal number of bins for a histogram by minimizing cross
# validation risk.
#
# Args:
#   xs: Data the histogram will represent, sorted in asceding order.
#
# Returns:
#   The optimal number of bins.
#
function choose_bin_count(xs::Vector{Float64})
    # Number of bins
    m = 3

    # Cross validation risk, which we want to minimize.
    r = cross_val_risk(xs, m)

    # Magnitude of proposal offsets
    d = Uniform(0, 3)

    # Run a few rounds of stochastic hill-climbing to find a good number
    N = 500
    for _ in 1:N
        off = int(rand(d))
        m_proposed = randbool() ? m + off : max(1, m - off)
        r_proposed = cross_val_risk(xs, m_proposed)

        # accept/reject
        if r_proposed < r
            m = m_proposed
            r = r_proposed
        end
    end

    m
end


function apply_statistic(stat::HistogramStatistic, aes::Gadfly.Aesthetics)
    sorted_x = sort(aes.x)
    n = length(sorted_x)
    m = choose_bin_count(sorted_x)
    h = (sorted_x[end] - sorted_x[1]) / m

    aes.x = Array(Float64, m)
    aes.y = Array(Float64, m)

    # current bin's upper bound
    b = sorted_x[1] + h
    i = 1

    for j in 1:m
        p = 0
        while i < n && sorted_x[i] <= b
            p += 1
            i += 1
        end

        aes.x[j] = j * h
        aes.y[j] = p
        b += h
    end
    nothing
end


# Find reasonable places to put tick marks and grid lines.
type TickStatistic <: Gadfly.StatisticElement
    in_vars::Vector{Symbol}
    out_var::Symbol
end


const x_ticks = TickStatistic([:x], :xtick)
const y_ticks = TickStatistic([:y], :ytick)


# Find some reasonable values for tick marks.
#
# This is basically Wilkinson's ad-hoc scoring method that tries to balance
# tight fit around the data, optimal number of ticks, and simple numbers.
#
# Args:
#   x_min: minimum value occuring in the data.
#   x_max: maximum value occuring in the data.
#
# Returns:
#   A Float64 vector containing tick marks.
#
function optimize_ticks(x_min::Float64, x_max::Float64)
    # TODO: these should perhaps be part of the theme
    const Q = {(1,1), (5, 0.9), (2, 0.7), (25, 0.5), (3, 0.2)}
    const n = length(Q)
    const k_min   = 2
    const k_max   = 10
    const k_ideal = 5

    xspan = x_max - x_min
    z = ceil(log10(xspan))

    high_score = -Inf
    z_best = 0.0
    k_best = 0.0
    r_best = 0.0
    q_best = 0.0

    while k_max * 10^(z+1) > xspan
        for k in k_min:k_max
            for (q, qscore) in Q
                span = (k - 1) * q * 10^z
                if span < xspan
                    continue
                end

                r = ceil((x_max - span) / (q*10^z))
                while r*q*10^z <= x_min
                    has_zero = r <= 0 && abs(r) < k

                    # simplicity
                    s = has_zero ? 1.0 : 0.0

                    # granularity
                    g = 0 < k < 2k_ideal ? 1 - abs(k - k_ideal) / k_ideal : 0.0

                    # coverage
                    c = xspan/span

                    score = (1/4)g + (1/6)s + (1/3)c + (1/4)qscore

                    if score > high_score
                        (q_best, r_best, k_best, z_best) = (q, r, k, z)
                        high_score = score
                    end
                    r += 1
                end
            end
        end
        z -= 1
    end

    S = Array(Float64, int(k_best))
    for i in 0:(k_best - 1)
        S[i+1] = (r_best + i) * q_best * 10^z_best
    end

    S
end


# Apply a tick statistic.
#
# Args:
#   stat: statistic.
#   aes: aesthetics.
#
# Returns:
#   nothing
#
# Modifies:
#   aes
#
function apply_statistic(stat::TickStatistic, aes::Gadfly.Aesthetics)
    in_values = [getfield(aes, var) for var in stat.in_vars]
    in_values = filter(val -> !(val === nothing), in_values)
    in_values = chain(in_values...)

    minval = Inf
    maxval = -Inf
    all_int = true

    for val in in_values
        if val < minval
            minval = val
        end

        if val > maxval
            maxval = val
        end

        if !(typeof(val) <: Integer)
            all_int = false
        end
    end

    # all the input values in order.
    if all_int
        ticks = Set{Float64}()
        add_each(ticks, chain(in_values))
        ticks = Float64[t for t in ticks]
        sort!(ticks)
    else
        ticks = optimize_ticks(minval, maxval)
    end

    # We use the first label function we find for any of the aesthetics. I'm not
    # positive this is the right thing to do, or would would be.
    labeler = getfield(aes, symbol(@sprintf("%s_label", stat.in_vars[1])))

    setfield(aes, stat.out_var, ticks)
    setfield(aes, symbol(@sprintf("%s_label", stat.out_var)), labeler)

    nothing
end


end # module Stat

