# E. Dynamic Parallelism


## streams

export CuDeviceStream

struct CuDeviceStream
    handle::cudaStream_t

    function CuDeviceStream(flags=cudaStreamNonBlocking)
        handle_ref = Ref{cudaStream_t}()
        cudaStreamCreateWithFlags(handle_ref, flags)
        return new(handle_ref[])
    end
end

Base.unsafe_convert(::Type{cudaStream_t}, s::CuDeviceStream) = s.handle

function unsafe_destroy!(s::CuDeviceStream)
    cudaStreamDestroy(s)
    return
end


## execution

# device-side counterpart of launch
@inline function device_launch(f, blocks, threads, shmem, stream, args...)
    blockdim = CuDim3(blocks)
    threaddim = CuDim3(threads)

    buf = parameter_buffer(f, blockdim, threaddim, shmem, args...)
    cudaLaunchDeviceV2(buf, stream)

    return
end

@generated function parameter_buffer(f, blocks, threads, shmem, args...)
    # allocate a buffer
    ex = quote
        Base.@_inline_meta
        buf = cudaGetParameterBufferV2(f, blocks, threads, shmem)
        ptr = Base.unsafe_convert(Ptr{UInt32}, buf)
    end

    # store the parameters
    #
    # D.3.2.2. Parameter Buffer Layout
    # > Each individual parameter placed in the parameter buffer is required to be aligned.
    # > That is, each parameter must be placed at the n-th byte in the parameter buffer,
    # > where n is the smallest multiple of the parameter size that is greater than the
    # > offset of the last byte taken by the preceding parameter. The maximum size of the
    # > parameter buffer is 4KB.
    #
    # NOTE: the above seems wrong, and we should use the parameter alignment, not its size.
    last_offset = 0
    for i in 1:length(args)
        T = args[i]
        align = Base.datatype_alignment(T)
        offset = Base.cld(last_offset, align) * align
        push!(ex.args, :(
            Base.pointerset(convert(Ptr{$T}, ptr+$offset), args[$i], 1, $align)
        ))
        last_offset = offset + sizeof(T)
    end

    push!(ex.args, :(return buf))

    return ex
end


## synchronization

"""
    device_synchronize()

Wait for the device to finish. This is the device side version,
and should not be called from the host.

`device_synchronize` acts as a synchronization point for
child grids in the context of dynamic parallelism.
"""
device_synchronize() = cudaDeviceSynchronize()
