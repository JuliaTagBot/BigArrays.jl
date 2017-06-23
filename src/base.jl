using .BigArrayIterators

"""
    BigArray
currently, assume that the array dimension (x,y,z,...) is >= 3
all the manipulation effects in the x,y,z dimension
"""
immutable BigArray{D<:Associative, T<:Real, N, C<:AbstractBigArrayCoding} <: AbstractBigArray
    kvStore     :: D
    chunkSize   :: NTuple{N}
    offset      :: CartesianIndex{N}
    function (::Type{BigArray}){D,T,N,C}(
                            kvStore     ::D,
                            foo         ::Type{T},
                            chunkSize   ::NTuple{N},
                            coding      ::Type{C} )
        new{D, T, N, C}(kvStore, chunkSize, CartesianIndex{N}() - 1)
    end

    function (::Type{BigArray}){D,T,N,C}(
                            kvStore     ::D,
                            foo         ::Type{T},
                            chunkSize   ::NTuple{N},
                            coding      ::Type{C},
                            offset      ::CartesianIndex{N} )
        # force the offset to be 0s to shutdown the functionality of offset for now
        # because it corrupted all the other bigarrays in aws s3
        offset = CartesianIndex{N}() - 1 
        new{D, T, N, C}(kvStore, chunkSize, offset)
    end
end

function BigArray( d::Associative )
    return BigArray(d, d.configDict)
end

function BigArray( d::Associative, configDict::Dict{Symbol, Any} )
    T = eval(parse(configDict[:dataType]))
    # @show T
    chunkSize = (configDict[:chunkSize]...)
    if haskey( configDict, :coding )
        if contains( configDict[:coding], "raw" )
            coding = RawCoding
        elseif contains(  configDict[:coding], "jpeg")
            coding = JPEGCoding
        elseif contains( configDict[:coding], "blosclz")
            coding = BlosclzCoding
        elseif contains( configDict[:coding], "gzip" )
            coding = GZipCoding
        else
            error("unknown coding")
        end
    else
        coding = DEFAULT_CODING
    end

    if haskey(configDict, :offset)
      offset = CartesianIndex(configDict[:offset]...)

      if length(offset) < length(chunkSize)
        N = length(chunkSize)
        offset = CartesianIndex{N}(Base.fill_to_length((offset...), 0, Val{N}))
      end

      return BigArray( d, T, chunkSize, coding, offset )
    else
      return BigArray( d, T, chunkSize, coding )
    end
end

function Base.ndims{D,T,N}(ba::BigArray{D,T,N})
    N
end

function Base.eltype{D, T, N}( ba::BigArray{D,T,N} )
    # @show T
    return T
end

function Base.size{D,T,N}( ba::BigArray{D,T,N} )
    # get size according to the keys
    ret = size( CartesianRange(ba) )
    return ret
end

function Base.size(ba::BigArray, i::Int)
    size(ba)[i]
end

function Base.show(ba::BigArray)
    display(ba)
end

function Base.display(ba::BigArray)
    for field in fieldnames(ba)
        println("$field: $(getfield(ba,field))")
    end
end

function Base.reshape{D,T,N}(ba::BigArray{D,T,N}, newShape)
    warn("reshape failed, the shape of bigarray is immutable!")
end

function Base.CartesianRange{D,T,N}( ba::BigArray{D,T,N} )
    warn("the size was computed according to the keys, which is a number of chunk sizes and is not accurate")
    ret = CartesianRange(
            CartesianIndex([typemax(Int) for i=1:N]...),
            CartesianIndex([0            for i=1:N]...))
    warn("boundingbox function abanduned due to the malfunction of keys in S3Dicts")

    #keyList = keys(ba.kvStore)
    #for key in keyList
     #   if !isempty(key)
    #        union!(ret, CartesianRange(key))
    #    end
    #end
    return ret
end

"""
    put array in RAM to a BigArray
"""
function Base.setindex!{D,T,N,C}( ba::BigArray{D,T,N,C}, buf::Array{T,N},
                                idxes::Union{UnitRange, Int, Colon} ... )
    @assert eltype(ba) == T
    @assert ndims(ba) == N
    # @show idxes
    idxes = colon2unitRange(buf, idxes)
    baIter = BigArrayIterator(idxes, ba.chunkSize)
    chk = Array(T, ba.chunkSize)
    #@sync begin 
        for (blockID, chunkGlobalRange, globalRange, rangeInChunk, rangeInBuffer) in baIter
            #@async begin
                println("global range of chunk: $(string(chunkGlobalRange))")
                fill!(chk, convert(T, 0))
                delay = 0.05
                for t in 1:4
                    try 
                        chk[rangeInChunk] = buf[rangeInBuffer]
                        ba.kvStore[ string(chunkGlobalRange) ] = encoding( chk, C)
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
            #end 
        end
    #end 
end 

function Base.getindex{D,T,N,C}( ba::BigArray{D, T, N, C}, idxes::Union{UnitRange, Int}...)
    sz = map(length, idxes)
    buf = zeros(eltype(ba), sz)

    baIter = BigArrayIterator(idxes, ba.chunkSize, ba.offset)
    #@sync begin
        for (blockID, chunkGlobalRange, globalRange, rangeInChunk, rangeInBuffer) in baIter
     #       @async begin
                # explicit error handling to deal with EOFError
                delay = 0.05
                for t in 1:4
                    try 
                        println("global range of chunk: $(string(chunkGlobalRange))") 
                        v = ba.kvStore[string(chunkGlobalRange)]
                        @assert isa(v, Array)
                        chk = decoding(v, C)
                        chk = reshape(reinterpret(T, chk), ba.chunkSize)
                        buf[rangeInBuffer] = chk[rangeInChunk]
                        break 
                    catch e
                        println("catch an error while getindex in BigArray: $e")
                        if isa(e, NoSuchKeyException)
                            println("no suck key in kvstore: $(e), will fill this block as zeros")
                            break
                        else
                            if isa(e, EOFError)
                                println("get EOFError in bigarray getindex: $e")
                            end
                            if t==4
                                rethrow()
                            end
                            sleep(delay*(0.8+(0.4*rand())))
                            delay *= 10
                        end
                    end 
                end
     #       end 
        end
    #end 
    # handle single element indexing, return the single value
    if length(buf) == 1
        return buf[1]
    else 
        # otherwise return array
        return buf
    end 
end

function get_chunk_size(ba::AbstractBigArray)
    ba.chunkSize
end
