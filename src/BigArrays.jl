__precompile__()

module BigArrays

abstract type AbstractBigArray <: AbstractArray{Any,Any} end

# basic functions
include("BackendBase.jl"); using .BackendBase
include("Codings.jl"); 
using .Codings;
include("Indexes.jl"); using .Indexes;
include("Iterators.jl"); using .Iterators;
include("backends/include.jl") 

using OffsetArrays 
using JSON
using Libz

#import .BackendBase: AbstractBigArrayBackend  
# Note that DenseArray only works for memory stored Array
# http://docs.julialang.org/en/release-0.4/manual/arrays/#implementation
export AbstractBigArray, BigArray 

function __init__()
    global const WORKER_POOL = WorkerPool( workers() )
    @show WORKER_POOL 
    global const GZIP_MAGIC_NUMBER = UInt8[0x1f, 0x8b, 0x08]  
    # map datatype of python to Julia 
    global const DATATYPE_MAP = Dict{String, DataType}(
        "bool"      => Bool,
        "uint8"     => UInt8, 
        "uint16"    => UInt16, 
        "uint32"    => UInt32, 
        "uint64"    => UInt64, 
        "float32"   => Float32, 
        "float64"   => Float64 
    )  

    global const CODING_MAP = Dict{String,Any}(
        # note that the raw encoding in cloud storage will be automatically gzip encoded!
        "raw"       => GzipCoding,
        "jpeg"      => JPEGCoding,
        "blosclz"   => BlosclzCoding,
        "gzip"      => GzipCoding, 
        "zstd"      => ZstdCoding 
    )
end 


struct BigArray{D<:AbstractBigArrayBackend, T<:Real, 
                            N, C<:AbstractBigArrayCoding} <: AbstractBigArray
    kvStore     :: D
    chunkSize   :: NTuple{N}
    volumeSize  :: NTuple{N}
    offset      :: CartesianIndex{N}
    function BigArray(
                kvStore     ::D,
                foo         ::Type{T},
                chunkSize   ::NTuple{N},
                volumeSize  ::NTuple{N},
                coding      ::Type{C};
                offset      ::CartesianIndex{N} = CartesianIndex{N}() - 1) where {D,T,N,C}
        new{D, T, N, C}(kvStore, chunkSize, volumeSize, offset)
    end
end

function BigArray( d::AbstractBigArrayBackend)
    info = get_info(d)
    return BigArray(d, info)
end

function BigArray( d::AbstractBigArrayBackend, info::Vector{UInt8})
    if all(info[1:3] .== GZIP_MAGIC_NUMBER)
        info = Libz.decompress(info)
    end 
    BigArray(d, String(info))
end 

function BigArray( d::AbstractBigArrayBackend, info::AbstractString )
    BigArray(d, JSON.parse( info, dicttype=Dict{Symbol, Any} ))
end 

function BigArray( d::AbstractBigArrayBackend, infoConfig::Dict{Symbol, Any}) 
    # chunkSize
    scale_name = get_scale_name(d)
    T = DATATYPE_MAP[infoConfig[:data_type]]
    local offset::Tuple, encoding, chunkSize::Tuple, volumeSize::Tuple 
    for scale in infoConfig[:scales]
        if scale[:key] == scale_name 
            chunkSize = (scale[:chunk_sizes][1]...)
            offset = (scale[:voxel_offset]...)
            volumeSize = (scale[:size]...)
            encoding = CODING_MAP[ scale[:encoding] ]
            if infoConfig[:num_channels] > 1
                chunkSize = (chunkSize..., infoConfig[:num_channels])
                volumeSize = (volumeSize..., infoConfig[:num_channels])
                offset = (offset..., 0)
            end
            break 
        end 
    end 
    BigArray(d, T, chunkSize, volumeSize, encoding; offset=CartesianIndex(offset)) 
end

######################### base functions #######################

function Base.ndims(ba::BigArray{D,T,N}) where {D,T,N} N end

function Base.eltype( ba::BigArray{D,T,N} ) where {D, T, N} T end

function Base.size( ba::BigArray{D,T,N} ) where {D,T,N}
    # get size according to the keys
    return ba.volumeSize
end

function Base.size(ba::BigArray, i::Int)  size(ba)[i] end

function Base.show(ba::BigArray) show(ba.chunkSize) end

function Base.display(ba::BigArray)
    for field in fieldnames(ba)
        println("$field: $(getfield(ba,field))")
    end
end

function Base.reshape(ba::BigArray{D,T,N}, newShape) where {D,T,N}
    warn("reshape failed, the shape of bigarray is immutable!")
end

function Base.CartesianRange( ba::BigArray{D,T,N} ) where {D,T,N}
    warn("the size was computed according to the keys, which is a number of chunk sizes and is not accurate")
    ret = CartesianRange(
            CartesianIndex([typemax(Int) for i=1:N]...),
            CartesianIndex([0            for i=1:N]...))
    warn("boundingbox function abanduned due to the malfunction of keys in S3Dicts")
    return ret
end

function setindex_remote_worker(block::Array{T,N}, ba::BigArray{D,T,N,C}, 
                                        chunkGlobalRange::CartesianRange) where {D,T,N,C}
    delay = 0.05
	for t in 1:4
		try
			ba.kvStore[ cartesian_range2string(chunkGlobalRange) ] = encode( block, C)
			break
		catch e
			println("catch an error while saving in BigArray: $e")
			@show typeof(e)
			@show stacktrace()
			if t==4
				println("rethrow the error: $e")
				rethrow()
			end 
			sleep(delay*(0.8+(0.4*rand())))
			delay *= 10
			println("retry for the $(t)'s time: $(string(chunkGlobalRange))")
		end
	end
end

"""
    put array in RAM to a BigArray
this version uses channel to control the number of asynchronized request
"""
function Base.setindex!( ba::BigArray{D,T,N,C}, buf::Array{T,N},
                       idxes::Union{UnitRange, Int, Colon} ... ) where {D,T,N,C}
    idxes = colon2unit_range(buf, idxes)
    # check alignment
    @assert all(map((x,y,z)->mod(x.start - 1 - y, z), idxes, ba.offset.I, ba.chunkSize).==0) "the start of index should align with BigArray chunk size" 
    t1 = time() 
    baIter = Iterator(idxes, ba.chunkSize; offset=ba.offset)
    @sync begin  
        for (blockID, chunkGlobalRange, globalRange, rangeInChunk, rangeInBuffer) in baIter
            chunkGlobalRange, globalRange, rangeInChunk, rangeInBuffer = adjust_volume_boundary(ba, chunkGlobalRange, globalRange, rangeInChunk, rangeInBuffer)
            block = buf[cartesian_range2unit_range(rangeInBuffer)...]
            @schedule remotecall_fetch(setindex_remote_worker, WORKER_POOL, 
                                       block, ba, chunkGlobalRange)
        end 
    end 
    totalSize = length(buf) * sizeof(eltype(buf)) / 1024/1024 # MB
    elapsed = time() - t1 # sec
    println("saving speed: $(totalSize/elapsed) MB/s")
end 

function Base.merge(ba::BigArray{D,T,N,C}, 
                    arr::OffsetArray{T,N, Array{T,N}}) where {D,T,N,C}
    @unsafe ba[indices(arr)...] = arr |> parent
end 

function Base.CartesianRange(ba::BigArray)
    start = ba.offset + 1
    stop = ba.offset + CartesianIndex(ba.volumeSize)
    return CartesianRange( start, stop )
end 

function remote_getindex_worker(ba::BigArray{D,T,N,C}, jobs::RemoteChannel, 
                                sharedBuffer::OffsetArray{T,N,SharedArray{T,N}}) where {D,T,N,C}
    baRange = CartesianRange(ba)
    blockId, chunkGlobalRange, globalRange, rangeInChunk, rangeInBuffer = take!(jobs)
    if any(map((x,y)->x>y, globalRange.start.I, baRange.stop.I)) || any(map((x,y)->x<y, globalRange.stop.I, baRange.start.I))
        warn("out of volume range, keep it as zeros")
        return
    end
    chunkGlobalRange, globalRange, rangeInChunk, rangeInBuffer = adjust_volume_boundary(ba, chunkGlobalRange, globalRange, rangeInChunk, rangeInBuffer)
    # finalize to avoid memory leak, see
    # https://discourse.julialang.org/t/understanding-distributed-memory-garbage-collection/8726/2
    #finalize(jobs)
    chunkSize = (chunkGlobalRange.stop - chunkGlobalRange.start + 1).I
    #println("processing block in global range: $(cartesian_range2string(globalRange))")
    data = ba.kvStore[ cartesian_range2string(chunkGlobalRange) ]
    chk = Codings.decode(data, C)
    chk = reshape(reinterpret(T, chk), chunkSize)
    chk = chk[cartesian_range2unit_range(rangeInChunk)...]
    sharedBuffer[cartesian_range2unit_range(globalRange)...] = chk[cartesian_range2unit_range(rangeInChunk)...]
end 

function Base.getindex( ba::BigArray{D, T, N, C}, idxes::Union{UnitRange, Int}...) where {D,T,N,C}
    t1 = time()
    sz = map(length, idxes)
    # it seems that the default value is automatically set to zero
    sharedBuffer = OffsetArray(SharedArray{eltype(ba)}(sz; pids=workers(WORKER_POOL)),
                               idxes...)

    const channelSize = cld( nworkers(), 2 )
    const jobs    = RemoteChannel(()->Channel{Tuple}( channelSize ));

    
    baIter = Iterator(idxes, ba.chunkSize; offset=ba.offset)
    
    @sync begin
        @async begin
            for iter in baIter
                put!(jobs, iter)
            end
            close(jobs)
        end
        # control the number of concurrent requests here
        for iter in baIter
            @async remote_do(remote_getindex_worker, WORKER_POOL, ba, jobs, sharedBuffer)
        end
    end
    ret = OffsetArray(Array(sharedBuffer |> parent), indices(sharedBuffer))
    totalSize = length(parent(ret)) * sizeof(eltype(parent(ret))) / 1024/1024 # mega bytes
    elapsed = time() - t1 # seconds 
    println("cutout speed: $(totalSize/elapsed) MB/s")
    # handle single element indexing, return the single value
    ret 
end

function get_chunk_size(ba::AbstractBigArray)
    ba.chunkSize
end

###################### utils ####################
"""
    get_num_chunks(ba::BigArray, idxes::Union{UnitRange,Int}...)
get number of chunks needed to do cutout from this range 
"""
function get_num_chunks(ba::BigArray, idxes::Union{UnitRange, Int}...)
    chunkNum = 0
    baIter = Iterator(idxes, ba.chunkSize; offset=ba.offset)                          
	for (blockId, chunkGlobalRange, globalRange, rangeInChunk, rangeInBuffer) in baIter
        chunkNum += 1
	end                                                                                
    chunkNum
end 

"""
    list_missing_chunks(ba::BigArray, idxes::Union{UnitRange, Int}...)
list the non-existing keys in the index range
if the returned list is empty, then all the chunks exist in the storage backend.
"""
function list_missing_chunks(ba::BigArray, idxes::Union{UnitRange, Int}...) 
    t1 = time()
    sz = map(length, idxes)
    missingChunkList = Vector{CartesianRange}()
    baIter = Iterator(idxes, ba.chunkSize; offset=ba.offset)
    @sync begin 
        for (blockId, chunkGlobalRange, globalRange, rangeInChunk, rangeInBuffer) in baIter
            @async begin 
                if !haskey(ba.kvStore, cartesian_range2string(chunkGlobalRange))
                    push!(missingChunkList, chunkGlobalRange)
                end
            end
        end
    end 
    missingChunkList 
end

function list_missing_chunks(ba::BigArray, keySet::Set{String}, idxes::Union{UnitRange, Int}...)
    t1 = time()
    sz = map(length, idxes)
    missingChunkList = Vector{CartesianRange}()
    baIter = Iterator(idxes, ba.chunkSize; offset=ba.offset)
    for (blockId, chunkGlobalRange, globalRange, rangeInChunk, rangeInBuffer) in baIter
        if !(cartesian_range2string(chunkGlobalRange) in keySet)
            push!(missingChunkList, chunkGlobalRange)
        end 
    end
    missingChunkList
end 

"""
adjust the global and buffer range according to total volume size.
shrink the range stop if the ranges passes the volume boundary.
"""
function adjust_volume_boundary(ba::BigArray, chunkGlobalRange::CartesianRange,
                                globalRange::CartesianRange,
                                rangeInChunk::CartesianRange, 
                                rangeInBuffer::CartesianRange)
    volumeStop = map(+, ba.offset.I, ba.volumeSize)
    chunkGlobalRangeStop = [chunkGlobalRange.stop.I ...]
    globalRangeStop = [globalRange.stop.I ...]
    rangeInBufferStop = [rangeInBuffer.stop.I ...]
    rangeInChunkStop = [rangeInChunk.stop.I...] 

    for (i,s) in enumerate(volumeStop)
        if chunkGlobalRangeStop[i] > s
            chunkGlobalRangeStop[i] = s
        end
        distanceOverBorder = globalRangeStop[i] - s
        if distanceOverBorder > 0
            globalRangeStop[i] -= distanceOverBorder
            @assert globalRangeStop[i] == s
            @assert globalRangeStop[i] > globalRange.start.I[i]
            rangeInBufferStop[i] -= distanceOverBorder
            rangeInChunkStop[i] -= distanceOverBorder
        end
    end
    chunkGlobalRange = CartesianRange(chunkGlobalRange.start, 
                                      CartesianIndex((chunkGlobalRangeStop...)))
    globalRange = CartesianRange(globalRange.start, 
                                 CartesianIndex((globalRangeStop...)))

    rangeInBuffer = CartesianRange(rangeInBuffer.start, 
                                   CartesianIndex((rangeInBufferStop...)))
    rangeInChunk = CartesianRange(rangeInChunk.start, 
                                  CartesianIndex((rangeInChunkStop...)))
    return chunkGlobalRange, globalRange, rangeInChunk, rangeInBuffer
end 

end # module
