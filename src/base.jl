export BigArray

include("types.jl")

using Blosc

function __init__()
    # use the same number of threads with Julia
    if haskey(ENV, "BLOSC_NUM_THREADS")
        Blosc.set_num_threads( parse(ENV["BLOSC_NUM_THREADS"]) )
    elseif haskey(ENV, "JULIA_NUM_THREADS")
        Blosc.set_num_threads( parse(ENV["JULIA_NUM_THREADS"]) )
    else
        Blosc.set_num_threads(4)
    end
    # use the default compression method
    # Blosc.set_compressor("blosclz")
end

"""
    BigArray
currently, assume that the array dimension (x,y,z,...) is >= 3
all the manipulation effects in the x,y,z dimension
"""
immutable BigArray{D<:Associative, T, N} <: AbstractBigArray
    chunkStore     ::D
    chunkSize   ::NTuple{N, Int}
    configDict  ::Dict{Symbol, Any}
end

function BigArray{D,T,N}( chunkStore::D, dataType::T,
                            chunkSize::NTuple{N,Int};
                            configDict::Dict{Symbol, Any}=Dict{Symbol, Any}() )
    BigArray{D,T,N}(chunkStore, chunkSize, configDict)
end

# a function expected to be inherited by backends
# refer the idea of modular design here:
# http://www.juliabloggers.com/modular-algorithms-for-scientific-computing-in-julia/
# a similar function:
# https://github.com/JuliaDiffEq/DiffEqBase.jl/blob/master/src/DiffEqBase.jl#L62
function get_config end

function BigArray( chunkStore::Associative )
    configDict = get_config( chunkStore )
    BigArray( chunkStore,
                eval(parse(configDict[:dataType])),
                (configDict[:chunkSize]...);
                configDict = configDict )
end

function Base.ndims{D,T,N}(ba::BigArray{D,T,N})
    return N
end

function Base.eltype{D, T, N}( ba::BigArray{D,T,N} )
    return T
end

function Base.size( ba::BigArray )
    # get size according to the keys
    size( CartesianRange(ba) )
end

function Base.CartesianRange{D,T,N}( ba::BigArray{D,T,N} )
    warn("the size was computed according to the keys, which is a number of chunk sizes and is not accurate")
    keyList = keys(ba.chunkStore)
    ret = CartesianRange(
            CartesianIndex([typemax(Int) for i=1:N]...),
            CartesianIndex([0            for i=1:N]...))
    for key in keyList
        union!(ret, CartesianRange(key))
    end
    ret
end

function Base.setindex!{D,T,N}( ba::BigArray{D,T,N}, buf::Array{T,N},
                            idxes::Union{UnitRange, Int, Colon}... )
    idxes = colon2unitRange(buf, idxes)
    baIter = BigArrayIterator(idxes, ba.chunkSize)
    chk = zeros(T, ba.chunkSize)
    for (blockID, chunkGlobalRange, globalRange, rangeInChunk, rangeInBuffer) in baIter
        # chk = ba.chunkStore[chunkGlobalRange]
        # chk = reshape(Blosc.decompress(T, chk), ba.chunkSize)
        fill!(chk, convert(T, 0))
        chk[rangeInChunk] = buf[rangeInBuffer]
        ba.chunkStore[chunkGlobalRange] = Blosc.compress(chk)
    end
end

function Base.getindex{D,T,N}( ba::BigArray{D, T, N}, idxes::Union{UnitRange, Int}...)
    sz = map(length, idxes)
    buf = zeros(eltype(ba), sz)
    baIter = BigArrayIterator(idxes, ba.chunkSize)
    for (blockID, chunkGlobalRange, globalRange, rangeInChunk, rangeInBuffer) in baIter
        chk = ba.chunkStore[chunkGlobalRange]
        chk = reshape(Blosc.decompress(T, chk), ba.chunkSize)
        buf[rangeInBuffer] = chk[rangeInChunk]
    end
    return buf
end

function Base.getindex{N}( h::Associative, key::CartesianRange{CartesianIndex{N}})
    h[string(key)]
end

function Base.setindex!{N}( h::Associative, v, key::CartesianRange{CartesianIndex{N}} )
    h[string(key)] = v
end
